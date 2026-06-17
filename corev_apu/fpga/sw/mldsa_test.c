/*
 * ML-DSA-65 (FIPS 204, sec_lvl=3) integration test.
 *
 * Runs a full KeyGen → Sign → Verify round-trip through the AXI bridge
 * and the CRYSTALS-Dilithium hardware accelerator.
 *
 * Register map (64-bit AXI, byte offsets):
 *   0x00  CTRL     [WO]  [0]=start  [2:1]=mode  [5:3]=sec_lvl
 *   0x08  DATA_IN  [WO]  push 64-bit word to accelerator input FIFO
 *   0x10  DATA_OUT [RO]  read 64-bit word from accelerator output FIFO
 *   0x18  STATUS   [RO]  [0]=in_empty [1]=in_full [2]=out_empty
 *                               [3]=out_full [4]=accel_ready [5]=accel_valid
 *                               [6]=busy
 *                       [8]=start_live [9]=sticky_ready_i
 *                            [10]=sticky_in_pop [11]=sticky_valid_o
 *   0x20  DIAG     [RO]  Accelerator internal state:
 *                       [4:0]=cstate0 [9:5]=cstate1 [14:10]=cstate2
 *                       [17:15]=sampler_state [22:18]=sample_state
 *                       [23]=done_latch [24]=gen_s_mode
 *                       [25]=done_s [26]=mux_ctrl_k
 *                       [37:27]=ctr [38]=src_ready [39]=src_read
 *                       [40]=dst_write [41]=dst_ready
 *                       [42]=valid_o_s [43]=ready_o_s
 *                       [51:44]=sample_ctr
 *                       [52]=s2_prereq_done [53]=done_a [54]=valid_o
 *                       [55]=done_op [56]=start_op [57]=ready_i_enc
 *                       [60:58]=addr1_sel_op [61]=enc_phase
 *
 * Mode encoding: 0 = KeyGen, 1 = Verify, 2 = Sign
 * Security level: 2 = ML-DSA-44, 3 = ML-DSA-65, 5 = ML-DSA-87
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

/* ---------- ML-DSA-65 constants (sec_lvl = 3) ---------- */
#define SEC_LVL   3

#define RHO_BYTES     32
#define K_BYTES       32
#define TR_BYTES      64
#define S1_BYTES      640   /* L * eta_packed = 5 * 128 */
#define S2_BYTES      768   /* K * eta_packed = 6 * 128 */
#define T1_BYTES      1920  /* K * t1_packed = 6 * 320  */
#define T0_BYTES      2496  /* K * t0_packed = 6 * 416  */

#define Z_BYTES       3200  /* L * z_packed   = 5 * 640  */
#define H_BYTES       61    /* K + omega      = 6 + 55   */
#define CTILDE_BYTES  48    /* lambda / 4     = 192 / 4  */

#define RHO_WORDS     (RHO_BYTES    / 8)  /*  4 */
#define K_WORDS       (K_BYTES      / 8)  /*  4 */
#define TR_WORDS      (TR_BYTES     / 8)  /*  8 */
#define S1_WORDS      (S1_BYTES     / 8)  /* 80 */
#define S2_WORDS      (S2_BYTES     / 8)  /* 96 */
#define T1_WORDS      (T1_BYTES     / 8)  /* 240 */
#define T0_WORDS      (T0_BYTES     / 8)  /* 312 */
#define Z_WORDS       (Z_BYTES      / 8)  /* 400 */
#define CTILDE_WORDS  (CTILDE_BYTES / 8)  /* 6  */
#define H_WORDS       ((H_BYTES + 7) / 8) /* 8  */

/* KeyGen output: rho || K || s1 || s2 || t1 || t0 || tr */
#define KG_WORDS (RHO_WORDS + K_WORDS + S1_WORDS + S2_WORDS + \
                  T1_WORDS + T0_WORDS + TR_WORDS)              /* 744 */

/* ---------- Test message ---------- */
static const uint8_t msg_bytes[] = { 'H', 'e', 'l', 'l', 'o' };
#define MSG_LEN  ((uint16_t)(sizeof(msg_bytes)))  /* 5 */
#define CTX_LEN  ((uint16_t)0)

/* Formatted message: 0x00 || ctxlen(=0) || message
 * Byte length = 2 + MSG_LEN = 7, padded to 1 x 64-bit word */
#define FMTD_WORDS  ((MSG_LEN + 2 + CTX_LEN + 7) / 8)  /* 1 */

/* ---------- Low-level register access ---------- */

static inline void write_reg(uint64_t offset, uint64_t value)
{
    *(volatile uint64_t *)(MLDSA_BASE + offset) = value;
}

static inline uint64_t read_reg(uint64_t offset)
{
    return *(volatile uint64_t *)(MLDSA_BASE + offset);
}

/* Push words to accelerator input FIFO; blocks when FIFO is full. */
static void push_words(const uint64_t *data, size_t count)
{
    for (size_t i = 0; i < count; i++) {
        while (read_reg(MLDSA_STATUS) & (1ull << 1))  /* in_full */
            __asm__("nop");
        write_reg(MLDSA_DATA_IN, data[i]);
    }
}

/* Read exactly `count` words from output FIFO; blocks until available. */
static void read_words(uint64_t *out, size_t count)
{
    for (size_t i = 0; i < count; i++) {
        while (read_reg(MLDSA_STATUS) & (1ull << 2))  /* out_empty */
            __asm__("nop");
        out[i] = read_reg(MLDSA_DATA_OUT);
    }
}

/* Write CTRL to start an operation (rising-edge start pulse).
 * The bridge detects a rising edge on ctrl_start to arm the accelerator.
 * We clear start, drain the store buffer with a STATUS read-back, then
 * set start — guaranteeing the bridge sees a clean 0→1 transition. */
static void start_op(uint32_t mode)
{
    uint64_t ctrl = ((uint64_t)mode << 1) | ((uint64_t)SEC_LVL << 3);
    write_reg(MLDSA_CTRL, ctrl);                 /* start = 0 */
    (void)read_reg(MLDSA_STATUS);                 /* barrier */
    write_reg(MLDSA_CTRL, ctrl | (1ull << 0));   /* start = 1 */
    (void)read_reg(MLDSA_STATUS);                 /* barrier */
}

/* ---------- Diagnostics ---------- */

/* Global diagnostic values — inspectable via GDB with 'x/8gx &diag' */
static volatile uint64_t diag_status_after_push;
static volatile uint64_t diag_status_after_start;
static volatile uint64_t diag_status_stuck;
static volatile uint64_t diag_status_read_idx;
static volatile uint64_t diag_sticky_after_start;
static volatile uint64_t diag_sticky_stuck;
static volatile uint64_t diag_accel_after_start;
static volatile uint64_t diag_accel_stuck;
static volatile uint64_t diag_accel_stuck2;

/* Decoded DIAG stuck values — for quick GDB inspection */
static volatile uint64_t diag_stuck_cstate0;
static volatile uint64_t diag_stuck_ctr;
static volatile uint64_t diag_stuck_s2_prereq;
static volatile uint64_t diag_stuck_done_a;
static volatile uint64_t diag_stuck_valid_o;
static volatile uint64_t diag_stuck_sample_state;
static volatile uint64_t diag_stuck_done_op;
static volatile uint64_t diag_stuck_start_op;
static volatile uint64_t diag_stuck_ready_i_enc;
static volatile uint64_t diag_stuck_addr1_sel_op;
static volatile uint64_t diag_stuck_enc_phase;

/* Bridge FIFO push/pop counters (from STATUS bits [31:16]) */
static volatile uint64_t diag_push_cnt_stuck;
static volatile uint64_t diag_push_cnt_after_start;

/* ---------- Main ---------- */

int main(void)
{
    /* ---- Seed for KeyGen (32 bytes = 4 words) ---- */
    const uint64_t seed[4] = {
        0x0123456789abcdefull,
        0xfedcba9876543210ull,
        0xdeadbeefcafebabeull,
        0x1122334455667788ull
    };

    /* ================================================================
     *  1. KEY GENERATION   (mode = 0)
     *  Input : seed (4 words)
     *  Output: rho(4) || K(4) || s1(80) || s2(96) || t1(240) ||
     *          t0(312) || tr(8)   = 744 words
     * ================================================================ */
    uint64_t kg[KG_WORDS];

    push_words(seed, 4);

    /* Diagnostics: snapshot STATUS after pushing seed */
    diag_status_after_push = read_reg(MLDSA_STATUS);

    start_op(0);

    /* Diagnostics: snapshot STATUS and DIAG after start pulse */
    diag_status_after_start = read_reg(MLDSA_STATUS);
    diag_sticky_after_start = read_reg(MLDSA_STATUS);
    diag_accel_after_start  = read_reg(MLDSA_DIAG);
    diag_push_cnt_after_start = (read_reg(MLDSA_STATUS) >> 16) & 0xFFFF;

    /* Modified read_words with per-word diagnostics */
    for (size_t i = 0; i < KG_WORDS; i++) {
        size_t spins = 0;
        while (read_reg(MLDSA_STATUS) & (1ull << 2)) { /* out_empty */
            spins++;
            if (spins > 100000) {
                uint64_t d;
                diag_status_stuck  = read_reg(MLDSA_STATUS);
                diag_sticky_stuck  = read_reg(MLDSA_STATUS);
                diag_accel_stuck   = read_reg(MLDSA_DIAG);
                diag_accel_stuck2  = read_reg(MLDSA_DIAG);
                diag_status_read_idx = i;
                /* Pre-decode key DIAG fields for quick GDB inspection */
                d = diag_accel_stuck;
                diag_stuck_cstate0     = d & 0x1F;
                diag_stuck_ctr         = (d >> 27) & 0x7FF;
                diag_stuck_s2_prereq   = (d >> 52) & 1;
                diag_stuck_done_a      = (d >> 53) & 1;
                diag_stuck_valid_o     = (d >> 54) & 1;
                diag_stuck_sample_state = (d >> 18) & 0x1F;
                diag_stuck_done_op     = (d >> 55) & 1;
                diag_stuck_start_op    = (d >> 56) & 1;
                diag_stuck_ready_i_enc = (d >> 57) & 1;
                diag_stuck_addr1_sel_op = (d >> 58) & 0x7;
                diag_stuck_enc_phase   = (d >> 61) & 1;
                diag_push_cnt_stuck    = (read_reg(MLDSA_STATUS) >> 16) & 0xFFFF;
                /* Hang here instead of returning, so main() doesn't loop */
                while (1) __asm__("nop");
                return (int)(i + 100); /* diagnostic exit code */
            }
        }
        kg[i] = read_reg(MLDSA_DATA_OUT);
    }

    /* Parse key material (all pointers into kg[]) */
    const uint64_t *rho = &kg[0];                           /* 4  */
    const uint64_t *K   = &kg[RHO_WORDS];                   /* 4  */
    const uint64_t *s1  = &kg[RHO_WORDS + K_WORDS];         /* 80 */
    const uint64_t *s2  = &kg[RHO_WORDS + K_WORDS + S1_WORDS];          /* 96 */
    const uint64_t *t1  = &kg[RHO_WORDS + K_WORDS + S1_WORDS + S2_WORDS];          /* 240 */
    const uint64_t *t0  = &kg[RHO_WORDS + K_WORDS + S1_WORDS + S2_WORDS + T1_WORDS]; /* 312 */
    const uint64_t *tr  = &kg[KG_WORDS - TR_WORDS];         /* 8  */

    /* ================================================================
     *  2. SIGNING   (mode = 2)
     *
     *  Input order (matches tb_sign_top.v):
     *    rho(4) | mlen_word(1) | tr(8) | fmtd_msg(1) | K(4) |
     *    rnd(4) | s1(80) | s2(96) | t0(312)   = 510 words
     *
     *  Output order:
     *    z(400) | h(8) | ctilde(6)   = 414 words
     * ================================================================ */

    /* mlen_word: lower 16 bits = message_length + context_length.
     * The accelerator adds +2 internally. */
    const uint64_t mlen_word = (uint64_t)(MSG_LEN + CTX_LEN);

    /* Formatted message word: byte0=0x00, byte1=ctxlen, then message.
     * 7 bytes fit in one 64-bit word. */
    uint64_t fmtd[FMTD_WORDS];
    {
        uint8_t buf[8] = {0};
        buf[0] = 0x00;                    /* separator */
        buf[1] = (uint8_t)CTX_LEN;        /* ctx length */
        memcpy(&buf[2], msg_bytes, MSG_LEN);
        memcpy(fmtd, buf, 8);
    }

    /* rnd = 32 bytes of zeros (deterministic signing) */
    const uint64_t rnd[4] = {0, 0, 0, 0};

    /* Push rho first, then start — the accelerator begins consuming
     * from the FIFO while we push the remaining data. */
    push_words(rho, RHO_WORDS);
    start_op(2);

    push_words(&mlen_word, 1);
    push_words(tr, TR_WORDS);
    push_words(fmtd, FMTD_WORDS);
    push_words(K, K_WORDS);
    push_words(rnd, 4);
    push_words(s1, S1_WORDS);
    push_words(s2, S2_WORDS);
    push_words(t0, T0_WORDS);

    /* Read signature: z || h || ctilde */
    uint64_t sig_z[Z_WORDS];
    uint64_t sig_h[H_WORDS];
    uint64_t sig_ctilde[CTILDE_WORDS];

    read_words(sig_z, Z_WORDS);
    read_words(sig_h, H_WORDS);
    read_words(sig_ctilde, CTILDE_WORDS);

    /* ================================================================
     *  3. VERIFICATION   (mode = 1)
     *
     *  Input order (matches tb_verify_top.v):
     *    rho(4) | ctilde(6) | z(400) | t1(240) |
     *    mlen_word(1) | fmtd_msg(1) | h(8)   = 660 words
     *
     *  Output (sec_lvl=3): 7 diagnostic words:
     *    [0] tr_diag  [1] mu_diag  [2] dout_diag  [3] c_diag
     *    [4] result (0=pass)  [5] rho_diag  [6] ctr0_diag
     * ================================================================ */
    push_words(rho, RHO_WORDS);
    start_op(1);

    push_words(sig_ctilde, CTILDE_WORDS);
    push_words(sig_z, Z_WORDS);
    push_words(t1, T1_WORDS);
    push_words(&mlen_word, 1);
    push_words(fmtd, FMTD_WORDS);
    push_words(sig_h, H_WORDS);

    /* Read 7 diagnostic words (result is word 4) */
    uint64_t ver_diag[7];
    read_words(ver_diag, 7);

    /* ver_diag[4] == 0  →  signature is valid */
    return (ver_diag[4] == 0) ? 0 : 1;
}
