/*
 * Sign Diagnostic v3: Granular DIAG snapshots during LOAD_MU
 * Captures GenY state at each data phase to trace the stall
 *
 * Corrected DIAG format (from LSB):
 * [4:0]   cstate0        [9:5]   cstate1/owt  [14:10] cstate2/owt
 * [25:15] padding         [26] done_geny       [27] cstart_fsm2
 * [28] cstart_fsm1        [29] cstart_fsm0     [30] k_fsm
 * [31] src_read[2]        [32] dst_write[2]    [33] start_geny
 * [34] ready_i_geny       [35] valid_o_geny    [39:36] geny_state
 * [50:40] ctr             [51] enc_phase       [52] ready_i_enc
 * [53] valid_o            [54] done_op[0]       [55] s2_prereq
 */
#include <stdint.h>
#include <stddef.h>

#define MLDSA_BASE     0x50000000ull
#define MLDSA_CTRL     0x00
#define MLDSA_DATA_IN  0x08
#define MLDSA_DATA_OUT 0x10
#define MLDSA_STATUS   0x18
#define MLDSA_DIAG     0x20

#define SEC_LVL   3
#define KG_WORDS  744

#define OFF_RHO  0
#define OFF_K    4
#define OFF_S1   8
#define OFF_S2   88
#define OFF_T1   184
#define OFF_T0   424
#define OFF_TR   736

#define S1_WORDS  80
#define S2_WORDS  96
#define T0_WORDS  312

static inline void write_reg(uint64_t off, uint64_t val) {
    *(volatile uint64_t *)(MLDSA_BASE + off) = val;
}
static inline uint64_t read_reg(uint64_t off) {
    return *(volatile uint64_t *)(MLDSA_BASE + off);
}

static int push_word_tmo(uint64_t data, uint32_t max_spins) {
    uint32_t spins = 0;
    while (read_reg(MLDSA_STATUS) & 2) {
        if (++spins > max_spins) return 0;
    }
    write_reg(MLDSA_DATA_IN, data);
    return 1;
}

static int read_word_tmo(uint64_t *out, uint32_t max_spins) {
    uint32_t spins = 0;
    while (read_reg(MLDSA_STATUS) & 4) {
        if (++spins > max_spins) return 0;
    }
    *out = read_reg(MLDSA_DATA_OUT);
    return 1;
}

static void start_op(uint32_t mode) {
    uint64_t ctrl = ((uint64_t)mode << 1) | ((uint64_t)SEC_LVL << 3);
    write_reg(MLDSA_CTRL, ctrl);
    (void)read_reg(MLDSA_STATUS);
    write_reg(MLDSA_CTRL, ctrl | 1);
    (void)read_reg(MLDSA_STATUS);
}

static volatile uint64_t phase         = 0;
static volatile uint64_t kg_result     = 0xDEAD;
static volatile uint64_t sign_result   = 0xDEAD;
static volatile uint64_t verify_result = 0xDEAD;
static volatile uint64_t sign_out_cnt  = 0;
static volatile uint64_t d0=0,d1=0,d2=0,d3=0,d4=0,d5=0,d6=0,d7=0;
static volatile uint64_t push_tmo_at = 0;

static uint64_t kg_out[KG_WORDS];
static uint64_t sign_out[420];

int main(void) {
    phase = 0; kg_result = 0xDEAD; sign_result = 0xDEAD;

    /* ======== KeyGen ======== */
    phase = 1;
    const uint64_t seed[4] = {
        0x0123456789abcdefull, 0xfedcba9876543210ull,
        0xdeadbeefcafebabeull, 0x1122334455667788ull
    };
    for (int i = 0; i < 4; i++)
        if (!push_word_tmo(seed[i], 100000)) { kg_result = 0xBAD00001; phase = 0xE1; while(1) __asm__("nop"); }
    start_op(0);
    for (int i = 0; i < KG_WORDS; i++) {
        if (!read_word_tmo(&kg_out[i], 500000)) { kg_result = 0xBAD00000ull | i; phase = 0xE1; while(1) __asm__("nop"); }
    }
    kg_result = KG_WORDS;

    /* ======== Sign ======== */
    phase = 2;
    d0 = read_reg(MLDSA_DIAG); /* before Sign */

    /* Push rho then start */
    for (int i = 0; i < 4; i++)
        if (!push_word_tmo(kg_out[OFF_RHO + i], 100000)) { sign_result = 0xBAD20001; phase = 0xE2; while(1) __asm__("nop"); }
    start_op(2);
    d1 = read_reg(MLDSA_DIAG); /* after start, before LOAD_MU pushes */

    /* Push mlen word — triggers start_geny */
    if (!push_word_tmo(32, 100000)) { sign_result = 0xBAD20002; phase = 0xE2; while(1) __asm__("nop"); }

    /* Push tr (8 words) */
    for (int i = 0; i < 8; i++)
        if (!push_word_tmo(kg_out[OFF_TR + i], 100000)) { sign_result = 0xBAD20003; phase = 0xE2; while(1) __asm__("nop"); }
    d2 = read_reg(MLDSA_DIAG); /* after tr — GenY should be in/near S_ABSORB_M */

    /* Push msg (5 words) */
    if (!push_word_tmo(0x2020202020200000ull, 100000)) { sign_result = 0xBAD20004; phase = 0xE2; while(1) __asm__("nop"); }
    for (int i = 0; i < 3; i++)
        if (!push_word_tmo(0x2020202020202020ull, 100000)) { sign_result = 0xBAD20005; phase = 0xE2; while(1) __asm__("nop"); }
    if (!push_word_tmo(0x0000000000002020ull, 100000)) { sign_result = 0xBAD20006; phase = 0xE2; while(1) __asm__("nop"); }
    d3 = read_reg(MLDSA_DIAG); /* after msg — GenY should be in S_HASH_MU or S_INIT_K */

    /* Push K (4 words) */
    for (int i = 0; i < 4; i++)
        if (!push_word_tmo(kg_out[OFF_K + i], 100000)) { sign_result = 0xBAD20007; phase = 0xE2; while(1) __asm__("nop"); }
    d4 = read_reg(MLDSA_DIAG); /* after K — GenY should be in S_ABSORB_K absorbing K */

    /* Push rnd (4 words) */
    for (int i = 0; i < 4; i++)
        if (!push_word_tmo(0, 100000)) { sign_result = 0xBAD20008; phase = 0xE2; while(1) __asm__("nop"); }
    d5 = read_reg(MLDSA_DIAG); /* after rnd — GenY should be past S_ABSORB_K */

    /* Push S1 (80 words) — during this, FSM0 is in DECODE_S1 */
    for (int i = 0; i < S1_WORDS; i++) {
        if (!push_word_tmo(kg_out[OFF_S1 + i], 500000000)) {
            sign_result = 0xBAD20009; push_tmo_at = i; phase = 0xE2;
            d6 = read_reg(MLDSA_DIAG); while(1) __asm__("nop");
        }
    }
    d6 = read_reg(MLDSA_DIAG); /* after S1 */

    /* Push S2 (96 words) */
    for (int i = 0; i < S2_WORDS; i++) {
        if (!push_word_tmo(kg_out[OFF_S2 + i], 500000000)) {
            sign_result = 0xBAD2000A; push_tmo_at = i; phase = 0xE2;
            d7 = read_reg(MLDSA_DIAG); while(1) __asm__("nop");
        }
    }
    d7 = read_reg(MLDSA_DIAG); /* after S2 */

    /* Push T0 (312 words) and read output — simplified, just stall detect */
    for (int i = 0; i < T0_WORDS; i++) {
        if (!push_word_tmo(kg_out[OFF_T0 + i], 500000000)) {
            sign_result = 0xBAD2000B; push_tmo_at = i; phase = 0xE2; while(1) __asm__("nop");
        }
    }

    /* Try to read output — expect stall */
    {
        uint32_t spins = 0;
        while (read_reg(MLDSA_STATUS) & 4) {
            if (++spins > 500000000) {
                sign_result = 0xBAD20FFF;
                phase = 0xE2; while(1) __asm__("nop");
            }
        }
        sign_out[0] = read_reg(MLDSA_DATA_OUT);
    }

    sign_out_cnt = 1;
    sign_result = 1;
    phase = 6;
    while(1) __asm__("nop");
    return 0;
}
