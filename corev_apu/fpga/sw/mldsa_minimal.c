// ==================================================
// Giulio Golinelli - golinelli.giulio13@gmail.com
// TUMCREATE QUASAR RESEARCH ENGINEER
// Modified: 2026-06-17
// This file contains modifications vs. the upstream
// CVA6 / ML-DSA-OSH source fork.
// ==================================================

#include <stdint.h>

#define MLDSA_BASE    0x50000000ull
#define MLDSA_CTRL    0x00
#define MLDSA_DATA_IN 0x08
#define MLDSA_DATA_OUT 0x10
#define MLDSA_STATUS  0x18
#define MLDSA_DIAG    0x20

static inline void write_reg(uint64_t offset, uint64_t value) {
    *(volatile uint64_t *)(MLDSA_BASE + offset) = value;
}
static inline uint64_t read_reg(uint64_t offset) {
    return *(volatile uint64_t *)(MLDSA_BASE + offset);
}

static volatile uint64_t result = 0xDEAD;
static volatile uint64_t status_at_10 = 0;
static volatile uint64_t diag_at_10 = 0;
static volatile uint64_t words_read = 0;
static volatile uint64_t first_word = 0;

int main(void) {
    const uint64_t seed[4] = {
        0x0123456789abcdefull,
        0xfedcba9876543210ull,
        0xdeadbeefcafebabeull,
        0x1122334455667788ull
    };

    // Push seed
    for (int i = 0; i < 4; i++) {
        while (read_reg(MLDSA_STATUS) & (1ull << 1))
            __asm__("nop");
        write_reg(MLDSA_DATA_IN, seed[i]);
    }

    // Start KeyGen: mode=0, sec_lvl=3
    write_reg(MLDSA_CTRL, (3ull << 3));
    (void)read_reg(MLDSA_STATUS);
    write_reg(MLDSA_CTRL, (3ull << 3) | 1);
    (void)read_reg(MLDSA_STATUS);

    // Wait 10ms worth of cycles (~500000 at 50MHz) then check status
    for (volatile int i = 0; i < 500000; i++)
        __asm__("nop");
    
    status_at_10 = read_reg(MLDSA_STATUS);
    diag_at_10 = read_reg(MLDSA_DIAG);
    
    // Try to read up to 20 words
    uint64_t buf[20];
    int count = 0;
    for (int i = 0; i < 20; i++) {
        uint64_t s = read_reg(MLDSA_STATUS);
        if (s & (1ull << 2)) break; // out_empty
        buf[i] = read_reg(MLDSA_DATA_OUT);
        count++;
    }
    words_read = count;
    if (count > 0) first_word = buf[0];
    
    result = 0x600D0000ull | count;
    while (1) __asm__("nop");
    return 0;
}
