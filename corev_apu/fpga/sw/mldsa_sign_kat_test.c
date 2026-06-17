// ==================================================
// Giulio Golinelli - golinelli.giulio13@gmail.com
// TUMCREATE QUASAR RESEARCH ENGINEER
// Modified: 2026-06-17
// This file contains modifications vs. the upstream
// CVA6 / ML-DSA-OSH source fork.
// ==================================================

/*
 * ML-DSA-65 Sign KAT Test
 * Pushes NIST KAT sk + message to Sign, compares output with KAT signature.
 * Uses rnd=0 (deterministic), so output should match KAT sig exactly.
 * If output matches KAT sig: Sign works correctly in integration.
 * If output differs: Sign FSM has integration bug.
 */

#include <stdint.h>
#include <stddef.h>

#include "mldsa_sign_kat_data.h"

#define MLDSA_BASE     0x50000000ull
#define MLDSA_CTRL     0x00
#define MLDSA_DATA_IN  0x08
#define MLDSA_DATA_OUT 0x10
#define MLDSA_STATUS   0x18
#define MLDSA_DIAG     0x20

#define SEC_LVL   3

#define S1_WORDS  80
#define S2_WORDS  96
#define T0_WORDS  312
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
static volatile uint64_t sign_result   = 0xDEAD;
static volatile uint64_t sign_out_cnt  = 0;
static volatile uint64_t sign_step     = 0;
static volatile uint64_t z_match       = 0xDEAD;
static volatile uint64_t h_match       = 0xDEAD;
static volatile uint64_t c_match       = 0xDEAD;
static volatile uint64_t first_mismatch_idx = 0xDEAD;
static volatile uint64_t first_mismatch_exp = 0xDEAD;
static volatile uint64_t first_mismatch_got = 0xDEAD;
static volatile uint64_t c_got0        = 0;
static volatile uint64_t c_got1        = 0;
static volatile uint64_t c_got2        = 0;
static volatile uint64_t c_got3        = 0;
static volatile uint64_t c_got4        = 0;
static volatile uint64_t c_got5        = 0;
static volatile uint64_t z_got0        = 0;
static volatile uint64_t h_got0        = 0;
static volatile uint64_t sign_diag_pre  = 0;
static volatile uint64_t sign_diag_mid  = 0;
static volatile uint64_t sign_diag_post = 0;

static uint64_t sign_out[SIG_TOTAL_WORDS + 8];

int main(void) {
    phase = 1;

    /* Push rho (4 words) BEFORE start */
    sign_step = 1;
    for (int i = 0; i < 4; i++)
        if (!push_word_tmo(kat_sk_rho[i], 500000)) {
            sign_result = 0xBAD20001;
            phase = 0xE1;
            while(1) __asm__("nop");
        }

    sign_step = 2;
    start_op(2);

    sign_diag_pre = read_reg(MLDSA_DIAG);

    /* Push MLEN (1 word): mlen + ctxlen */
    sign_step = 3;
    if (!push_word_tmo(KAT_MLEN_WORD, 500000)) {
        sign_result = 0xBAD20002;
        phase = 0xE1;
        while(1) __asm__("nop");
    }

    /* Push tr (8 words) */
    sign_step = 4;
    for (int i = 0; i < 8; i++)
        if (!push_word_tmo(kat_sk_tr[i], 500000)) {
            sign_result = 0xBAD20003;
            phase = 0xE1;
            while(1) __asm__("nop");
        }

    /* Push formatted message (KAT_FMTD_WORDS words) */
    sign_step = 5;
    for (int i = 0; i < KAT_FMTD_WORDS; i++)
        if (!push_word_tmo(kat_fmtd_msg[i], 500000)) {
            sign_result = 0xBAD20004ull | ((uint64_t)i << 16);
            phase = 0xE1;
            while(1) __asm__("nop");
        }

    /* Push K (4 words) */
    sign_step = 6;
    for (int i = 0; i < 4; i++)
        if (!push_word_tmo(kat_sk_k[i], 500000)) {
            sign_result = 0xBAD20005;
            phase = 0xE1;
            while(1) __asm__("nop");
        }

    /* Push rnd (4 words of 0) */
    sign_step = 7;
    for (int i = 0; i < 4; i++)
        if (!push_word_tmo(0, 500000)) {
            sign_result = 0xBAD20006;
            phase = 0xE1;
            while(1) __asm__("nop");
        }

    /* Push S1 (80 words) */
    sign_step = 8;
    for (int i = 0; i < S1_WORDS; i++)
        if (!push_word_tmo(kat_sk_s1[i], 500000)) {
            sign_result = 0xBAD20007ull | ((uint64_t)i << 16);
            phase = 0xE1;
            while(1) __asm__("nop");
        }

    /* Push S2 (96 words) */
    sign_step = 9;
    for (int i = 0; i < S2_WORDS; i++)
        if (!push_word_tmo(kat_sk_s2[i], 500000)) {
            sign_result = 0xBAD20008ull | ((uint64_t)i << 16);
            phase = 0xE1;
            while(1) __asm__("nop");
        }

    sign_diag_mid = read_reg(MLDSA_DIAG);

    /* Push T0 (312 words) */
    sign_step = 10;
    for (int i = 0; i < T0_WORDS; i++)
        if (!push_word_tmo(kat_sk_t0[i], 500000)) {
            sign_result = 0xBAD20009ull | ((uint64_t)i << 16);
            phase = 0xE1;
            while(1) __asm__("nop");
        }

    sign_diag_post = read_reg(MLDSA_DIAG);

    /* Read Sign output: Z(400) + H(8) + C(6) = 414 words */
    sign_step = 11;
    for (int i = 0; i < SIG_TOTAL_WORDS; i++) {
        if (!read_word_tmo(&sign_out[i], 5000000)) {
            sign_result = 0xBAD20000ull | i;
            phase = 0xE1;
            while (1) __asm__("nop");
        }
    }
    sign_out_cnt = SIG_TOTAL_WORDS;
    sign_result = SIG_TOTAL_WORDS;

    /* Expose first words for diagnostic */
    z_got0 = sign_out[0];
    h_got0 = sign_out[SIG_Z_WORDS];
    c_got0 = sign_out[SIG_Z_WORDS + SIG_H_WORDS + 0];
    c_got1 = sign_out[SIG_Z_WORDS + SIG_H_WORDS + 1];
    c_got2 = sign_out[SIG_Z_WORDS + SIG_H_WORDS + 2];
    c_got3 = sign_out[SIG_Z_WORDS + SIG_H_WORDS + 3];
    c_got4 = sign_out[SIG_Z_WORDS + SIG_H_WORDS + 4];
    c_got5 = sign_out[SIG_Z_WORDS + SIG_H_WORDS + 5];

    /* Compare Z with expected */
    z_match = 1;
    first_mismatch_idx = 0xFFFFFFFFFFFFFFFFULL;
    for (int i = 0; i < SIG_Z_WORDS; i++) {
        if (sign_out[i] != kat_exp_z[i]) {
            z_match = 0;
            first_mismatch_idx = i;
            first_mismatch_exp = kat_exp_z[i];
            first_mismatch_got = sign_out[i];
            break;
        }
    }

    /* Compare H with expected (only if Z matched) */
    if (z_match) {
        h_match = 1;
        for (int i = 0; i < SIG_H_WORDS; i++) {
            if (sign_out[SIG_Z_WORDS + i] != kat_exp_h[i]) {
                h_match = 0;
                first_mismatch_idx = 0x10000 + i;
                first_mismatch_exp = kat_exp_h[i];
                first_mismatch_got = sign_out[SIG_Z_WORDS + i];
                break;
            }
        }
    } else {
        h_match = 0xDEAD;
    }

    /* Compare C with expected (only if Z and H matched) */
    if (z_match && h_match) {
        c_match = 1;
        for (int i = 0; i < SIG_C_WORDS; i++) {
            if (sign_out[SIG_Z_WORDS + SIG_H_WORDS + i] != kat_exp_c[i]) {
                c_match = 0;
                first_mismatch_idx = 0x20000 + i;
                first_mismatch_exp = kat_exp_c[i];
                first_mismatch_got = sign_out[SIG_Z_WORDS + SIG_H_WORDS + i];
                break;
            }
        }
    } else {
        c_match = 0xDEAD;
    }

    phase = (z_match && h_match && c_match) ? 6 : 0xE2;
    while (1) __asm__("nop");
    return 0;
}
