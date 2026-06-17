/*
 * Quick diagnostic test to check bridge timing and data alignment.
 * Runs KeyGen, then checks accelerator state before/during Verify start.
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
#define S1_WORDS  80
#define S2_WORDS  96
#define T0_WORDS  312
#define T1_WORDS  240
#define SIG_Z_WORDS 400
#define SIG_H_WORDS 8
#define SIG_C_WORDS 6
#define SIG_TOTAL_WORDS (SIG_Z_WORDS + SIG_H_WORDS + SIG_C_WORDS)
#define MSG_BYTES 32

#define OFF_RHO  0
#define OFF_K    4
#define OFF_S1   8
#define OFF_S2   88
#define OFF_T1   184
#define OFF_T0   424
#define OFF_TR   736

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

static volatile uint64_t phase = 0;
static volatile uint64_t kg_result = 0xDEAD;
static volatile uint64_t sign_result = 0xDEAD;
static volatile uint64_t verify_result = 0xDEAD;
static volatile uint64_t sign_out_cnt = 0;

/* Diagnostics */
static volatile uint64_t status_before_rho1 = 0;
static volatile uint64_t status_after_rho4 = 0;
static volatile uint64_t status_after_start_config = 0;
static volatile uint64_t status_after_start = 0;
static volatile uint64_t diag_after_start = 0;
static volatile uint64_t ver_diag = 0;
static volatile uint64_t ver_c_diag = 0;
static volatile uint64_t sign_diag_pre = 0;
static volatile uint64_t sign_diag_mid = 0;
static volatile uint64_t sign_diag_post_input = 0;
static volatile uint64_t sign_status = 0;

static uint64_t kg_out[KG_WORDS];
static uint64_t sign_out[SIG_TOTAL_WORDS + 100];

int main(void) {
    /* ======== PHASE 1: KeyGen ======== */
    phase = 1;
    const uint64_t seed[4] = {
        0x0123456789abcdefull,
        0xfedcba9876543210ull,
        0xdeadbeefcafebabeull,
        0x1122334455667788ull
    };

    for (int i = 0; i < 4; i++)
        if (!push_word_tmo(seed[i], 100000)) { kg_result = 0xBAD00001; phase = 0xE1; while(1) __asm__("nop"); }

    start_op(0);

    for (int i = 0; i < KG_WORDS; i++) {
        if (!read_word_tmo(&kg_out[i], 200000)) {
            kg_result = 0xBAD00000ull | i;
            phase = 0xE1;
            while (1) __asm__("nop");
        }
    }
    kg_result = KG_WORDS;

    /* ======== PHASE 2: Sign ======== */
    phase = 2;

    for (int i = 0; i < 4; i++)
        if (!push_word_tmo(kg_out[OFF_RHO + i], 100000)) { sign_result = 0xBAD20001; phase = 0xE2; while(1) __asm__("nop"); }

    start_op(2);

    sign_diag_pre = read_reg(MLDSA_DIAG);

    if (!push_word_tmo(32, 100000)) { sign_result = 0xBAD20002; phase = 0xE2; while(1) __asm__("nop"); }

    for (int i = 0; i < 8; i++)
        if (!push_word_tmo(kg_out[OFF_TR + i], 100000)) { sign_result = 0xBAD20003; phase = 0xE2; while(1) __asm__("nop"); }

    if (!push_word_tmo(0x2020202020200000ull, 100000)) { sign_result = 0xBAD20004; phase = 0xE2; while(1) __asm__("nop"); }
    for (int i = 0; i < 3; i++)
        if (!push_word_tmo(0x2020202020202020ull, 100000)) { sign_result = 0xBAD20005; phase = 0xE2; while(1) __asm__("nop"); }
    if (!push_word_tmo(0x0000000000002020ull, 100000)) { sign_result = 0xBAD20006; phase = 0xE2; while(1) __asm__("nop"); }

    for (int i = 0; i < 4; i++)
        if (!push_word_tmo(kg_out[OFF_K + i], 100000)) { sign_result = 0xBAD20007; phase = 0xE2; while(1) __asm__("nop"); }

    for (int i = 0; i < 4; i++)
        if (!push_word_tmo(0, 100000)) { sign_result = 0xBAD20008; phase = 0xE2; while(1) __asm__("nop"); }

    for (int i = 0; i < S1_WORDS; i++)
        if (!push_word_tmo(kg_out[OFF_S1 + i], 500000)) { sign_result = 0xBAD20009; phase = 0xE2; while(1) __asm__("nop"); }

    for (int i = 0; i < S2_WORDS; i++)
        if (!push_word_tmo(kg_out[OFF_S2 + i], 500000)) { sign_result = 0xBAD2000A; phase = 0xE2; while(1) __asm__("nop"); }

    sign_diag_mid = read_reg(MLDSA_DIAG);

    for (int i = 0; i < T0_WORDS; i++)
        if (!push_word_tmo(kg_out[OFF_T0 + i], 500000)) { sign_result = 0xBAD2000B; phase = 0xE2; while(1) __asm__("nop"); }

    sign_diag_post_input = read_reg(MLDSA_DIAG);

    for (int i = 0; i < SIG_TOTAL_WORDS; i++) {
        if (!read_word_tmo(&sign_out[i], 500000)) {
            sign_diag_pre = read_reg(MLDSA_DIAG);
            sign_status = read_reg(MLDSA_STATUS);
            sign_result = 0xBAD20000ull | i;
            phase = 0xE2;
            while (1) __asm__("nop");
        }
    }
    sign_out_cnt = SIG_TOTAL_WORDS;
    sign_result = SIG_TOTAL_WORDS;

    /* ======== PHASE 3: Verify with timing diagnostics ======== */
    phase = 3;

    /* Check STATUS before pushing anything */
    status_before_rho1 = read_reg(MLDSA_STATUS);

    /* Push PK_rho (4 words) BEFORE start */
    for (int i = 0; i < 4; i++)
        if (!push_word_tmo(kg_out[OFF_RHO + i], 500000)) { verify_result = 0xBAD30001; phase = 0xE3; while(1) __asm__("nop"); }

    /* Check STATUS after pushing all rho */
    status_after_rho4 = read_reg(MLDSA_STATUS);

    /* Write CTRL config (mode + sec_lvl, NO start yet) */
    {
        uint64_t ctrl = ((uint64_t)1 << 1) | ((uint64_t)SEC_LVL << 3);
        write_reg(MLDSA_CTRL, ctrl);
    }

    /* Check STATUS after config write */
    status_after_start_config = read_reg(MLDSA_STATUS);

    /* Now assert start */
    {
        uint64_t ctrl = ((uint64_t)1 << 1) | ((uint64_t)SEC_LVL << 3) | 1;
        write_reg(MLDSA_CTRL, ctrl);
    }

    /* Check STATUS after start */
    status_after_start = read_reg(MLDSA_STATUS);
    diag_after_start = read_reg(MLDSA_DIAG);

    /* Push SIG_C (6 words) */
    for (int i = 0; i < SIG_C_WORDS; i++)
        if (!push_word_tmo(sign_out[SIG_Z_WORDS + SIG_H_WORDS + i], 500000)) { verify_result = 0xBAD30002; phase = 0xE3; while(1) __asm__("nop"); }

    /* Push SIG_Z (400 words) */
    for (int i = 0; i < SIG_Z_WORDS; i++)
        if (!push_word_tmo(sign_out[i], 500000)) { verify_result = 0xBAD30003ull | (uint64_t)i << 16; phase = 0xE3; while(1) __asm__("nop"); }

    /* Push PK_T1 (240 words) */
    for (int i = 0; i < T1_WORDS; i++)
        if (!push_word_tmo(kg_out[OFF_T1 + i], 500000)) { verify_result = 0xBAD30004; phase = 0xE3; while(1) __asm__("nop"); }

    /* Push MLEN (1 word) */
    if (!push_word_tmo(32, 500000)) { verify_result = 0xBAD30005; phase = 0xE3; while(1) __asm__("nop"); }

    /* Push formatted MESSAGE (5 words) */
    if (!push_word_tmo(0x2020202020200000ull, 500000)) { verify_result = 0xBAD30006; phase = 0xE3; while(1) __asm__("nop"); }
    for (int i = 0; i < 3; i++)
        if (!push_word_tmo(0x2020202020202020ull, 500000)) { verify_result = 0xBAD30007; phase = 0xE3; while(1) __asm__("nop"); }
    if (!push_word_tmo(0x0000000000002020ull, 500000)) { verify_result = 0xBAD30008; phase = 0xE3; while(1) __asm__("nop"); }

    /* Push SIG_H (8 words) */
    for (int i = 0; i < SIG_H_WORDS; i++)
        if (!push_word_tmo(sign_out[SIG_Z_WORDS + i], 500000)) { verify_result = 0xBAD30009; phase = 0xE3; while(1) __asm__("nop"); }

    ver_diag = read_reg(MLDSA_DIAG);

    /* Read Verify result (7 diagnostic words) */
    {
        uint64_t tr_diag = 0, mu_diag = 0, dout_diag = 0, c_diag = 0;
        uint64_t verif_out = 0, rho_diag = 0, ctr0_diag = 0;
        if (!read_word_tmo(&tr_diag, 5000000)) { ver_diag = read_reg(MLDSA_DIAG); verify_result = 0xBAD30010; phase = 0xE3; while(1) __asm__("nop"); }
        if (!read_word_tmo(&mu_diag, 5000000)) { verify_result = 0xBAD30011; phase = 0xE3; while(1) __asm__("nop"); }
        if (!read_word_tmo(&dout_diag, 5000000)) { verify_result = 0xBAD30012; phase = 0xE3; while(1) __asm__("nop"); }
        if (!read_word_tmo(&c_diag, 5000000)) { verify_result = 0xBAD30013; phase = 0xE3; while(1) __asm__("nop"); }
        if (!read_word_tmo(&verif_out, 5000000)) { verify_result = 0xBAD30014; phase = 0xE3; while(1) __asm__("nop"); }
        if (!read_word_tmo(&rho_diag, 5000000)) { verify_result = 0xBAD30015; phase = 0xE3; while(1) __asm__("nop"); }
        if (!read_word_tmo(&ctr0_diag, 5000000)) { verify_result = 0xBAD30016; phase = 0xE3; while(1) __asm__("nop"); }

        verify_result = verif_out;
        ver_diag = tr_diag;
        ver_c_diag = mu_diag;
        sign_diag_pre = dout_diag;
        sign_diag_mid = c_diag;
        sign_diag_post_input = rho_diag;
        sign_status = ctr0_diag;
    }

    phase = 6;
    while (1) __asm__("nop");
    return 0;
}
