/*
 * ML-DSA-65 Full Test: KeyGen -> Sign -> Verify
 * Runs all three phases on FPGA and reports results.
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
#define MSG_BYTES 32
#define T1_WORDS  240
#define SIG_Z_WORDS 400
#define SIG_H_WORDS 8
#define SIG_C_WORDS 6
#define SIG_TOTAL_WORDS (SIG_Z_WORDS + SIG_H_WORDS + SIG_C_WORDS)

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
static volatile uint64_t ver_diag      = 0;
static volatile uint64_t sign_step    = 0;
static volatile uint64_t sign_diag    = 0;
static volatile uint64_t sign_status  = 0;
static volatile uint64_t sign_diag_pre = 0;  /* DIAG right after start */
static volatile uint64_t sign_status_pre = 0; /* STATUS right before output read */
static volatile uint64_t sign_diag_mid = 0;  /* DIAG snapshot during S2 push */
static volatile uint64_t sign_diag_post_input = 0; /* DIAG after all input pushed */
static volatile uint64_t ver_t1_count   = 0;  /* T1 words actually pushed */
static volatile uint64_t ver_c_diag    = 0;  /* C register first word from compare */

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

    /* Store keygen TR first word for comparison with verify TR */
    sign_diag = kg_out[OFF_TR + 0];

    /* ======== PHASE 2: Sign ======== */
    phase = 2;

    /* Push rho (4 words) BEFORE start */
    sign_step = 1;
    for (int i = 0; i < 4; i++)
        if (!push_word_tmo(kg_out[OFF_RHO + i], 100000)) { sign_result = 0xBAD20001; phase = 0xE2; while(1) __asm__("nop"); }

    sign_step = 2;
    start_op(2);

    /* Snapshot DIAG right after Sign start to see initial FSM state */
    sign_diag_pre = read_reg(MLDSA_DIAG);

    /* Push mlen (1 word: mlen + ctxlen = 32 + 0) */
    sign_step = 3;
    if (!push_word_tmo(32, 100000)) { sign_result = 0xBAD20002; phase = 0xE2; while(1) __asm__("nop"); }

    /* Push tr (8 words) */
    sign_step = 4;
    for (int i = 0; i < 8; i++)
        if (!push_word_tmo(kg_out[OFF_TR + i], 100000)) { sign_result = 0xBAD20003; phase = 0xE2; while(1) __asm__("nop"); }

    /* Push formatted message (5 words) */
    sign_step = 5;
    if (!push_word_tmo(0x2020202020200000ull, 100000)) { sign_result = 0xBAD20004; phase = 0xE2; while(1) __asm__("nop"); }
    for (int i = 0; i < 3; i++)
        if (!push_word_tmo(0x2020202020202020ull, 100000)) { sign_result = 0xBAD20005; phase = 0xE2; while(1) __asm__("nop"); }
    if (!push_word_tmo(0x0000000000002020ull, 100000)) { sign_result = 0xBAD20006; phase = 0xE2; while(1) __asm__("nop"); }

    /* Push K (4 words) */
    sign_step = 6;
    for (int i = 0; i < 4; i++)
        if (!push_word_tmo(kg_out[OFF_K + i], 100000)) { sign_result = 0xBAD20007; phase = 0xE2; while(1) __asm__("nop"); }

    /* Push rnd (4 words of 0) */
    sign_step = 7;
    for (int i = 0; i < 4; i++)
        if (!push_word_tmo(0, 100000)) { sign_result = 0xBAD20008; phase = 0xE2; while(1) __asm__("nop"); }

    /* Push S1 (80 words) */
    sign_step = 8;
    for (int i = 0; i < S1_WORDS; i++)
        if (!push_word_tmo(kg_out[OFF_S1 + i], 500000)) { sign_result = 0xBAD20009; phase = 0xE2; while(1) __asm__("nop"); }

    /* Push S2 (96 words) */
    sign_step = 9;
    for (int i = 0; i < S2_WORDS; i++)
        if (!push_word_tmo(kg_out[OFF_S2 + i], 500000)) { sign_result = 0xBAD2000A; phase = 0xE2; while(1) __asm__("nop"); }

    /* Snapshot DIAG after S2 push — check if cstart_fsm1 has fired */
    sign_diag_mid = read_reg(MLDSA_DIAG);

    /* Push T0 (312 words) */
    sign_step = 10;
    for (int i = 0; i < T0_WORDS; i++)
        if (!push_word_tmo(kg_out[OFF_T0 + i], 500000)) { sign_result = 0xBAD2000B; phase = 0xE2; while(1) __asm__("nop"); }

    /* Snapshot DIAG after all input pushed */
    sign_diag_post_input = read_reg(MLDSA_DIAG);

    /* Read Sign output: Z(400) + H(8) + C(SIG_C_WORDS) = total words */
    sign_step = 11;
    sign_status_pre = read_reg(MLDSA_STATUS);
    for (int i = 0; i < SIG_TOTAL_WORDS; i++) {
        if (!read_word_tmo(&sign_out[i], 500000)) {
            sign_diag   = read_reg(MLDSA_DIAG);
            sign_status = read_reg(MLDSA_STATUS);
            sign_result = 0xBAD20000ull | i;
            sign_step = 0xB0 | (i > 255 ? 1 : 0);
            phase = 0xE2;
            while (1) __asm__("nop");
        }
    }
    sign_out_cnt = SIG_TOTAL_WORDS;
    sign_result = SIG_TOTAL_WORDS;

    /* ======== PHASE 3: Verify ======== */
    phase = 3;

    /* Store kg_out[0] (first rho word) for comparison with RHO diagnostic */
    sign_step = kg_out[OFF_RHO + 0];
    /* Also store kg_out[184] (first T1 word) for Keccak data verification */
    ver_t1_count = kg_out[OFF_T1 + 0];

    /* Sign output order: Z(400) + H(8) + C(6) = 414
     * Verify input order: PK_rho(4) + SIG_C(6) + SIG_Z(400) + PK_T1(240) + MLEN(1) + MESSAGE(5) + SIG_H(8)
     * HW expects 6 C words for sec_lvl=3 (ctilde_out_len=384 bits = 6 words)
     */

    /* Push PK_rho (4 words) BEFORE start */
    for (int i = 0; i < 4; i++)
        if (!push_word_tmo(kg_out[OFF_RHO + i], 500000)) { verify_result = 0xBAD30001; phase = 0xE3; while(1) __asm__("nop"); }

    start_op(1);

    /* Push SIG_C (6 words) */
    for (int i = 0; i < SIG_C_WORDS; i++)
        if (!push_word_tmo(sign_out[SIG_Z_WORDS + SIG_H_WORDS + i], 500000)) { verify_result = 0xBAD30002; phase = 0xE3; while(1) __asm__("nop"); }

    /* Push SIG_Z (400 words) */
    for (int i = 0; i < SIG_Z_WORDS; i++)
        if (!push_word_tmo(sign_out[i], 500000)) { verify_result = 0xBAD30003ull | (uint64_t)i << 16; ver_diag = read_reg(MLDSA_DIAG); phase = 0xE3; while(1) __asm__("nop"); }

    /* Push PK_T1 (240 words) — use short timeout, skip to result if FIFO full */
    {
        int t1_ok = 1;
        for (int i = 0; i < T1_WORDS && t1_ok; i++) {
            if (!push_word_tmo(kg_out[OFF_T1 + i], 500000)) {
                ver_t1_count = i;
                t1_ok = 0;
            }
        }
        if (t1_ok) ver_t1_count = T1_WORDS;
    }
    ver_diag = read_reg(MLDSA_DIAG);

    /* Skip MLEN/MSG/SIG_H pushes if T1 didn't complete — read result directly */
    if (ver_t1_count == T1_WORDS) {
        /* Push MLEN (1 word): mlen + ctxlen = 32 + 0 = 32 */
        if (!push_word_tmo(32, 500000)) { verify_result = 0xBAD30005; ver_diag = read_reg(MLDSA_DIAG); phase = 0xE3; while(1) __asm__("nop"); }

        /* Push formatted MESSAGE (5 words) */
        if (!push_word_tmo(0x2020202020200000ull, 500000)) { verify_result = 0xBAD30006; phase = 0xE3; while(1) __asm__("nop"); }
        for (int i = 0; i < 3; i++)
            if (!push_word_tmo(0x2020202020202020ull, 500000)) { verify_result = 0xBAD30007; phase = 0xE3; while(1) __asm__("nop"); }
        if (!push_word_tmo(0x0000000000002020ull, 500000)) { verify_result = 0xBAD30008; phase = 0xE3; while(1) __asm__("nop"); }

        /* Push SIG_H (8 words) */
        for (int i = 0; i < SIG_H_WORDS; i++)
            if (!push_word_tmo(sign_out[SIG_Z_WORDS + i], 500000)) { verify_result = 0xBAD30009; ver_diag = read_reg(MLDSA_DIAG); phase = 0xE3; while(1) __asm__("nop"); }

        ver_diag = read_reg(MLDSA_DIAG);
    }

    /* Read Verify result (7 words: tr_diag, mu_diag, dout_diag, c_diag, fail, rho_diag, ctr0_diag) */
    {
        uint64_t tr_diag = 0;
        uint64_t mu_diag = 0;
        uint64_t dout_diag = 0;
        uint64_t c_diag = 0;
        uint64_t verif_out = 0;
        uint64_t rho_diag = 0;
        uint64_t ctr0_diag = 0;
        if (!read_word_tmo(&tr_diag, 5000000)) {
            ver_diag = read_reg(MLDSA_DIAG);
            verify_result = 0xBAD30010;
            phase = 0xE3;
            while (1) __asm__("nop");
        }
        if (!read_word_tmo(&mu_diag, 5000000)) {
            ver_diag = read_reg(MLDSA_DIAG);
            verify_result = 0xBAD30011;
            phase = 0xE3;
            while (1) __asm__("nop");
        }
        if (!read_word_tmo(&dout_diag, 5000000)) {
            ver_diag = read_reg(MLDSA_DIAG);
            verify_result = 0xBAD30012;
            phase = 0xE3;
            while (1) __asm__("nop");
        }
        if (!read_word_tmo(&c_diag, 5000000)) {
            ver_diag = read_reg(MLDSA_DIAG);
            verify_result = 0xBAD30013;
            phase = 0xE3;
            while (1) __asm__("nop");
        }
        if (!read_word_tmo(&verif_out, 5000000)) {
            ver_diag = read_reg(MLDSA_DIAG);
            verify_result = 0xBAD30014;
            phase = 0xE3;
            while (1) __asm__("nop");
        }
        if (!read_word_tmo(&rho_diag, 5000000)) {
            ver_diag = read_reg(MLDSA_DIAG);
            verify_result = 0xBAD30015;
            phase = 0xE3;
            while (1) __asm__("nop");
        }
        if (!read_word_tmo(&ctr0_diag, 5000000)) {
            ver_diag = read_reg(MLDSA_DIAG);
            verify_result = 0xBAD30016;
            phase = 0xE3;
            while (1) __asm__("nop");
        }
        verify_result = verif_out;
        ver_diag = tr_diag;
        ver_c_diag = mu_diag;
        sign_diag_pre = dout_diag;
        sign_diag_mid = c_diag;
        sign_diag_post_input = rho_diag;   /* RHO[255:192] at VY_DECODE_Z ctr0==2 */
        sign_status = ctr0_diag;            /* ctr0 at VY_NTT_Z->VY_NTT_T1 transition */
    }
    phase = 6;
    while (1) __asm__("nop");
    return 0;
}
