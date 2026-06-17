// ==================================================
// Giulio Golinelli - golinelli.giulio13@gmail.com
// TUMCREATE QUASAR RESEARCH ENGINEER
// Modified: 2026-06-17
// This file contains modifications vs. the upstream
// CVA6 / ML-DSA-OSH source fork.
// ==================================================

// =============================================================================
// End-to-End STANDALONE testbench for ML-DSA-65 (sec_lvl=3).
// =============================================================================
// Chains all three accelerator phases — KeyGen → Sign → Verify — on a single
// combined_top instance, driving the streaming interface directly (no AXI
// bridge). Phase N's output is routed into Phase N+1's input:
//
//   Phase 1 KeyGen : seed (from KAT)            → pk_out + sk_out
//   Phase 2 Sign   : sk_out + message (KAT)     → sig_out
//   Phase 3 Verify : pk_out + sig_out + message → 1 result word (fail bit)
//
// PASS if the Verify result word has bit 0 == 0 (signature accepted).
//
// -----------------------------------------------------------------------------
// WHY THIS STRUCTURE
// -----------------------------------------------------------------------------
// Each phase's FSM mirrors the corresponding upstream KAT testbench
// (ref_combined/src_tb/tb_{keygen,sign,verify}_top.v) exactly:
//
//   - One clocked always block with default assignments at the top:
//       rst <= 0; valid_i <= 0; start <= 0; ready_o <= 0;
//     Then case(state) overrides these for the current state.
//
//   - The accelerator does NOT produce output while inputs are being
//     streamed (ready_o=0 during all SEND states). Output is only consumed
//     after all inputs have been handed off (ready_o=1 in RECV states).
//     Matching this pattern is critical — driving ready_o high during SEND
//     (as an earlier queue-based version of this TB did) causes the FSM
//     inside the accelerator to deadlock at the Sign phase.
//
//   - Inter-phase reset is a single cycle of rst=1 (same as upstream uses
//     between testvectors). Long resets are unnecessary and can leave BRAM
//     init paths in an unexpected state.
//
//   - CRITICAL VERILOG GOTCHA: seed_3 MUST be declared `reg [SEED_WIDTH-1:0]`
//     (descending) — same as upstream tb_keygen_top.v — NOT `reg [0:255]`
//     (ascending). Both regs hold the same numeric value after $readmemh,
//     but the bit-index interpretation differs: with the descending form,
//     `[SEED_WIDTH-1 -: 64]` extracts the MSB 64 bits first (which is what
//     the accelerator expects); with the ascending form, the same index
//     expression reads LSB-first and silently sends the seed in reverse
//     byte order. This bug caused 5950/5984 byte mismatches in KeyGen
//     output before being caught. pk_out/sk_out/sig_out stay ascending
//     because they're filled with `[k*64 +: 64]` index expressions.
//
// The upstream KAT testbenches verify output against precomputed vectors.
// This e2e TB instead chains real outputs to real inputs, so the final
// Verify result proves the FULL pipeline is functionally coherent.
//
// Reference: see e2e/bridge/tb_e2e_bridge.sv for the same logical flow driven
// through the AXI bridge (the path the CVA6 CPU uses at runtime).
// =============================================================================

`include "mldsa_params.v"

`timescale 1ns / 1ps
`define P 10   // clock period in ns (matches upstream TBs)

module tb_e2e_standalone;

    // ----------------------------- Clock / Reset -----------------------------
    reg clk = 1;
    reg rst = 1;
    always #(`P/2) clk = ~clk;

    // ----------------------------- Accelerator DUT signals -------------------
    reg         start;
    reg  [1:0]  mode;
    reg  [2:0]  sec_lvl;
    reg         valid_i;
    wire        ready_i;
    reg  [63:0] data_i;
    wire        valid_o;
    reg         ready_o;
    wire [63:0] data_o;

    // ----------------------------- Accelerator DUT ---------------------------
    combined_top DUT (
        .clk     (clk),
        .rst     (rst),
        .start   (start),
        .mode    (mode),
        .sec_lvl (sec_lvl),
        .valid_i (valid_i),
        .ready_i (ready_i),
        .data_i  (data_i),
        .valid_o (valid_o),
        .ready_o (ready_o),
        .data_o  (data_o)
    );

    // ----------------------------- KAT inputs (sec_lvl=3 only) --------------
    localparam NUM_TV = 1;
    localparam MAX_MLEN_3 = 8192*8;

    // BUG FIX (2026-06-17): seed_3 MUST be declared DESCENDING [SEED_WIDTH-1:0]
    // (matching upstream tb_keygen_top.v) so that `[SEED_WIDTH-1 -: 64]` extracts
    // the MSB word first. With ascending [0:N-1] the same index expression reads
    // the LSB first, which sends the seed in REVERSE byte order and breaks
    // KeyGen (5950/5984 byte mismatches vs KAT). The bridge e2e TB avoids this
    // because the CPU writes bytes via AXI byte-by-byte.
    reg [`SEED_WIDTH - 1 : 0]   seed_3    [NUM_TV - 1 : 0];
    reg [0 : MAX_MLEN_3 - 1]    message_3 [NUM_TV - 1 : 0];
    reg [31:0]                  mlen_3    [NUM_TV - 1 : 0];
    reg [0 : `CTX_WIDTH - 1]    context_3 [NUM_TV - 1 : 0];
    reg [31:0]                  ctxlen_3  [NUM_TV - 1 : 0];

    // Formatted message M' = [0] || ctxlen || ctx || msg (shared by Sign+Verify)
    reg [0 : MAX_MLEN_3 + 2*8 + `CTX_WIDTH - 1] message_fmtd_3 [NUM_TV - 1 : 0];
    integer fmt_word_len, fmt_byte_len;

    // ----------------------------- Phase outputs (chained) ------------------
    reg [0 : `PK_WIDTH_3  - 1]  pk_out;
    reg [0 : `SK_WIDTH_3  - 1]  sk_out;
    reg [0 : `SIG_WIDTH_3 - 1]  sig_out;

    // ----------------------------- KAT reference (for debug comparison) -----
    // Declared as single-element arrays so $readmemh can load them.
    reg [0 : `PK_WIDTH_3 - 1]   pk_kat  [0:0];
    reg [0 : `SK_WIDTH_3 - 1]   sk_kat  [0:0];
    reg [0 : `SIG_WIDTH_3 - 1]  sig_kat [0:0];
    // SigGen KAT SK (separate key material from KeyGen KAT SK)
    reg [0 : `SK_WIDTH_3 - 1]   sg_sk_kat [0:0];
    integer kg_mismatches, sg_mismatches;
    integer sk_match_sg;

    // ----------------------------- Counters / control -----------------------
    integer c;          // testvector index (always 0 here)
    integer ctr;        // word counter within current state
    integer start_time; // cycle accounting
    integer kg_cycles, sg_cycles, vy_cycles;

    reg [63:0] mlen_ctxlen_word;
    reg [63:0] result_word;
    reg        result_fail;

    integer i, j;

    // ----------------------------- FSM state encoding -----------------------
    // 6-bit state space — plenty for all three phases.
    localparam
        // Phase 1: KeyGen (mode=0)
        S_KG_INIT      = 6'd0,
        S_KG_START     = 6'd1,
        S_KG_SEND      = 6'd2,   // send 4 seed words
        S_KG_RECV      = 6'd3,   // recv 744 words (pk+sk interleaved)
        S_KG_END       = 6'd4,

        // Phase 2: Sign (mode=2)
        S_SG_INIT      = 6'd10,
        S_SG_START     = 6'd11,
        S_SG_SEND_RHO  = 6'd12,  // sk rho (4)
        S_SG_SEND_MLEN = 6'd13,  // mlen+ctxlen (1)
        S_SG_SEND_TR   = 6'd14,  // sk tr (8)
        S_SG_SEND_MSG  = 6'd15,  // message_fmtd (fmt_word_len)
        S_SG_SEND_K    = 6'd16,  // sk K (4)
        S_SG_SEND_RND  = 6'd17,  // rnd zeros (4)
        S_SG_SEND_S1   = 6'd18,  // sk s1 (80)
        S_SG_SEND_S2   = 6'd19,  // sk s2 (96)
        S_SG_SEND_T0   = 6'd20,  // sk t0 (312)
        S_SG_RECV_Z    = 6'd21,  // z (400)
        S_SG_RECV_H    = 6'd22,  // h (8)
        S_SG_RECV_C    = 6'd23,  // ctilde (6)
        S_SG_END       = 6'd24,

        // Phase 3: Verify (mode=1)
        S_VY_INIT      = 6'd30,
        S_VY_START     = 6'd31,
        S_VY_SEND_RHO  = 6'd32,  // pk rho (4)
        S_VY_SEND_CT   = 6'd33,  // ctilde (6)
        S_VY_SEND_Z    = 6'd34,  // z (400)
        S_VY_SEND_T1   = 6'd35,  // pk t1 (240)
        S_VY_SEND_MLEN = 6'd36,  // mlen+ctxlen (1)
        S_VY_SEND_MSG  = 6'd37,  // message_fmtd
        S_VY_SEND_H    = 6'd38,  // h (8)
        S_VY_RECV      = 6'd39,  // 1 result word
        S_VY_END       = 6'd40,

        S_FINISH       = 6'd50;

    reg [5:0] state = S_KG_INIT;

    // ----------------------------- KAT load + message formatting ------------
    initial begin
        // Bounded $readmemh(addr 0..0) — documents that we only consume vector 0
        // from each 25-vector KAT file. (XSIM still emits a "Too many words"
        // warning; run.sh filters it from displayed output.)
        $readmemh("KeyGen_seed_65.txt",    seed_3, 0, 0);
        $readmemh("SigGen_message_65.txt", message_3, 0, 0);
        $readmemh("SigGen_mlen_65.txt",    mlen_3, 0, 0);
        $readmemh("SigGen_ctx_65.txt",     context_3, 0, 0);
        $readmemh("SigGen_ctxlen_65.txt",  ctxlen_3, 0, 0);

        // KAT references for debug comparison
        $readmemh("KeyGen_pk_65.txt",      pk_kat, 0, 0);
        $readmemh("KeyGen_sk_65.txt",      sk_kat, 0, 0);
        $readmemh("SigGen_signature_65.txt", sig_kat, 0, 0);
        $readmemh("SigGen_sk_65.txt",      sg_sk_kat, 0, 0);

        c = 0;
        pk_out = 0;
        sk_out = 0;
        sig_out = 0;
        ctr = 0;
        valid_i = 0;
        ready_o = 0;
        data_i  = 0;
        start   = 0;
        rst     = 1;
        sec_lvl = 3'd3;
        mode    = 2'd0;   // KeyGen first

        // Build M' = [0] || ctxlen || ctx || msg  (same layout as upstream TBs)
        message_fmtd_3[c] = 0;
        message_fmtd_3[c][0 +: 8] = 8'd0;
        message_fmtd_3[c][8 +: 8] = ctxlen_3[c][7:0];
        for (i = 0; i < ctxlen_3[c]; i = i + 1) begin
            message_fmtd_3[c][16 + i*8 +: 8] = context_3[c][(`CTX_BYTES - ctxlen_3[c])*8 + i*8 +: 8];
        end
        for (i = 0; i < mlen_3[c]; i = i + 1) begin
            message_fmtd_3[c][16 + ctxlen_3[c]*8 + i*8 +: 8] = message_3[c][(MAX_MLEN_3 - mlen_3[c]*8) + i*8 +: 8];
        end
        fmt_byte_len = 2 + ctxlen_3[c] + mlen_3[c];
        fmt_word_len = (fmt_byte_len + 7) / 8;
        mlen_ctxlen_word = {48'd0, mlen_3[c] + ctxlen_3[c]};

        $display("=== [e2e standalone] KAT #%0d: mlen=%0d ctxlen=%0d fmt_words=%0d ===",
                 c, mlen_3[c], ctxlen_3[c], fmt_word_len);
    end

    // ----------------------------- Main FSM ---------------------------------
    //
    // Default-then-override pattern (identical to upstream TBs): every cycle,
    // rst/valid_i/start/ready_o default to 0. The current state's case branch
    // overrides only what it needs. This keeps handshake signals clean during
    // state transitions.
    //
    always @(posedge clk) begin
        rst     <= 1'b0;
        valid_i <= 1'b0;
        start   <= 1'b0;
        ready_o <= 1'b0;
        // sec_lvl and mode are set explicitly per phase (not defaulted here)

        case (state)
        // =====================================================================
        // PHASE 1: KEYGEN (mode=0)
        // =====================================================================
        S_KG_INIT: begin
            // Replicate upstream tb_keygen_top.v S_INIT exactly:
            // rst=1 every cycle, pre-load seed word 0, exit with ctr=1.
            rst <= 1'b1;
            mode <= 2'd0;
            ctr <= ctr + 1;
            data_i <= seed_3[c][`SEED_WIDTH - 1 -: 64];
            if (ctr == 3) begin
                ctr <= 1;
                start_time = $time;
                state <= S_KG_START;
            end
        end
        S_KG_START: begin
            start <= 1'b1;
            state <= S_KG_SEND;
        end
        S_KG_SEND: begin
            // Replicate upstream S_SEND_SEED exactly.
            // ctr enters as 1 (from S_KG_INIT). data_i = seed word 0 (from S_KG_INIT).
            valid_i <= (!ready_i) ? 1 : 0;
            if (ready_i) begin
                ctr <= ctr + 1;
                valid_i <= 1'b1;
                data_i <= seed_3[c][`SEED_WIDTH - ctr*64 - 1 -: 64];
                if (ctr * 8 == `SEED_BYTES - 8) begin
                    ctr   <= 0;
                    state <= S_KG_RECV;
                end
            end
        end
        S_KG_RECV: begin
            // Receive 744 words. Routing matches upstream tb_keygen_top.v
            // (sec_lvl=3 path) and the bridge e2e TB:
            //   0..3   SKPK_rho → pk[0+]      and sk[0+]
            //   4..7   SK_K     → sk[SKPK_RHO+]
            //   8..87  SK_s1    → sk[SKPK_RHO+SK_K+SK_tr+]
            //  88..183 SK_s2    → sk[...+SK_s1+]
            // 184..423 PK_t1   → pk[SKPK_RHO+]
            // 424..735 SK_t0   → sk[...+SK_s2+]
            // 736..743 SK_tr   → sk[SKPK_RHO+SK_K+]
            ready_o <= 1'b1;
            if (valid_o) begin
                if (ctr < 4) begin
                    pk_out[ctr*64 +: 64] <= data_o;
                    sk_out[ctr*64 +: 64] <= data_o;
                end else if (ctr < 8) begin
                    sk_out[`SKPK_RHO_WIDTH + (ctr-4)*64 +: 64] <= data_o;
                end else if (ctr < 88) begin
                    sk_out[`SKPK_RHO_WIDTH + `SK_K_WIDTH + `SK_tr_WIDTH + (ctr-8)*64 +: 64] <= data_o;
                end else if (ctr < 184) begin
                    sk_out[`SKPK_RHO_WIDTH + `SK_K_WIDTH + `SK_tr_WIDTH + `SK_s1_WIDTH_3 + (ctr-88)*64 +: 64] <= data_o;
                end else if (ctr < 424) begin
                    pk_out[`SKPK_RHO_WIDTH + (ctr-184)*64 +: 64] <= data_o;
                end else if (ctr < 736) begin
                    sk_out[`SKPK_RHO_WIDTH + `SK_K_WIDTH + `SK_tr_WIDTH + `SK_s1_WIDTH_3 + `SK_s2_WIDTH_3 + (ctr-424)*64 +: 64] <= data_o;
                end else begin
                    sk_out[`SKPK_RHO_WIDTH + `SK_K_WIDTH + (ctr-736)*64 +: 64] <= data_o;
                end

                ctr <= ctr + 1;
                if (ctr == 743) begin
                    ctr <= 0;
                    kg_cycles = ($time - start_time) / `P;
                    $display("");
                    $display("=== Phase 1: KeyGen complete: 744 words, cycles=%0d ===", kg_cycles);
                    state <= S_KG_END;
                end
            end
        end
        S_KG_END: begin
            // KAT comparison: pk_out vs pk_kat, sk_out vs sk_kat
            kg_mismatches = 0;
            for (i = 0; i < `PK_BYTES_3; i = i + 1) begin
                if (pk_out[i*8 +: 8] !== pk_kat[0][i*8 +: 8]) begin
                    if (kg_mismatches < 5)
                        $display("  [KG PK mismatch] byte %0d: got %h, KAT %h", i, pk_out[i*8 +: 8], pk_kat[0][i*8 +: 8]);
                    kg_mismatches = kg_mismatches + 1;
                end
            end
            for (i = 0; i < `SK_BYTES_3; i = i + 1) begin
                if (sk_out[i*8 +: 8] !== sk_kat[0][i*8 +: 8]) begin
                    if (kg_mismatches < 5)
                        $display("  [KG SK mismatch] byte %0d: got %h, KAT %h", i, sk_out[i*8 +: 8], sk_kat[0][i*8 +: 8]);
                    kg_mismatches = kg_mismatches + 1;
                end
            end
            if (kg_mismatches == 0)
                $display("  [KAT check] KeyGen: PK+SK match KAT reference");
            else
                $display("  [KAT check] KeyGen: %0d byte mismatches vs KAT", kg_mismatches);

            // Settle cycle, then start Sign
            mode  <= 2'd2;
            ctr   <= 0;
            state <= S_SG_INIT;
        end

        // =====================================================================
        // PHASE 2: SIGN (mode=2)
        // =====================================================================
        S_SG_INIT: begin
            rst <= 1'b1;
            mode <= 2'd2;
            ctr  <= ctr + 1;
            if (ctr >= 2) begin
                ctr   <= 0;
                start_time = $time;
                $display("");
                $display("=== Phase 2: Sign started (mode=2, sec_lvl=3) ===");
                state <= S_SG_START;
            end
        end
        S_SG_START: begin
            start  <= 1'b1;
            data_i <= sk_out[0 +: 64];  // first sk_rho word
            ctr    <= 0;
            state  <= S_SG_SEND_RHO;
        end
        S_SG_SEND_RHO: begin
            // SK rho: 4 words from sk_out[0+]
            valid_i <= 1'b1;
            if (ready_i) begin
                ctr <= ctr + 1;
                if (ctr * 8 == `SKPK_RHO_BYTES - 8) begin
                    ctr <= 0;
                    data_i <= mlen_ctxlen_word;
                    state  <= S_SG_SEND_MLEN;
                end else begin
                    data_i <= sk_out[(ctr+1)*64 +: 64];
                end
            end
        end
        S_SG_SEND_MLEN: begin
            // mlen+ctxlen: 1 word
            valid_i <= 1'b1;
            data_i  <= mlen_ctxlen_word;
            if (ready_i) begin
                ctr <= 0;
                data_i <= sk_out[`SKPK_RHO_WIDTH + `SK_K_WIDTH +: 64]; // first tr word
                state  <= S_SG_SEND_TR;
            end
        end
        S_SG_SEND_TR: begin
            // SK tr: 8 words from sk_out[SKPK_RHO+SK_K+]
            valid_i <= 1'b1;
            if (ready_i) begin
                ctr <= ctr + 1;
                if (ctr * 8 == `SK_tr_BYTES - 8) begin
                    ctr <= 0;
                    data_i <= message_fmtd_3[c][0 +: 64];
                    state  <= S_SG_SEND_MSG;
                end else begin
                    data_i <= sk_out[`SKPK_RHO_WIDTH + `SK_K_WIDTH + (ctr+1)*64 +: 64];
                end
            end
        end
        S_SG_SEND_MSG: begin
            // message_fmtd: fmt_word_len words
            valid_i <= 1'b1;
            if (ready_i) begin
                ctr <= ctr + 1;
                if (ctr * 8 >= fmt_byte_len - 8) begin
                    ctr <= 0;
                    data_i <= sk_out[`SKPK_RHO_WIDTH +: 64]; // first K word
                    state  <= S_SG_SEND_K;
                end else begin
                    data_i <= message_fmtd_3[c][(ctr+1)*64 +: 64];
                end
            end
        end
        S_SG_SEND_K: begin
            // SK K: 4 words from sk_out[SKPK_RHO+]
            valid_i <= 1'b1;
            if (ready_i) begin
                ctr <= ctr + 1;
                if (ctr * 8 == `SK_K_BYTES - 8) begin
                    ctr <= 0;
                    data_i <= 64'd0;
                    state  <= S_SG_SEND_RND;
                end else begin
                    data_i <= sk_out[`SKPK_RHO_WIDTH + (ctr+1)*64 +: 64];
                end
            end
        end
        S_SG_SEND_RND: begin
            // rnd: 4 zero words
            valid_i <= 1'b1;
            data_i  <= 64'd0;
            if (ready_i) begin
                ctr <= ctr + 1;
                if (ctr * 8 == `RND_BYTES - 8) begin
                    ctr <= 0;
                    data_i <= sk_out[`SKPK_RHO_WIDTH + `SK_K_WIDTH + `SK_tr_WIDTH +: 64]; // first s1
                    state  <= S_SG_SEND_S1;
                end
            end
        end
        S_SG_SEND_S1: begin
            // SK s1: 80 words
            valid_i <= 1'b1;
            if (ready_i) begin
                ctr <= ctr + 1;
                if (ctr * 8 == `SK_s1_BYTES_3 - 8) begin
                    ctr <= 0;
                    data_i <= sk_out[`SKPK_RHO_WIDTH + `SK_K_WIDTH + `SK_tr_WIDTH + `SK_s1_WIDTH_3 +: 64]; // first s2
                    state  <= S_SG_SEND_S2;
                end else begin
                    data_i <= sk_out[`SKPK_RHO_WIDTH + `SK_K_WIDTH + `SK_tr_WIDTH + (ctr+1)*64 +: 64];
                end
            end
        end
        S_SG_SEND_S2: begin
            // SK s2: 96 words
            valid_i <= 1'b1;
            if (ready_i) begin
                ctr <= ctr + 1;
                if (ctr * 8 == `SK_s2_BYTES_3 - 8) begin
                    ctr <= 0;
                    data_i <= sk_out[`SKPK_RHO_WIDTH + `SK_K_WIDTH + `SK_tr_WIDTH + `SK_s1_WIDTH_3 + `SK_s2_WIDTH_3 +: 64]; // first t0
                    state  <= S_SG_SEND_T0;
                end else begin
                    data_i <= sk_out[`SKPK_RHO_WIDTH + `SK_K_WIDTH + `SK_tr_WIDTH + `SK_s1_WIDTH_3 + (ctr+1)*64 +: 64];
                end
            end
        end
        S_SG_SEND_T0: begin
            // SK t0: 312 words — last input field. After this, switch to RECV.
            valid_i <= 1'b1;
            if (ready_i) begin
                ctr <= ctr + 1;
                if (ctr * 8 == `SK_t0_BYTES_3 - 8) begin
                    ctr <= 0;
                    state <= S_SG_RECV_Z;
                end else begin
                    data_i <= sk_out[`SKPK_RHO_WIDTH + `SK_K_WIDTH + `SK_tr_WIDTH + `SK_s1_WIDTH_3 + `SK_s2_WIDTH_3 + (ctr+1)*64 +: 64];
                end
            end
        end
        S_SG_RECV_Z: begin
            // z: 400 words → sig_out[CTILDE_WIDTH_3 +]
            ready_o <= 1'b1;
            if (valid_o) begin
                sig_out[`CTILDE_WIDTH_3 + ctr*64 +: 64] <= data_o;
                ctr <= ctr + 1;
                if (ctr * 8 == `z_BYTES_3 - 8) begin
                    ctr <= 0;
                    state <= S_SG_RECV_H;
                end
            end
        end
        S_SG_RECV_H: begin
            // h: ceil(61/8)=8 words → sig_out[CTILDE_WIDTH_3 + z_WIDTH_3 +]
            ready_o <= 1'b1;
            if (valid_o) begin
                sig_out[`CTILDE_WIDTH_3 + `z_WIDTH_3 + ctr*64 +: 64] <= data_o;
                ctr <= ctr + 1;
                if (ctr >= 7) begin   // 8 words (0..7)
                    ctr <= 0;
                    state <= S_SG_RECV_C;
                end
            end
        end
        S_SG_RECV_C: begin
            // ctilde: 6 words → sig_out[0+]
            ready_o <= 1'b1;
            if (valid_o) begin
                sig_out[ctr*64 +: 64] <= data_o;
                ctr <= ctr + 1;
                if (ctr * 8 == `CTILDE_BYTES_3 - 8) begin
                    ctr <= 0;
                    sg_cycles = ($time - start_time) / `P;
                    $display("");
                    $display("=== Phase 2: Sign complete: 414 words, cycles=%0d ===", sg_cycles);
                    state <= S_SG_END;
                end
            end
        end
        S_SG_END: begin
            // Sign KAT comparison is only meaningful if KeyGen SK matches SigGen KAT SK
            sk_match_sg = 1;
            for (i = 0; i < `SK_BYTES_3; i = i + 1) begin
                if (sk_out[i*8 +: 8] !== sg_sk_kat[0][i*8 +: 8]) begin
                    sk_match_sg = 0;
                    i = `SK_BYTES_3;
                end
            end

            if (sk_match_sg) begin
                sg_mismatches = 0;
                for (i = 0; i < `SIG_BYTES_3; i = i + 1) begin
                    if (sig_out[i*8 +: 8] !== sig_kat[0][i*8 +: 8]) begin
                        if (sg_mismatches < 5)
                            $display("  [SG mismatch] byte %0d: got %h, KAT %h", i, sig_out[i*8 +: 8], sig_kat[0][i*8 +: 8]);
                        sg_mismatches = sg_mismatches + 1;
                    end
                end
                if (sg_mismatches == 0)
                    $display("  [KAT check] Sign: signature matches KAT reference");
                else
                    $display("  [KAT check] Sign: %0d byte mismatches vs KAT", sg_mismatches);
            end else begin
                $display("  [KAT check] Sign: SKIPPED — e2e SK differs from SigGen KAT SK (expected)");
            end

            mode  <= 2'd1;  // Verify next
            ctr   <= 0;
            state <= S_VY_INIT;
        end

        // =====================================================================
        // PHASE 3: VERIFY (mode=1)
        // =====================================================================
        S_VY_INIT: begin
            rst <= 1'b1;
            mode <= 2'd1;
            ctr  <= ctr + 1;
            if (ctr >= 2) begin
                ctr   <= 0;
                start_time = $time;
                $display("");
                $display("=== Phase 3: Verify started (mode=1, sec_lvl=3) ===");
                state <= S_VY_START;
            end
        end
        S_VY_START: begin
            start  <= 1'b1;
            data_i <= pk_out[0 +: 64];  // first pk_rho word
            ctr    <= 0;
            state  <= S_VY_SEND_RHO;
        end
        S_VY_SEND_RHO: begin
            // PK rho: 4 words from pk_out[0+]
            valid_i <= 1'b1;
            if (ready_i) begin
                ctr <= ctr + 1;
                if (ctr * 8 == `SKPK_RHO_BYTES - 8) begin
                    ctr <= 0;
                    data_i <= sig_out[0 +: 64];  // first ctilde
                    state  <= S_VY_SEND_CT;
                end else begin
                    data_i <= pk_out[(ctr+1)*64 +: 64];
                end
            end
        end
        S_VY_SEND_CT: begin
            // ctilde: 6 words from sig_out[0+]
            valid_i <= 1'b1;
            if (ready_i) begin
                ctr <= ctr + 1;
                if (ctr * 8 == `CTILDE_BYTES_3 - 8) begin
                    ctr <= 0;
                    data_i <= sig_out[`CTILDE_WIDTH_3 +: 64];  // first z
                    state  <= S_VY_SEND_Z;
                end else begin
                    data_i <= sig_out[(ctr+1)*64 +: 64];
                end
            end
        end
        S_VY_SEND_Z: begin
            // z: 400 words from sig_out[CTILDE_WIDTH_3 +]
            valid_i <= 1'b1;
            if (ready_i) begin
                ctr <= ctr + 1;
                if (ctr * 8 == `z_BYTES_3 - 8) begin
                    ctr <= 0;
                    data_i <= pk_out[`SKPK_RHO_WIDTH +: 64];  // first t1
                    state  <= S_VY_SEND_T1;
                end else begin
                    data_i <= sig_out[`CTILDE_WIDTH_3 + (ctr+1)*64 +: 64];
                end
            end
        end
        S_VY_SEND_T1: begin
            // PK t1: 240 words from pk_out[SKPK_RHO_WIDTH +]
            valid_i <= 1'b1;
            if (ready_i) begin
                ctr <= ctr + 1;
                if (ctr * 8 == `PK_t1_BYTES_3 - 8) begin
                    ctr <= 0;
                    data_i <= mlen_ctxlen_word;
                    state  <= S_VY_SEND_MLEN;
                end else begin
                    data_i <= pk_out[`SKPK_RHO_WIDTH + (ctr+1)*64 +: 64];
                end
            end
        end
        S_VY_SEND_MLEN: begin
            // mlen+ctxlen: 1 word
            valid_i <= 1'b1;
            data_i  <= mlen_ctxlen_word;
            if (ready_i) begin
                ctr <= 0;
                data_i <= message_fmtd_3[c][0 +: 64];
                state  <= S_VY_SEND_MSG;
            end
        end
        S_VY_SEND_MSG: begin
            // message_fmtd: fmt_word_len words
            valid_i <= 1'b1;
            if (ready_i) begin
                ctr <= ctr + 1;
                if (ctr * 8 >= fmt_byte_len - 8) begin
                    ctr <= 0;
                    data_i <= sig_out[`CTILDE_WIDTH_3 + `z_WIDTH_3 +: 64];  // first h
                    state  <= S_VY_SEND_H;
                end else begin
                    data_i <= message_fmtd_3[c][(ctr+1)*64 +: 64];
                end
            end
        end
        S_VY_SEND_H: begin
            // h: 8 words from sig_out[CTILDE_WIDTH_3 + z_WIDTH_3 +]
            valid_i <= 1'b1;
            if (ready_i) begin
                ctr <= ctr + 1;
                if (ctr >= 7) begin   // 8 words (0..7)
                    ctr <= 0;
                    state <= S_VY_RECV;
                end else begin
                    data_i <= sig_out[`CTILDE_WIDTH_3 + `z_WIDTH_3 + (ctr+1)*64 +: 64];
                end
            end
        end
        S_VY_RECV: begin
            // Drain 1 result word. Bit 0 = fail (0=valid, 1=invalid).
            ready_o <= 1'b1;
            if (valid_o) begin
                result_word <= data_o;
                result_fail <= data_o[0];
                vy_cycles = ($time - start_time) / `P;
                $display("");
                $display("=== Phase 3: Verify complete: result=0x%h (fail=%0d), cycles=%0d ===",
                         data_o, data_o[0], vy_cycles);
                state <= S_FINISH;
            end
        end

        // =====================================================================
        // DONE
        // =====================================================================
        S_FINISH: begin
            $display("");
            $display("============================================================");
            $display("=== [e2e standalone] Phase cycles: KG=%0d  Sign=%0d  Verify=%0d",
                     kg_cycles, sg_cycles, vy_cycles);
            if (result_fail === 1'b0) begin
                $display("=== [e2e standalone] RESULT: PASS — Verify accepted sig from chained KeyGen+Sign ===");
                $display("testbench done - PASS");
            end else begin
                $display("=== [e2e standalone] RESULT: FAIL — Verify rejected sig (fail=%0d, expected 0=valid) ===",
                         result_fail);
                $display("testbench done - FAIL");
            end
            $display("============================================================");
            $finish;
        end

        endcase
    end

    // ----------------------------- Watchdog ---------------------------------
    initial begin
        #2_000_000_000; // 2s sim time — enough for all three phases
        $display("FAIL: watchdog timeout — e2e standalone sim hung");
        $display("testbench done - FAIL");
        $finish;
    end

endmodule
