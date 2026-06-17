// ==================================================
// Giulio Golinelli - golinelli.giulio13@gmail.com
// TUMCREATE QUASAR RESEARCH ENGINEER
// Modified: 2026-06-17
// This file contains modifications vs. the upstream
// CVA6 / ML-DSA-OSH source fork.
// ==================================================

/*
 * ML-DSA-65 KeyGen diagnostic test v3.
 * Per-phase output word counters in DIAG.
 * DIAG layout (from combined_top.v):
 *   [4:0]   cstate0      [9:5] out_word_total[4:0]  [14:10] out_word_total[9:5]
 *   [24:15] owt_t1[9:0]  [34:25] owt_t0[9:0]  [38:35] owt_tr[3:0]
 *   [49:39] ctr[10:0]    [50] enc_phase  [51] ready_i_enc
 *   [52] valid_o  [53] done_op[0]  [54] s2_prereq_done
 *   [55] sticky_entered_t0  [56] sticky_entered_tr
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

/* Expected phase boundaries (cumulative word counts) */
#define BOUND_HASH  8    /* rho(4) + K(4) */
#define BOUND_S1    88   /* + S1(80) */
#define BOUND_S2    184  /* + S2(96) */
#define BOUND_T1    424  /* + T1(240) */
#define BOUND_T0    736  /* + T0(312) */
#define BOUND_TR    744  /* + tr(8) */

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

/* Results - inspectable via GDB */
static volatile uint64_t kg_result = 0xDEAD;
static volatile uint64_t stall_idx = 0;
static volatile uint64_t stall_diag = 0;
static volatile uint64_t stall_status = 0;

/* Granular snapshots: captured every SNAP_INTERVAL words during T0+tr */
#define SNAP_INTERVAL 32
#define SNAP_COUNT    ((KG_WORDS - BOUND_T1 + SNAP_INTERVAL - 1) / SNAP_INTERVAL + 1)
static volatile uint64_t snap_diags[SNAP_COUNT];
static volatile uint64_t snap_idx = 0;  /* how many snapshots captured */
static volatile uint64_t snap_word[SNAP_COUNT]; /* word index of each snapshot */

/* Phase boundary snapshots */
static volatile uint64_t snap_hash_diag;
static volatile uint64_t snap_s1_diag;
static volatile uint64_t snap_s2_diag;
static volatile uint64_t snap_t1_diag;
static volatile uint64_t snap_t0_diag;

/* Helpers to extract fields from DIAG */
static inline uint64_t diag_cstate0(uint64_t d)    { return d & 0x1F; }
static inline uint64_t diag_out_total(uint64_t d)   {
    return ((d >> 10) & 0x1F) << 5 | ((d >> 5) & 0x1F);
}
static inline uint64_t diag_owt_t1(uint64_t d)      { return (d >> 15) & 0x3FF; }
static inline uint64_t diag_owt_t0(uint64_t d)      { return (d >> 25) & 0x3FF; }
static inline uint64_t diag_owt_tr(uint64_t d)      { return (d >> 35) & 0xF; }
static inline uint64_t diag_ctr(uint64_t d)         { return (d >> 39) & 0x7FF; }
static inline uint64_t diag_enc_phase(uint64_t d)   { return (d >> 50) & 1; }
static inline uint64_t diag_ready_enc(uint64_t d)   { return (d >> 51) & 1; }
static inline uint64_t diag_valid_o(uint64_t d)     { return (d >> 52) & 1; }
static inline uint64_t diag_done_op(uint64_t d)     { return (d >> 53) & 1; }
static inline uint64_t diag_s2_pre(uint64_t d)      { return (d >> 54) & 1; }
static inline uint64_t diag_sticky_t0(uint64_t d)   { return (d >> 55) & 1; }
static inline uint64_t diag_sticky_tr(uint64_t d)   { return (d >> 56) & 1; }

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

        /* Capture DIAG at phase boundaries */
        if (i == BOUND_HASH - 1) snap_hash_diag = read_reg(MLDSA_DIAG);
        if (i == BOUND_S1 - 1)   snap_s1_diag   = read_reg(MLDSA_DIAG);
        if (i == BOUND_S2 - 1)   snap_s2_diag   = read_reg(MLDSA_DIAG);
        if (i == BOUND_T1 - 1)   snap_t1_diag   = read_reg(MLDSA_DIAG);

        /* Capture DIAG every SNAP_INTERVAL words during T0+tr (from word 424 onward) */
        if (i >= BOUND_T1 && ((i - BOUND_T1) % SNAP_INTERVAL == 0) && snap_idx < SNAP_COUNT) {
            snap_diags[snap_idx] = read_reg(MLDSA_DIAG);
            snap_word[snap_idx] = i;
            snap_idx++;
        }
    }

    /* Capture final DIAG at completion */
    snap_t0_diag = read_reg(MLDSA_DIAG);

    kg_result = KG_WORDS;
    while (1) __asm__("nop");
    return 0;
}
