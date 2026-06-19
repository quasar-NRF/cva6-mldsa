// ==================================================
// Giulio Golinelli - golinelli.giulio13@gmail.com
// TUMCREATE QUASAR RESEARCH ENGINEER
// Modified: 2026-06-17
// This file contains modifications vs. the upstream
// CVA6 / ML-DSA-OSH source fork.
// ==================================================

/*
 * ML-DSA KAT Verify Test (all 3 security levels)
 * TUMCREATE (2026-06-18): parameterized via -DSEC_LVL=X (X=2|3|5).
 * Feeds known-answer test vectors directly to the verify pipeline.
 * If this passes, the verify HW works and the bug is in KeyGen/Sign.
 * If this fails, the verify HW has a bug.
 */

#include <stdint.h>
#include <stddef.h>

// TUMCREATE (2026-06-18): allow compile-time override via -DSEC_LVL=X for multi-level testing
#ifndef SEC_LVL
#define SEC_LVL   3
#endif

// TUMCREATE (2026-06-18): per-sec_lvl KAT data header (auto-generated from NIST KAT files)
#if   SEC_LVL == 2
#  include "mldsa_kat_verify_data_2.h"
#elif SEC_LVL == 5
#  include "mldsa_kat_verify_data_5.h"
#else
#  include "mldsa_kat_verify_data_3.h"
#endif

#define MLDSA_BASE     0x50000000ull
#define MLDSA_CTRL     0x00
#define MLDSA_DATA_IN  0x08
#define MLDSA_DATA_OUT 0x10
#define MLDSA_STATUS   0x18
#define MLDSA_DIAG     0x20

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
static volatile uint64_t verify_result = 0xDEAD;
static volatile uint64_t diag          = 0;
static volatile uint64_t fail_step     = 0;
static volatile uint64_t diag_after_start    = 0;
static volatile uint64_t diag_after_rho      = 0;
static volatile uint64_t diag_after_sigc     = 0;
static volatile uint64_t diag_after_sigz     = 0;
static volatile uint64_t diag_after_t1       = 0;
static volatile uint64_t diag_after_msg      = 0;
static volatile uint64_t diag_after_sigh     = 0;
static volatile uint64_t diag_final          = 0;

int main(void) {
    phase = 1;

    /* Push PK_rho (4 words) BEFORE start */
    for (int i = 0; i < 4; i++)
        if (!push_word_tmo(kat_pk_rho[i], 500000)) {
            verify_result = 0xBAD00001;
            phase = 0xE1;
            while(1) __asm__("nop");
        }

    start_op(1);

    /* Snapshot DIAG after start to see FSM state */
    diag_after_start = read_reg(MLDSA_DIAG);

    /* Push SIG_C (KAT_SIG_C_WORDS words) */
    fail_step = 2;
    for (int i = 0; i < KAT_SIG_C_WORDS; i++)
        if (!push_word_tmo(kat_sig_c[i], 500000)) {
            verify_result = 0xBAD00002;
            diag = read_reg(MLDSA_STATUS);
            phase = 0xE1;
            while(1) __asm__("nop");
        }
    diag_after_sigc = read_reg(MLDSA_DIAG);

    /* Push SIG_Z (KAT_SIG_Z_WORDS words) */
    fail_step = 3;
    for (int i = 0; i < KAT_SIG_Z_WORDS; i++)
        if (!push_word_tmo(kat_sig_z[i], 500000)) {
            verify_result = 0xBAD00003ull | ((uint64_t)i << 16);
            diag = read_reg(MLDSA_STATUS);
            phase = 0xE1;
            while(1) __asm__("nop");
        }
    diag_after_sigz = read_reg(MLDSA_DIAG);

    /* Push PK_T1 (KAT_PK_T1_WORDS words) */
    fail_step = 4;
    for (int i = 0; i < KAT_PK_T1_WORDS; i++)
        if (!push_word_tmo(kat_pk_t1[i], 500000)) {
            verify_result = 0xBAD00004ull | ((uint64_t)i << 16);
            phase = 0xE1;
            while(1) __asm__("nop");
        }
    diag_after_t1 = read_reg(MLDSA_DIAG);

    /* Push MLEN (1 word): mlen + ctxlen */
    fail_step = 5;
    if (!push_word_tmo(kat_mlen, 500000)) {
        verify_result = 0xBAD00005;
        phase = 0xE1;
        while(1) __asm__("nop");
    }

    /* Push formatted MESSAGE */
    fail_step = 6;
    for (int i = 0; i < KAT_FMTD_WORDS; i++)
        if (!push_word_tmo(kat_fmtd_msg[i], 500000)) {
            verify_result = 0xBAD00006ull | ((uint64_t)i << 16);
            phase = 0xE1;
            while(1) __asm__("nop");
        }
    diag_after_msg = read_reg(MLDSA_DIAG);

    /* Push SIG_H (KAT_SIG_H_WORDS words) */
    fail_step = 7;
    for (int i = 0; i < KAT_SIG_H_WORDS; i++)
        if (!push_word_tmo(kat_sig_h[i], 500000)) {
            verify_result = 0xBAD00007;
            diag = read_reg(MLDSA_STATUS);
            phase = 0xE1;
            while(1) __asm__("nop");
        }
    diag_after_sigh = read_reg(MLDSA_DIAG);

    /* TUMCREATE (2026-06-18): HW outputs exactly ONE fail-bit word (0=valid, 1=invalid).
     * Previous C test expected 7 diagnostic words, but that diagnostic output was reverted
     * in combined_top.v VY_COMPARE — only {63'd0, fail} is emitted, valid_o asserts once
     * at ctr=4/6/8 for sec_lvl=2/3/5. */
    fail_step = 8;
    uint64_t hw_fail_word = 0xDEAD;
    if (!read_word_tmo(&hw_fail_word, 2000000)) {
        verify_result = 0xBAD00010;
        diag = read_reg(MLDSA_STATUS);
        diag_final = read_reg(MLDSA_DIAG);
        diag_after_start = read_reg(MLDSA_DIAG);  /* FSM state at hang */
        diag_after_sigc  = read_reg(MLDSA_STATUS); /* bridge status at hang */
        phase = 0xE1;
        while (1) __asm__("nop");
    }

    diag_after_start = hw_fail_word;  /* raw fail word for debug visibility */

    uint64_t hw_fail    = hw_fail_word & 1ULL;
    uint64_t api_result = (hw_fail == 0) ? 1ULL : 0ULL;  /* API: 1=valid, 0=invalid */

    verify_result = api_result;
    fail_step     = ~hw_fail_word;  /* overload: shows raw word + bit pattern for debug */

    /* phase=6 iff api_result matches KAT_EXPECTED */
    phase = (api_result == KAT_EXPECTED) ? 6 : 0xE3;
    while (1) __asm__("nop");
    return 0;
}
