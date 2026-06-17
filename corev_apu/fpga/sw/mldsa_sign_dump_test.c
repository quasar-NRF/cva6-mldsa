// ==================================================
// Giulio Golinelli - golinelli.giulio13@gmail.com
// TUMCREATE QUASAR RESEARCH ENGINEER
// Modified: 2026-06-17
// This file contains modifications vs. the upstream
// CVA6 / ML-DSA-OSH source fork.
// ==================================================

/*
 * Sign dump test: dump first 30 Z values to see the pattern.
 */

#include <stdint.h>
#include <stddef.h>

#define MLDSA_BASE    0x50000000ull
#define MLDSA_CTRL    0x00
#define MLDSA_DATA_IN 0x08
#define MLDSA_DATA_OUT 0x10
#define MLDSA_STATUS  0x18
#define MLDSA_DIAG    0x20

#define SEC_LVL   3

#define RHO_WORDS     4
#define TR_WORDS      8
#define S1_WORDS      80
#define S2_WORDS      96
#define T0_WORDS      312
#define K_WORDS       4
#define Z_WORDS       400

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

static volatile uint64_t result = 0xDEAD;
static volatile uint64_t z_arr[32];

int main(void) {
    uint64_t rho[4] = {0};
    uint64_t K[4] = {0};
    uint64_t s1[80] = {0};
    uint64_t s2[96] = {0};
    uint64_t t0[312] = {0};
    uint64_t tr[8] = {0};
    uint64_t rnd[4] = {0};
    uint64_t mlen_word = 5;
    uint64_t fmtd[1] = {0x0000000000000048ull};

    push_words(rho, RHO_WORDS);
    start_op(2);

    push_words(&mlen_word, 1);
    push_words(tr, TR_WORDS);
    push_words(fmtd, 1);
    push_words(K, K_WORDS);
    push_words(rnd, 4);
    push_words(s1, S1_WORDS);
    push_words(s2, S2_WORDS);
    push_words(t0, T0_WORDS);

    uint64_t sig_z[Z_WORDS];

    /* Read all Z values */
    for (size_t i = 0; i < Z_WORDS; i++) {
        size_t spins = 0;
        while (read_reg(MLDSA_STATUS) & (1ull << 2)) {
            spins++;
            if (spins > 5000000) {
                result = 0xBAD00000ull | i;
                while (1) __asm__("nop");
            }
        }
        sig_z[i] = read_reg(MLDSA_DATA_OUT);
    }

    /* Dump first 32 Z values to z_arr[] */
    for (int i = 0; i < 32; i++) {
        z_arr[i] = sig_z[i];
    }

    result = Z_WORDS;
    while (1) __asm__("nop");
    return 0;
}
