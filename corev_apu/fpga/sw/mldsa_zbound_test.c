// ==================================================
// Giulio Golinelli - golinelli.giulio13@gmail.com
// TUMCREATE QUASAR RESEARCH ENGINEER
// Modified: 2026-06-17
// This file contains modifications vs. the upstream
// CVA6 / ML-DSA-OSH source fork.
// ==================================================

/*
 * Z boundary dump: read Z at poly boundaries to detect uniform-per-poly pattern.
 * Each poly = 80 words (256 coeffs * 20 bits / 64 bits).
 * Dump word 0,1,2 (poly 0 start), 78,79,80,81,82 (poly 0 end / poly 1 start),
 * 158,159,160,161,162 (poly 1 end / poly 2 start).
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

static volatile uint64_t result = 0xDEAD;
static volatile uint64_t zb[16];

static uint64_t sign_out[SIG_Z_WORDS + 8];

int main(void) {
    /* Push rho */
    for (int i = 0; i < 4; i++)
        if (!push_word_tmo(kat_sk_rho[i], 500000)) { result = 0xBAD20001; while(1) __asm__("nop"); }

    start_op(2);

    /* Push MLEN */
    if (!push_word_tmo(KAT_MLEN_WORD, 500000)) { result = 0xBAD20002; while(1) __asm__("nop"); }
    /* Push tr */
    for (int i = 0; i < 8; i++)
        if (!push_word_tmo(kat_sk_tr[i], 500000)) { result = 0xBAD20003; while(1) __asm__("nop"); }
    /* Push fmtd */
    for (int i = 0; i < KAT_FMTD_WORDS; i++)
        if (!push_word_tmo(kat_fmtd_msg[i], 500000)) { result = 0xBAD20004; while(1) __asm__("nop"); }
    /* Push K */
    for (int i = 0; i < 4; i++)
        if (!push_word_tmo(kat_sk_k[i], 500000)) { result = 0xBAD20005; while(1) __asm__("nop"); }
    /* Push rnd */
    for (int i = 0; i < 4; i++)
        if (!push_word_tmo(0, 500000)) { result = 0xBAD20006; while(1) __asm__("nop"); }
    /* Push s1 */
    for (int i = 0; i < S1_WORDS; i++)
        if (!push_word_tmo(kat_sk_s1[i], 500000)) { result = 0xBAD20007; while(1) __asm__("nop"); }
    /* Push s2 */
    for (int i = 0; i < S2_WORDS; i++)
        if (!push_word_tmo(kat_sk_s2[i], 500000)) { result = 0xBAD20008; while(1) __asm__("nop"); }
    /* Push t0 */
    for (int i = 0; i < T0_WORDS; i++)
        if (!push_word_tmo(kat_sk_t0[i], 500000)) { result = 0xBAD20009; while(1) __asm__("nop"); }

    /* Read all Z values */
    for (int i = 0; i < SIG_Z_WORDS; i++) {
        if (!read_word_tmo(&sign_out[i], 5000000)) { result = 0xBAD20000ull | i; while(1) __asm__("nop"); }
    }

    /* Sample at boundaries */
    zb[0]  = sign_out[0];     /* poly 0 word 0 */
    zb[1]  = sign_out[1];     /* poly 0 word 1 */
    zb[2]  = sign_out[2];     /* poly 0 word 2 */
    zb[3]  = sign_out[78];    /* poly 0 word 78 (last cycle of poly 0) */
    zb[4]  = sign_out[79];    /* poly 0 word 79 (last word of poly 0) */
    zb[5]  = sign_out[80];    /* poly 1 word 0 (first word of poly 1) */
    zb[6]  = sign_out[81];    /* poly 1 word 1 */
    zb[7]  = sign_out[82];    /* poly 1 word 2 */
    zb[8]  = sign_out[158];   /* poly 1 word 78 */
    zb[9]  = sign_out[159];   /* poly 1 word 79 */
    zb[10] = sign_out[160];   /* poly 2 word 0 */
    zb[11] = sign_out[161];   /* poly 2 word 1 */
    zb[12] = sign_out[162];   /* poly 2 word 2 */
    zb[13] = sign_out[319];   /* poly 3 last word */
    zb[14] = sign_out[320];   /* poly 4 first word */
    zb[15] = sign_out[321];   /* poly 4 word 1 */

    result = SIG_Z_WORDS;
    while (1) __asm__("nop");
    return 0;
}
