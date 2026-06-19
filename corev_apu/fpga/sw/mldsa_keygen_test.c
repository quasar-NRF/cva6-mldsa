// ==================================================
// Giulio Golinelli - golinelli.giulio13@gmail.com
// TUMCREATE QUASAR RESEARCH ENGINEER
// Modified: 2026-06-17
// This file contains modifications vs. the upstream
// CVA6 / ML-DSA-OSH source fork.
// ==================================================

/*
 * ML-DSA-65 KeyGen-only test.
 * Verifies that KeyGen completes and reads all 744 output words.
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

// TUMCREATE (2026-06-18): allow compile-time override via -DSEC_LVL=X for multi-level testing
#ifndef SEC_LVL
#define SEC_LVL   3
#endif
// KG_WORDS = ceil(SK_BYTES/8) where SK_BYTES varies per level
#if   SEC_LVL == 2
#  define KG_WORDS  480
#elif SEC_LVL == 5
#  define KG_WORDS  932
#else
#  define KG_WORDS  744   // sec_lvl=3 default
#endif

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

/* Result word - inspectable via GDB */
static volatile uint64_t kg_result = 0xDEAD;

/* Diagnostic state at stall */
static volatile uint64_t stall_diag = 0;
static volatile uint64_t stall_status = 0;
static volatile uint64_t stall_idx = 0;

int main(void) {
    const uint64_t seed[4] = {
        0x0123456789abcdefull,
        0xfedcba9876543210ull,
        0xdeadbeefcafebabeull,
        0x1122334455667788ull
    };

    uint64_t kg[KG_WORDS];

    push_words(seed, 4);
    start_op(0);

    /* Read all 744 KeyGen output words */
    for (size_t i = 0; i < KG_WORDS; i++) {
        size_t spins = 0;
        while (read_reg(MLDSA_STATUS) & (1ull << 2)) {
            spins++;
            if (spins > 500000) {
                stall_diag = read_reg(MLDSA_DIAG);
                stall_status = read_reg(MLDSA_STATUS);
                stall_idx = i;
                kg_result = 0xBAD00000ull | (uint64_t)i;
                while (1) __asm__("nop");
            }
        }
        kg[i] = read_reg(MLDSA_DATA_OUT);
    }

    /* Success! Write the number of words read */
    kg_result = KG_WORDS;

    /* Hang here so GDB can read the result */
    while (1) __asm__("nop");

    return 0;
}
