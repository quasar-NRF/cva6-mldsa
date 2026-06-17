/*
 * ML-DSA-65 KAT Verify Test
 * Feeds known-answer test vectors directly to the verify pipeline.
 * If this passes, the verify HW works and the bug is in KeyGen/Sign.
 * If this fails, the verify HW has a bug.
 */

#include <stdint.h>
#include <stddef.h>

#include "mldsa_kat_verify_data.h"

#define MLDSA_BASE     0x50000000ull
#define MLDSA_CTRL     0x00
#define MLDSA_DATA_IN  0x08
#define MLDSA_DATA_OUT 0x10
#define MLDSA_STATUS   0x18
#define MLDSA_DIAG     0x20

#define SEC_LVL   3

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

    /* Push SIG_C (6 words) */
    fail_step = 2;
    for (int i = 0; i < 6; i++)
        if (!push_word_tmo(kat_sig_c[i], 500000)) {
            verify_result = 0xBAD00002;
            diag = read_reg(MLDSA_STATUS);
            phase = 0xE1;
            while(1) __asm__("nop");
        }
    diag_after_sigc = read_reg(MLDSA_DIAG);

    /* Push SIG_Z (400 words) */
    fail_step = 3;
    for (int i = 0; i < 400; i++)
        if (!push_word_tmo(kat_sig_z[i], 500000)) {
            verify_result = 0xBAD00003ull | ((uint64_t)i << 16);
            diag = read_reg(MLDSA_STATUS);
            phase = 0xE1;
            while(1) __asm__("nop");
        }
    diag_after_sigz = read_reg(MLDSA_DIAG);

    /* Push PK_T1 (240 words) */
    fail_step = 4;
    for (int i = 0; i < 240; i++)
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

    /* Push SIG_H (8 words) */
    fail_step = 7;
    for (int i = 0; i < 8; i++)
        if (!push_word_tmo(kat_sig_h[i], 500000)) {
            verify_result = 0xBAD00007;
            diag = read_reg(MLDSA_STATUS);
            phase = 0xE1;
            while(1) __asm__("nop");
        }
    diag_after_sigh = read_reg(MLDSA_DIAG);

    /* Read 7-word diagnostic output from modified verify build:
     * Word 0: tr_diag, Word 1: mu_diag, Word 2: dout_diag,
     * Word 3: c_diag, Word 4: fail, Word 5: rho_diag, Word 6: ctr0_diag */
    fail_step = 8;
    uint64_t words[7] = {0};
    for (int i = 0; i < 7; i++) {
        if (!read_word_tmo(&words[i], 10000000)) {
            verify_result = 0xBAD00010ull | i;
            diag = read_reg(MLDSA_STATUS);
            diag_final = read_reg(MLDSA_DIAG);
            phase = 0xE1;
            while (1) __asm__("nop");
        }
    }

    /* Store diagnostics in global vars for GDB readout */
    diag_after_start = words[0]; /* tr_diag */
    diag_after_sigc  = words[1]; /* mu_diag */
    diag_after_sigz  = words[2]; /* dout_diag (HW Keccak c~hat' word 0) */
    diag_after_t1    = words[3]; /* c_diag (sig_c word 0 = expected c~hat) */
    diag_after_msg   = words[5]; /* rho_diag */
    diag_after_sigh  = words[6]; /* ctr0_diag */

    /* CONVENTION-FREE HASH EQUALITY CHECK.
     * HW fail flag: 0 = all 6 words matched, 1 = at least one mismatch.
     * Standard ML-DSA API: 0 = invalid, 1 = valid. We invert HW fail to API.
     * hashes_match_step0 directly compares the captured first hash word,
     * bypassing any 0/1 convention. */
    uint64_t hw_fail            = words[4];
    uint64_t dout_word0         = words[2];
    uint64_t c_word0            = words[3];
    uint64_t hashes_match_step0 = (dout_word0 == c_word0) ? 1ULL : 0ULL;
    uint64_t real_pass          = (hw_fail == 0) ? 1ULL : 0ULL;
    uint64_t api_result         = real_pass;  /* API: 1=valid, 0=invalid */

    verify_result = api_result;     /* standard ML-DSA convention */
    fail_step     = hashes_match_step0;  /* overload: 1=word0 hashes match, 0=mismatch */

    /* phase=6 iff BOTH the API result matches KAT_EXPECTED AND the SW hash check agrees */
    phase = (api_result == KAT_EXPECTED && hashes_match_step0 == KAT_EXPECTED) ? 6 : 0xE3;
    while (1) __asm__("nop");
    return 0;
}
