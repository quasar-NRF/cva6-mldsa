/*
 * Verify pipeline diagnostic: captures FSM state at each transition point.
 * Runs KeyGen + Sign first, then verifies with detailed diagnostics.
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

/* Result variables */
static volatile uint64_t phase = 0;
static volatile uint64_t kg_result = 0xDEAD;
static volatile uint64_t sign_result = 0xDEAD;
static volatile uint64_t verify_result = 0xDEAD;

/* Verify pipeline diagnostics: diag snapshots at key points */
static volatile uint64_t d1_start = 0;      /* after verify start */
static volatile uint64_t d2_after_c = 0;    /* after pushing SIG_C */
static volatile uint64_t d3_after_z = 0;    /* after pushing SIG_Z */
static volatile uint64_t d4_mid_t1 = 0;     /* after pushing 120 T1 words */
static volatile uint64_t d5_after_t1 = 0;    /* after pushing all T1 */
static volatile uint64_t d6_after_msg = 0;   /* after pushing mlen+msg */
static volatile uint64_t d7_after_h = 0;     /* after pushing SIG_H */
static volatile uint64_t d8_pre_result = 0;  /* before reading result */

/* Verify result diagnostics */
static volatile uint64_t vr_tr = 0;
static volatile uint64_t vr_mu = 0;
static volatile uint64_t vr_dout = 0;
static volatile uint64_t vr_c = 0;
static volatile uint64_t vr_fail = 0;
static volatile uint64_t vr_rho = 0;
static volatile uint64_t vr_ctr0 = 0;

/* KeyGen first words for cross-check */
static volatile uint64_t kg_rho0 = 0;
static volatile uint64_t kg_t1_0 = 0;
static volatile uint64_t kg_tr_0 = 0;

static uint64_t kg_out[KG_WORDS];
static uint64_t sign_out[SIG_TOTAL_WORDS + 100];

int main(void) {
    /* ======== KeyGen ======== */
    phase = 1;
    const uint64_t seed[4] = {
        0x0123456789abcdefull, 0xfedcba9876543210ull,
        0xdeadbeefcafebabeull, 0x1122334455667788ull
    };
    for (int i = 0; i < 4; i++)
        if (!push_word_tmo(seed[i], 100000)) { kg_result = 0xBAD00001; while(1) __asm__("nop"); }
    start_op(0);
    for (int i = 0; i < KG_WORDS; i++)
        if (!read_word_tmo(&kg_out[i], 200000)) { kg_result = 0xBAD00000ull | i; while(1) __asm__("nop"); }
    kg_result = KG_WORDS;
    kg_rho0 = kg_out[0];
    kg_t1_0 = kg_out[OFF_T1];
    kg_tr_0 = kg_out[OFF_TR];

    /* ======== Sign ======== */
    phase = 2;
    for (int i = 0; i < 4; i++)
        if (!push_word_tmo(kg_out[OFF_RHO + i], 100000)) { sign_result = 0xBAD20001; while(1) __asm__("nop"); }
    start_op(2);
    if (!push_word_tmo(32, 100000)) { sign_result = 0xBAD20002; while(1) __asm__("nop"); }
    for (int i = 0; i < 8; i++)
        if (!push_word_tmo(kg_out[OFF_TR + i], 100000)) { sign_result = 0xBAD20003; while(1) __asm__("nop"); }
    if (!push_word_tmo(0x2020202020200000ull, 100000)) { sign_result = 0xBAD20004; while(1) __asm__("nop"); }
    for (int i = 0; i < 3; i++)
        if (!push_word_tmo(0x2020202020202020ull, 100000)) { sign_result = 0xBAD20005; while(1) __asm__("nop"); }
    if (!push_word_tmo(0x0000000000002020ull, 100000)) { sign_result = 0xBAD20006; while(1) __asm__("nop"); }
    for (int i = 0; i < 4; i++)
        if (!push_word_tmo(kg_out[OFF_K + i], 100000)) { sign_result = 0xBAD20007; while(1) __asm__("nop"); }
    for (int i = 0; i < 4; i++)
        if (!push_word_tmo(0, 100000)) { sign_result = 0xBAD20008; while(1) __asm__("nop"); }
    for (int i = 0; i < S1_WORDS; i++)
        if (!push_word_tmo(kg_out[OFF_S1 + i], 500000)) { sign_result = 0xBAD20009; while(1) __asm__("nop"); }
    for (int i = 0; i < S2_WORDS; i++)
        if (!push_word_tmo(kg_out[OFF_S2 + i], 500000)) { sign_result = 0xBAD2000A; while(1) __asm__("nop"); }
    for (int i = 0; i < T0_WORDS; i++)
        if (!push_word_tmo(kg_out[OFF_T0 + i], 500000)) { sign_result = 0xBAD2000B; while(1) __asm__("nop"); }
    for (int i = 0; i < SIG_TOTAL_WORDS; i++)
        if (!read_word_tmo(&sign_out[i], 500000)) { sign_result = 0xBAD20000ull | i; while(1) __asm__("nop"); }
    sign_result = SIG_TOTAL_WORDS;

    /* ======== Verify with diagnostics ======== */
    phase = 3;

    /* Push rho (4 words) BEFORE start */
    for (int i = 0; i < 4; i++)
        if (!push_word_tmo(kg_out[OFF_RHO + i], 500000)) { verify_result = 0xBAD30001; while(1) __asm__("nop"); }

    start_op(1);
    d1_start = read_reg(MLDSA_DIAG);

    /* Push SIG_C (6 words) */
    for (int i = 0; i < SIG_C_WORDS; i++)
        if (!push_word_tmo(sign_out[SIG_Z_WORDS + SIG_H_WORDS + i], 500000)) { verify_result = 0xBAD30002; while(1) __asm__("nop"); }
    d2_after_c = read_reg(MLDSA_DIAG);

    /* Push SIG_Z (400 words) */
    for (int i = 0; i < SIG_Z_WORDS; i++)
        if (!push_word_tmo(sign_out[i], 500000)) { verify_result = 0xBAD30003ull | (uint64_t)i << 16; while(1) __asm__("nop"); }
    d3_after_z = read_reg(MLDSA_DIAG);

    /* Push PK_T1 (240 words) — capture mid-way */
    for (int i = 0; i < T1_WORDS; i++) {
        if (!push_word_tmo(kg_out[OFF_T1 + i], 500000)) { verify_result = 0xBAD30004; while(1) __asm__("nop"); }
        if (i == 119) d4_mid_t1 = read_reg(MLDSA_DIAG);
    }
    d5_after_t1 = read_reg(MLDSA_DIAG);

    /* Push MLEN + MESSAGE */
    if (!push_word_tmo(32, 500000)) { verify_result = 0xBAD30005; while(1) __asm__("nop"); }
    if (!push_word_tmo(0x2020202020200000ull, 500000)) { verify_result = 0xBAD30006; while(1) __asm__("nop"); }
    for (int i = 0; i < 3; i++)
        if (!push_word_tmo(0x2020202020202020ull, 500000)) { verify_result = 0xBAD30007; while(1) __asm__("nop"); }
    if (!push_word_tmo(0x0000000000002020ull, 500000)) { verify_result = 0xBAD30008; while(1) __asm__("nop"); }
    d6_after_msg = read_reg(MLDSA_DIAG);

    /* Push SIG_H (8 words) */
    for (int i = 0; i < SIG_H_WORDS; i++)
        if (!push_word_tmo(sign_out[SIG_Z_WORDS + i], 500000)) { verify_result = 0xBAD30009; while(1) __asm__("nop"); }
    d7_after_h = read_reg(MLDSA_DIAG);

    /* Wait a bit for pipeline to process, then snapshot */
    for (volatile int i = 0; i < 1000; i++) __asm__("nop");
    d8_pre_result = read_reg(MLDSA_DIAG);

    /* Read 7 diagnostic words */
    {
        uint64_t t = 0, m = 0, d = 0, c = 0, f = 0, r = 0, z = 0;
        if (!read_word_tmo(&t, 5000000)) { verify_result = 0xBAD30010; while(1) __asm__("nop"); }
        if (!read_word_tmo(&m, 5000000)) { verify_result = 0xBAD30011; while(1) __asm__("nop"); }
        if (!read_word_tmo(&d, 5000000)) { verify_result = 0xBAD30012; while(1) __asm__("nop"); }
        if (!read_word_tmo(&c, 5000000)) { verify_result = 0xBAD30013; while(1) __asm__("nop"); }
        if (!read_word_tmo(&f, 5000000)) { verify_result = 0xBAD30014; while(1) __asm__("nop"); }
        if (!read_word_tmo(&r, 5000000)) { verify_result = 0xBAD30015; while(1) __asm__("nop"); }
        if (!read_word_tmo(&z, 5000000)) { verify_result = 0xBAD30016; while(1) __asm__("nop"); }
        vr_tr = t; vr_mu = m; vr_dout = d; vr_c = c;
        vr_fail = f; vr_rho = r; vr_ctr0 = z;
        verify_result = f;
    }

    phase = 6;
    while (1) __asm__("nop");
    return 0;
}
