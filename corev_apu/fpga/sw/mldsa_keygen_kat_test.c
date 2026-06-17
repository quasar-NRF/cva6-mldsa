/*
 * ML-DSA-65 KeyGen KAT test.
 * Uses NIST KAT seed and verifies rho matches expected pk.
 * If kg_out[0..3] matches expected_rho, KeyGen works correctly.
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
#define KG_WORDS  744

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

/* NIST KAT seed for ML-DSA-65, first test vector.
 * HW expects MSB-word first: seed[255:192], seed[191:128], seed[127:64], seed[63:0]
 * (matches tb_keygen_top.v S_INIT + S_SEND_SEED ordering) */
static const uint64_t kat_seed[4] = {
    0x8AB6448BF58F897Dull,
    0x528A8DE9F8E59329ull,
    0xAC929A9CDE7EDF3Eull,
    0x27E01BC9EF128A67ull
};

/* Expected pk_rho[0..3] from NIST KAT (first 32 bytes of pk_65.txt line 1).
 * pk_65.txt line 1 starts: 49DE190622B06817 61A9DB044015BF81 2760429001FDFF5F C897166546277E84...
 * Each word is bytes packed little-endian (HW outputs byte 0 in LSB position of word 0).
 *   word 0 = bytes 0-7:   49 DE 19 06 22 B0 68 17 -> 0x1768B0220619DE49
 *   word 1 = bytes 8-15:  61 A9 DB 04 40 15 BF 81 -> 0x81BF154004DBA961
 *   word 2 = bytes 16-23: 27 60 42 90 01 FD FF 5F -> 0x5FFFDF0190426027
 *   word 3 = bytes 24-31: C8 97 16 65 46 27 7E 84 -> 0x847E2746651697C8
 */
static const uint64_t expected_rho[4] = {
    0x1768B0220619DE49ull,
    0x81BF154004DBA961ull,
    0x5FFFDF0190426027ull,
    0x847E2746651697C8ull
};

static volatile uint64_t phase         = 0;
static volatile uint64_t kg_result     = 0xDEAD;
static volatile uint64_t rho0          = 0;
static volatile uint64_t rho1          = 0;
static volatile uint64_t rho2          = 0;
static volatile uint64_t rho3          = 0;
static volatile uint64_t rho_match     = 0xDEAD;
static volatile uint64_t kg_tr0        = 0;  /* First TR word from KeyGen */
static volatile uint64_t kg_k0         = 0;  /* First K word from KeyGen */
static volatile uint64_t kg_t1_0       = 0;  /* First T1 word from KeyGen */

int main(void) {
    phase = 1;

    for (int i = 0; i < 4; i++)
        if (!push_word_tmo(kat_seed[i], 100000)) { kg_result = 0xBAD00001; phase = 0xE1; while(1) __asm__("nop"); }

    start_op(0);

    uint64_t kg_out[KG_WORDS];
    for (int i = 0; i < KG_WORDS; i++) {
        if (!read_word_tmo(&kg_out[i], 500000)) {
            kg_result = 0xBAD00000ull | i;
            phase = 0xE1;
            while (1) __asm__("nop");
        }
    }
    kg_result = KG_WORDS;

    /* Expose rho[0..3] */
    rho0 = kg_out[0];
    rho1 = kg_out[1];
    rho2 = kg_out[2];
    rho3 = kg_out[3];

    /* Check if rho matches expected */
    rho_match = (rho0 == expected_rho[0] &&
                 rho1 == expected_rho[1] &&
                 rho2 == expected_rho[2] &&
                 rho3 == expected_rho[3]) ? 1ULL : 0ULL;

    /* Also expose K[0], T1[0], TR[0] for additional diagnostics */
    kg_k0   = kg_out[4];
    kg_t1_0 = kg_out[184];
    kg_tr0  = kg_out[736];

    phase = 6;
    while (1) __asm__("nop");
    return 0;
}
