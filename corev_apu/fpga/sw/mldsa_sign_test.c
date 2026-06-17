// ==================================================
// Giulio Golinelli - golinelli.giulio13@gmail.com
// TUMCREATE QUASAR RESEARCH ENGINEER
// Modified: 2026-06-17
// This file contains modifications vs. the upstream
// CVA6 / ML-DSA-OSH source fork.
// ==================================================

/*
 * ML-DSA-65 Sign-only test.
 * Uses a dummy key (all zeros) to test the signing phase.
 * Reads DIAG at various points to identify where the stall occurs.
 */

#include <stdint.h>
#include <stddef.h>
#include <string.h>

#define MLDSA_BASE    0x50000000ull
#define MLDSA_CTRL    0x00
#define MLDSA_DATA_IN 0x08
#define MLDSA_DATA_OUT 0x10
#define MLDSA_STATUS  0x18
#define MLDSA_DIAG    0x20

#define SEC_LVL   3

/* Signing input sizes */
#define RHO_WORDS     4
#define TR_WORDS      8
#define S1_WORDS      80
#define S2_WORDS      96
#define T0_WORDS      312
#define K_WORDS       4
#define Z_WORDS       400
#define H_WORDS       8
#define CTILDE_WORDS  6

static inline void write_reg(uint64_t offset, uint64_t value) {
    *(volatile uint64_t *)(MLDSA_BASE + offset) = value;
}
static inline uint64_t read_reg(uint64_t offset) {
    return *(volatile uint64_t *)(MLDSA_BASE + offset);
}

static void push_words(const uint64_t *data, size_t count) {
    for (size_t i = 0; i < count; i++) {
        while (read_reg(MLDSA_STATUS) & (1ull << 1))
            __asm__("nop");
        write_reg(MLDSA_DATA_IN, data[i]);
    }
}

static void start_op(uint32_t mode) {
    uint64_t ctrl = ((uint64_t)mode << 1) | ((uint64_t)SEC_LVL << 3);
    write_reg(MLDSA_CTRL, ctrl);
    (void)read_reg(MLDSA_STATUS);
    write_reg(MLDSA_CTRL, ctrl | 1);
    (void)read_reg(MLDSA_STATUS);
}

/* Diagnostics */
static volatile uint64_t diag_after_push[16];
static volatile uint64_t status_after_push[16];
static volatile uint64_t result = 0xDEAD;

int main(void) {
    /* Dummy key material (all zeros) */
    uint64_t rho[4] = {0};
    uint64_t K[4] = {0};
    uint64_t s1[80] = {0};
    uint64_t s2[96] = {0};
    uint64_t t0[312] = {0};
    uint64_t tr[8] = {0};
    uint64_t rnd[4] = {0};
    uint64_t mlen_word = 5;  /* message length */
    uint64_t fmtd[1] = {0x0000000000000048ull}; /* "H\0\0\0\0\0\0\0" */

    /* Push rho and start */
    push_words(rho, RHO_WORDS);
    start_op(2);

    /* Push remaining signing input, capturing diagnostics at each step */
    int di = 0;

    push_words(&mlen_word, 1);
    diag_after_push[di] = read_reg(MLDSA_DIAG);
    status_after_push[di] = read_reg(MLDSA_STATUS);
    di++;

    push_words(tr, TR_WORDS);
    diag_after_push[di] = read_reg(MLDSA_DIAG);
    status_after_push[di] = read_reg(MLDSA_STATUS);
    di++;

    push_words(fmtd, 1);
    diag_after_push[di] = read_reg(MLDSA_DIAG);
    status_after_push[di] = read_reg(MLDSA_STATUS);
    di++;

    push_words(K, K_WORDS);
    diag_after_push[di] = read_reg(MLDSA_DIAG);
    status_after_push[di] = read_reg(MLDSA_STATUS);
    di++;

    push_words(rnd, 4);
    diag_after_push[di] = read_reg(MLDSA_DIAG);
    status_after_push[di] = read_reg(MLDSA_STATUS);
    di++;

    push_words(s1, S1_WORDS);
    diag_after_push[di] = read_reg(MLDSA_DIAG);
    status_after_push[di] = read_reg(MLDSA_STATUS);
    di++;

    push_words(s2, S2_WORDS);
    diag_after_push[di] = read_reg(MLDSA_DIAG);
    status_after_push[di] = read_reg(MLDSA_STATUS);
    di++;

    push_words(t0, T0_WORDS);
    diag_after_push[di] = read_reg(MLDSA_DIAG);
    status_after_push[di] = read_reg(MLDSA_STATUS);
    di++;

    /* All input pushed. Now read signing output. */
    result = 0xA0000000ull | di;  /* marker: pushed all data */

    uint64_t sig_z[Z_WORDS];
    for (size_t i = 0; i < Z_WORDS; i++) {
        size_t spins = 0;
        while (read_reg(MLDSA_STATUS) & (1ull << 2)) {
            spins++;
            if (spins > 500000) {
                result = 0xBAD00000ull | i;
                diag_after_push[15] = read_reg(MLDSA_DIAG);
                status_after_push[15] = read_reg(MLDSA_STATUS);
                while (1) __asm__("nop");
            }
        }
        sig_z[i] = read_reg(MLDSA_DATA_OUT);
    }

    result = Z_WORDS;  /* Success - read all z words */
    while (1) __asm__("nop");
    return 0;
}
