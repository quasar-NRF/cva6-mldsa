/*
 * ML-DSA-65 KeyGen diagnostic test with UART output.
 * Uses UART at 0x10000000 (16550-compatible) for real-time debug prints.
 * Also captures DIAG snapshots for detailed analysis.
 */

#include <stdint.h>
#include <stddef.h>

#define MLDSA_BASE    0x50000000ull
#define MLDSA_CTRL    0x00
#define MLDSA_DATA_IN 0x08
#define MLDSA_DATA_OUT 0x10
#define MLDSA_STATUS  0x18
#define MLDSA_DIAG    0x20

#define UART_BASE     0x10000000ull
#define UART_THR      0x00
#define UART_LSR      0x14
#define UART_LCR      0x0C
#define UART_FCR      0x08
#define UART_IER      0x04
#define UART_DLL      0x00
#define UART_DLM      0x04

#define SEC_LVL   3
#define KG_WORDS  744

#define BOUND_HASH  8
#define BOUND_S1    88
#define BOUND_S2    184
#define BOUND_T1    424
#define BOUND_T0    736
#define BOUND_TR    744

static inline void write_reg(uint64_t offset, uint64_t value) {
    *(volatile uint64_t *)(MLDSA_BASE + offset) = value;
}
static inline uint64_t read_reg(uint64_t offset) {
    return *(volatile uint64_t *)(MLDSA_BASE + offset);
}

/* UART functions */
static inline void uart_putc(char c) {
    /* Wait for THR empty (LSR bit 5) */
    volatile uint64_t *lsr = (volatile uint64_t *)(UART_BASE + UART_LSR);
    while (!(*lsr & (1 << 5)))
        __asm__("nop");
    *(volatile uint64_t *)(UART_BASE + UART_THR) = c;
}

static void uart_puts(const char *s) {
    while (*s) uart_putc(*s++);
}

static void uart_putHex(uint64_t x) {
    const char hex[] = "0123456789abcdef";
    char buf[17];
    for (int i = 15; i >= 0; i--) {
        buf[i] = hex[x & 0xf];
        x >>= 4;
    }
    buf[16] = 0;
    uart_puts("0x");
    uart_puts(buf);
}

static void uart_putDec(uint64_t x) {
    char buf[12];
    int i = 11;
    buf[i] = 0;
    if (x == 0) { uart_puts("0"); return; }
    while (x > 0 && i > 0) {
        buf[--i] = '0' + (x % 10);
        x /= 10;
    }
    uart_puts(&buf[i]);
}

/* DIAG field extraction */
static inline uint64_t diag_cstate0(uint64_t d)    { return d & 0x1F; }
static inline uint64_t diag_out_total(uint64_t d)   {
    return ((d >> 10) & 0x3F) << 5 | ((d >> 5) & 0x1F);
}
static inline uint64_t diag_ctr(uint64_t d)         { return (d >> 27) & 0x7FF; }
static inline uint64_t diag_valid_o(uint64_t d)     { return (d >> 54) & 1; }
static inline uint64_t diag_ready_enc(uint64_t d)   { return (d >> 57) & 1; }
static inline uint64_t diag_enc_phase(uint64_t d)   { return (d >> 61) & 1; }
static inline uint64_t diag_sticky_tr(uint64_t d)   { return (d >> 62) & 1; }

static void print_diag(const char *label, uint64_t d) {
    uart_puts(label);
    uart_puts(" raw=");
    uart_putHex(d);
    uart_puts(" cstate=");
    uart_putDec(diag_cstate0(d));
    uart_puts(" out_total=");
    uart_putDec(diag_out_total(d));
    uart_puts(" ctr=");
    uart_putDec(diag_ctr(d));
    uart_puts(" v=");
    uart_putDec(diag_valid_o(d));
    uart_puts(" re=");
    uart_putDec(diag_ready_enc(d));
    uart_puts(" ep=");
    uart_putDec(diag_enc_phase(d));
    uart_puts(" tr=");
    uart_putDec(diag_sticky_tr(d));
    uart_puts("\r\n");
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
}

int main(void) {
    const uint64_t seed[4] = {
        0x0123456789abcdefull,
        0xfedcba9876543210ull,
        0xdeadbeefcafebabeull,
        0x1122334455667788ull
    };

    uint64_t kg[KG_WORDS];

    uart_puts("\r\n=== ML-DSA KeyGen UART Diag ===\r\n");

    push_words(seed, 4);
    start_op(0);
    uart_puts("KeyGen started\r\n");

    /* Read all output words, capturing DIAG at each phase boundary */
    for (size_t i = 0; i < KG_WORDS; i++) {
        size_t spins = 0;
        while (read_reg(MLDSA_STATUS) & (1ull << 2)) {
            spins++;
            if (spins > 500000) {
                uint64_t diag = read_reg(MLDSA_DIAG);
                uint64_t status = read_reg(MLDSA_STATUS);
                uart_puts("STALL at word ");
                uart_putDec(i);
                uart_puts("\r\n");
                print_diag("DIAG", diag);
                uart_puts("STATUS=");
                uart_putHex(status);
                uart_puts("\r\n");

                /* Read DIAG a few more times to see if it's changing */
                for (int j = 0; j < 5; j++) {
                    for (volatile int k = 0; k < 1000; k++);
                    print_diag("DIAG", read_reg(MLDSA_DIAG));
                }

                while (1) __asm__("nop");
            }
        }
        kg[i] = read_reg(MLDSA_DATA_OUT);

        /* Print progress at phase boundaries and every 32 words during T0+tr */
        if (i == BOUND_HASH - 1) {
            uart_puts("--- HASH phase done (");
            uart_putDec(i + 1);
            uart_puts(" words) ---\r\n");
            print_diag("DIAG", read_reg(MLDSA_DIAG));
        }
        if (i == BOUND_S1 - 1) {
            uart_puts("--- S1 phase done (");
            uart_putDec(i + 1);
            uart_puts(" words) ---\r\n");
            print_diag("DIAG", read_reg(MLDSA_DIAG));
        }
        if (i == BOUND_S2 - 1) {
            uart_puts("--- S2 phase done (");
            uart_putDec(i + 1);
            uart_puts(" words) ---\r\n");
            print_diag("DIAG", read_reg(MLDSA_DIAG));
        }
        if (i == BOUND_T1 - 1) {
            uart_puts("--- T1 phase done (");
            uart_putDec(i + 1);
            uart_puts(" words) ---\r\n");
            print_diag("DIAG", read_reg(MLDSA_DIAG));
        }

        /* During T0+tr: print every 32 words */
        if (i >= BOUND_T1 && ((i - BOUND_T1) % 32 == 0)) {
            uart_puts("T0+tr word ");
            uart_putDec(i);
            uart_puts("/");
            uart_putDec(KG_WORDS - 1);
            uart_puts("\r\n");
            print_diag("DIAG", read_reg(MLDSA_DIAG));
        }
    }

    /* Final DIAG read */
    uint64_t final_diag = read_reg(MLDSA_DIAG);
    uart_puts("=== KeyGen COMPLETE: ");
    uart_putDec(KG_WORDS);
    uart_puts(" words ===\r\n");
    print_diag("FINAL", final_diag);

    uart_puts("out_word_total=");
    uart_putDec(diag_out_total(final_diag));
    uart_puts(" sticky_tr=");
    uart_putDec(diag_sticky_tr(final_diag));
    uart_puts("\r\n");

    while (1) __asm__("nop");
    return 0;
}
