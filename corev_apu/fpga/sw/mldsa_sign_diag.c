/*
 * ML-DSA-65 KeyGen -> Sign test v10.
 * Streams data normally but captures DIAG at every FSM0 state change.
 * Also captures DIAG every 1M push spins to track progress.
 */

#include <stdint.h>
#include <stddef.h>

#define MLDSA_BASE     0x50000000ull
#define MLDSA_CTRL     0x00
#define MLDSA_DATA_IN  0x08
#define MLDSA_DATA_OUT 0x10
#define MLDSA_STATUS   0x18
#define MLDSA_DIAG     0x20

#define SEC_LVL   3
#define KG_WORDS  744

#define OFF_RHO  0
#define OFF_K    4
#define OFF_S1   8
#define OFF_S2   88
#define OFF_T1   184
#define OFF_T0   424
#define OFF_TR   736

#define S1_WORDS  80
#define S2_WORDS  96
#define T0_WORDS  312
#define MSG_BYTES 32
#define SIGN_OUT_MAX  512
#define SIGN_IN_TOTAL 514

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

static void start_op(uint32_t mode) {
    uint64_t ctrl = ((uint64_t)mode << 1) | ((uint64_t)SEC_LVL << 3);
    write_reg(MLDSA_CTRL, ctrl);
    (void)read_reg(MLDSA_STATUS);
    write_reg(MLDSA_CTRL, ctrl | 1);
    (void)read_reg(MLDSA_STATUS);
}

static volatile uint64_t phase         = 0;
static volatile uint64_t kg_result     = 0xDEAD;
static volatile uint64_t sign_result   = 0xDEAD;

/* Compact snapshot storage: DIAG + push_idx pairs */
static volatile uint64_t snap[48];
static volatile uint64_t snap_at[48]; /* push_idx or iteration when captured */

static uint64_t kg_out[KG_WORDS];
static uint64_t sign_out[SIGN_OUT_MAX];

int main(void) {
    /* ======== KeyGen ======== */
    phase = 1;
    const uint64_t seed[4] = {
        0x0123456789abcdefull,
        0xfedcba9876543210ull,
        0xdeadbeefcafebabeull,
        0x1122334455667788ull
    };

    for (int i = 0; i < 4; i++) push_word_tmo(seed[i], 100000);
    start_op(0);

    for (int i = 0; i < KG_WORDS; i++) {
        uint32_t spins = 0;
        while (read_reg(MLDSA_STATUS) & 4) {
            if (++spins > 500000) {
                kg_result = 0xBAD00000ull | i;
                phase = 0xB1;
                while (1) __asm__("nop");
            }
        }
        kg_out[i] = read_reg(MLDSA_DATA_OUT);
    }
    kg_result = KG_WORDS;
    phase = 2;

    /* ======== Build Sign input ======== */
    static uint64_t sign_in[SIGN_IN_TOTAL];
    int idx = 0;

    for (int i = 0; i < 4; i++) sign_in[idx++] = kg_out[OFF_RHO + i];
    sign_in[idx++] = MSG_BYTES;
    for (int i = 0; i < 4; i++) sign_in[idx++] = 0x2020202020202020ull;
    for (int i = 0; i < 4; i++) sign_in[idx++] = 0;
    for (int i = 0; i < 4; i++) sign_in[idx++] = kg_out[OFF_K + i];
    for (int i = 0; i < 8; i++) sign_in[idx++] = kg_out[OFF_TR + i];
    sign_in[idx++] = 0; /* padding */
    for (int i = 0; i < S1_WORDS; i++) sign_in[idx++] = kg_out[OFF_S1 + i];
    for (int i = 0; i < S2_WORDS; i++) sign_in[idx++] = kg_out[OFF_S2 + i];
    for (int i = 0; i < T0_WORDS; i++) sign_in[idx++] = kg_out[OFF_T0 + i];

    /* ======== Sign ======== */
    phase = 3;

    /* Push 26 header words */
    int push_idx = 0;
    for (int i = 0; i < 26; i++) push_word_tmo(sign_in[push_idx++], 100000);

    /* Start Sign */
    start_op(2);

    int si = 0;
    uint64_t prev_cstate0 = 0xFF;

    snap[si] = read_reg(MLDSA_DIAG);
    snap_at[si] = push_idx;
    si++;

    phase = 4;

    /* Stream remaining words with FSM tracking */
    while (push_idx < idx) {
        /* Try to push one word with long timeout */
        uint32_t spins = 0;
        while (read_reg(MLDSA_STATUS) & 2) {
            if (++spins > 500000000) {
                /* 20 second timeout — capture final state */
                if (si < 46) {
                    snap[si] = read_reg(MLDSA_DIAG);
                    snap_at[si] = push_idx | 0x10000;
                    si++;
                }
                sign_result = 0xBAD20000ull | push_idx;
                phase = 0xB4;
                while (1) __asm__("nop");
            }
            /* Check FSM state every 100K spins */
            if ((spins & 0xFFFF) == 0) {
                uint64_t d = read_reg(MLDSA_DIAG);
                uint64_t c0 = d & 0x1F;
                /* Capture on state change or every 10M spins */
                if ((c0 != prev_cstate0 || (spins & 0xFFFFFF) == 0) && si < 46) {
                    snap[si] = d;
                    snap_at[si] = push_idx | ((uint64_t)spins << 16);
                    si++;
                    prev_cstate0 = c0;
                }
            }
        }
        write_reg(MLDSA_DATA_IN, sign_in[push_idx]);
        push_idx++;

        /* Also capture on push boundary at certain words */
        if ((push_idx == 106 || push_idx == 202 || push_idx == 330) && si < 46) {
            snap[si] = read_reg(MLDSA_DIAG);
            snap_at[si] = push_idx;
            si++;
        }
    }

    phase = 5;
    sign_result = si;  /* number of snapshots */

    /* Capture post-push DIAG */
    if (si < 46) {
        snap[si] = read_reg(MLDSA_DIAG);
        snap_at[si] = push_idx;
        si++;
    }

    /* Read all output words — spin on out_empty with timeout */
    int out_cnt = 0;
    for (int i = 0; i < SIGN_OUT_MAX; i++) {
        uint32_t spins = 0;
        while (read_reg(MLDSA_STATUS) & 4) {
            if (++spins > 500000000) {
                sign_result = 0xBAD10000ull | i;
                phase = 0xB5;
                while (1) __asm__("nop");
            }
        }
        sign_out[i] = read_reg(MLDSA_DATA_OUT);
        out_cnt = i + 1;
    }

    sign_result = out_cnt;
    phase = 6;
    while (1) __asm__("nop");
    return 0;
}
