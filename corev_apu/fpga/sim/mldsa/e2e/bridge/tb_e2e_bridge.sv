// ==================================================
// Giulio Golinelli - golinelli.giulio13@gmail.com
// TUMCREATE QUASAR RESEARCH ENGINEER
// Modified: 2026-06-18
// This file contains modifications vs. the upstream
// CVA6 / ML-DSA-OSH source fork.
// ==================================================

// Bridge testbench for ML-DSA end-to-end (KeyGen → Sign → Verify).
// Runs all three phases through axi_mldsa_bridge in sequence using the SAME
// accelerator + bridge instance. Uses KAT seed for KeyGen, then routes the
// accelerator's actual KeyGen output (PK + SK) into Sign, and routes Sign's
// actual signature output into Verify. Final fail bit must be 0 (valid).
//
// TUMCREATE (M-A5, 2026-06-18): TB now level-aware. KAT arrays sized for the
// active level only (XSIM $readmemh mis-aligns when container is wider than
// KAT line); word counts via localparams selected by `SEC_LVL; KAT filenames
// branched on `SEC_LVL.

`include "mldsa_params.v"
`include "axi/typedef.svh"
`include "axi/assign.svh"

`timescale 1ns / 1ps

// TUMCREATE: Compile-time security level. Forwarded via xvlog/xelab -d SEC_LVL=X.
// Default 3 (ML-DSA-65) for backward compatibility.
`ifndef SEC_LVL
  `define SEC_LVL 3
`endif

module tb_e2e_bridge;

  // ----------------------------- Clock / Reset -----------------------------
  reg clk = 0;
  reg rst_n = 0;
  always #5 clk = ~clk;

  // ----------------------------- AXI BUS interface -----------------------------
  AXI_BUS #(
    .AXI_ADDR_WIDTH (64),
    .AXI_DATA_WIDTH (64),
    .AXI_ID_WIDTH   (5),
    .AXI_USER_WIDTH (1)
  ) axi ();

  // ----------------------------- DUT signals -----------------------------
  wire        rst_o_w, start_o_w, valid_i_o_w, ready_i_i_w, valid_o_i_w, ready_o_o_w;
  wire [1:0]  mode_o_w;
  wire [2:0]  sec_lvl_o_w;
  wire [63:0] data_i_o_w, data_o_i_w;

  // ----------------------------- Bridge DUT -----------------------------
  axi_mldsa_bridge #(
    .AxiAddrWidth (64),
    .AxiDataWidth (64),
    .AxiIdWidth   (5),
    .AxiUserWidth (1)
  ) i_bridge (
    .clk_i     (clk),
    .rst_ni    (rst_n),
    .axi       (axi),
    .rst_o     (rst_o_w),
    .start_o   (start_o_w),
    .mode_o    (mode_o_w),
    .sec_lvl_o (sec_lvl_o_w),
    .valid_i_o (valid_i_o_w),
    .data_i_o  (data_i_o_w),
    .ready_i_i (ready_i_i_w),
    .valid_o_i (valid_o_i_w),
    .ready_o_o (ready_o_o_w),
    .data_o_i  (data_o_i_w),
    .diag_i    (63'b0)
  );

  // ----------------------------- Accelerator DUT -----------------------------
  combined_top DUT (
    .clk     (clk),
    .rst     (rst_o_w),
    .start   (start_o_w),
    .mode    (mode_o_w),
    .sec_lvl (sec_lvl_o_w),
    .valid_i (valid_i_o_w),
    .ready_i (ready_i_i_w),
    .data_i  (data_i_o_w),
    .valid_o (valid_o_i_w),
    .ready_o (ready_o_o_w),
    .data_o  (data_o_i_w)
  );

  // ----------------------------- Level-mapping localparams (TUMCREATE M-A5) -----------------------------
  localparam integer PK_BYTES_L     = (`SEC_LVL == 2) ? `PK_BYTES_2   : (`SEC_LVL == 3) ? `PK_BYTES_3   : `PK_BYTES_5;
  localparam integer SK_BYTES_L     = (`SEC_LVL == 2) ? `SK_BYTES_2   : (`SEC_LVL == 3) ? `SK_BYTES_3   : `SK_BYTES_5;
  localparam integer SK_s1_BYTES_L  = (`SEC_LVL == 2) ? `SK_s1_BYTES_2 : (`SEC_LVL == 3) ? `SK_s1_BYTES_3 : `SK_s1_BYTES_5;
  localparam integer SK_s2_BYTES_L  = (`SEC_LVL == 2) ? `SK_s2_BYTES_2 : (`SEC_LVL == 3) ? `SK_s2_BYTES_3 : `SK_s2_BYTES_5;
  localparam integer SK_t0_BYTES_L  = (`SEC_LVL == 2) ? `SK_t0_BYTES_2 : (`SEC_LVL == 3) ? `SK_t0_BYTES_3 : `SK_t0_BYTES_5;
  localparam integer PK_t1_BYTES_L  = (`SEC_LVL == 2) ? `PK_t1_BYTES_2 : (`SEC_LVL == 3) ? `PK_t1_BYTES_3 : `PK_t1_BYTES_5;
  localparam integer SIG_BYTES_L    = (`SEC_LVL == 2) ? `SIG_BYTES_2   : (`SEC_LVL == 3) ? `SIG_BYTES_3   : `SIG_BYTES_5;
  localparam integer CTILDE_BYTES_L = (`SEC_LVL == 2) ? `CTILDE_BYTES_2 : (`SEC_LVL == 3) ? `CTILDE_BYTES_3 : `CTILDE_BYTES_5;
  localparam integer z_BYTES_L      = (`SEC_LVL == 2) ? `z_BYTES_2     : (`SEC_LVL == 3) ? `z_BYTES_3     : `z_BYTES_5;
  localparam integer h_BYTES_L      = (`SEC_LVL == 2) ? `h_BYTES_2     : (`SEC_LVL == 3) ? `h_BYTES_3     : `h_BYTES_5;

  // Array widths (must match KAT line length exactly — see M-A5 note)
  localparam integer PK_ARR_W  = (`SEC_LVL == 2) ? `PK_WIDTH_2  : (`SEC_LVL == 3) ? `PK_WIDTH_3  : `PK_WIDTH_5;
  localparam integer SK_ARR_W  = (`SEC_LVL == 2) ? `SK_WIDTH_2  : (`SEC_LVL == 3) ? `SK_WIDTH_3  : `SK_WIDTH_5;
  // TUMCREATE fix (2026-06-18): Sign outputs ceil(SIG_BYTES/8)*8 bytes (pads final
  // word). For sec_lvl=2/5 the unpadded SIG_WIDTH_L is not 8-byte aligned, so reading
  // the last h word from sig_out[SIG_WIDTH_L-64+:64] returned 32 bits of X — verify
  // saw corrupted h and rejected the chained signature. Pad SIG_ARR_W up to the next
  // 64-bit boundary so the captured last word is fully inside the array.
  localparam integer SIG_BYTES_PADDED_L = ((SIG_BYTES_L + 7) / 8) * 8;
  localparam integer SIG_ARR_W = SIG_BYTES_PADDED_L * 8;
  localparam integer CTILDE_W  = (`SEC_LVL == 2) ? `CTILDE_WIDTH_2 : (`SEC_LVL == 3) ? `CTILDE_WIDTH_3 : `CTILDE_WIDTH_5;
  localparam integer z_WIDTH_L = (`SEC_LVL == 2) ? `z_WIDTH_2   : (`SEC_LVL == 3) ? `z_WIDTH_3   : `z_WIDTH_5;

  // KeyGen output word counts
  localparam integer RHO_WORDS = 4;
  localparam integer K_WORDS   = 4;
  localparam integer TR_WORDS  = 8;
  localparam integer S1_WORDS  = SK_s1_BYTES_L / 8;
  localparam integer S2_WORDS  = SK_s2_BYTES_L / 8;
  localparam integer T1_WORDS  = PK_t1_BYTES_L / 8;
  localparam integer T0_WORDS  = SK_t0_BYTES_L / 8;

  // Cumulative word index thresholds for KeyGen output drain
  localparam integer RHO_W_END = RHO_WORDS;
  localparam integer K_W_END   = RHO_W_END + K_WORDS;
  localparam integer S1_W_END  = K_W_END   + S1_WORDS;
  localparam integer S2_W_END  = S1_W_END  + S2_WORDS;
  localparam integer T1_W_END  = S2_W_END  + T1_WORDS;
  localparam integer T0_W_END  = T1_W_END  + T0_WORDS;
  localparam integer TR_W_END  = T0_W_END  + TR_WORDS;
  localparam integer KG_OUT_TOTAL = TR_W_END;

  // Sign input word counts (rnd is 4 words of zeros)
  localparam integer RND_WORDS = 4;

  // Sign output word counts
  localparam integer z_WORDS_OUT     = z_BYTES_L / 8;
  localparam integer h_WORDS_OUT     = (h_BYTES_L + 7) / 8;
  localparam integer CTILDE_WORDS_OUT = CTILDE_BYTES_L / 8;
  localparam integer SG_OUT_TOTAL    = z_WORDS_OUT + h_WORDS_OUT + CTILDE_WORDS_OUT;

  // Verify input word counts (RHO_WORDS + CTILDE + z + T1 + 1 + fmt + h)
  // (computed at runtime for fmt_word_len)

  // ----------------------------- KAT inputs -----------------------------
  localparam NUM_TV = 1;
  localparam MAX_MLEN = 8192*8;

  // KeyGen seed
  reg [0 : 256-1]                seed    [NUM_TV - 1 : 0];
  // Sign/Verify message from KAT
  reg [0 : MAX_MLEN - 1]         message [NUM_TV - 1 : 0];
  reg [31:0]                     mlen    [NUM_TV - 1 : 0];
  reg [0 : `CTX_WIDTH - 1]       ctx     [NUM_TV - 1 : 0];
  reg [31:0]                     ctxlen  [NUM_TV - 1 : 0];

  // Phase outputs (filled in by each phase, used as inputs to next phase)
  reg [0 : PK_ARR_W - 1]         pk_out;
  reg [0 : SK_ARR_W - 1]         sk_out;
  reg [0 : SIG_ARR_W - 1]        sig_out;

  // KAT reference vectors for per-phase comparison
  reg [0 : PK_ARR_W - 1]         pk_kat  [0:0];
  reg [0 : SK_ARR_W - 1]         sk_kat  [0:0];
  reg [0 : SIG_ARR_W - 1]        sig_kat [0:0];
  // SigGen KAT SK (separate from KeyGen KAT SK — different key material)
  reg [0 : SK_ARR_W - 1]         sg_sk_kat [0:0];
  integer kg_mismatches, sg_mismatches;
  integer sk_match_sg;  // 1 = KeyGen SK matches SigGen KAT SK

  // Formatted message buffer (shared by Sign and Verify)
  reg [0 : MAX_MLEN + 2*8 + `CTX_WIDTH - 1] message_fmtd [NUM_TV - 1 : 0];

  integer c, i, j;
  integer wr_idx, recv_idx, fmt_word_len, fmt_byte_len;
  integer total_cycles, drain_wait;
  integer kg_cycles, sg_cycles, vy_cycles;
  logic [63:0] mlen_ctxlen_word;
  logic [63:0] result_word;
  logic        result_fail;
  logic [63:0] status_r;
  logic [63:0] data_r;
  integer start_time;
  integer kg_start, sg_start, vy_start;
  // TUMCREATE DEBUG (2026-06-19): Verify-phase TB push counter for bridge drop detection.
`ifdef BRG_DEBUG
  integer tb_vy_push_ctr;
  logic  vy_active;
`endif

  // ----------------------------- AXI Master BFM tasks -----------------------------
  task axi_write(input logic [63:0] addr, input logic [63:0] data);
    begin
      axi.aw_id      = 5'b0;
      axi.aw_addr    = addr;
      axi.aw_len     = 8'b0;
      axi.aw_size    = 3'b011;
      axi.aw_burst   = 2'b00;
      axi.aw_lock    = 1'b0;
      axi.aw_cache   = 4'b0;
      axi.aw_prot    = 3'b0;
      axi.aw_qos     = 4'b0;
      axi.aw_region  = 4'b0;
      axi.aw_atop    = 5'b0;
      axi.aw_user    = 1'b0;
      axi.aw_valid   = 1'b1;
      axi.w_data     = data;
      axi.w_strb     = 8'hFF;
      axi.w_last     = 1'b1;
      axi.w_user     = 1'b0;
      axi.w_valid    = 1'b1;
      axi.b_ready    = 1'b1;

      while (!(axi.aw_ready && axi.w_ready)) begin
        @(posedge clk);
        if (axi.aw_ready) axi.aw_valid = 1'b0;
        if (axi.w_ready)  axi.w_valid  = 1'b0;
      end
      @(posedge clk);
      axi.aw_valid = 1'b0;
      axi.w_valid  = 1'b0;

      while (!axi.b_valid) @(posedge clk);
      @(posedge clk);
      axi.b_ready = 1'b0;
    end
  endtask

  task axi_read(input logic [63:0] addr, output logic [63:0] data);
    begin
      axi.ar_id      = 5'b0;
      axi.ar_addr    = addr;
      axi.ar_len     = 8'b0;
      axi.ar_size    = 3'b011;
      axi.ar_burst   = 2'b00;
      axi.ar_lock    = 1'b0;
      axi.ar_cache   = 4'b0;
      axi.ar_prot    = 3'b0;
      axi.ar_qos     = 4'b0;
      axi.ar_region  = 4'b0;
      axi.ar_user    = 1'b0;
      axi.ar_valid   = 1'b1;
      axi.r_ready    = 1'b1;

      while (!axi.ar_ready) @(posedge clk);
      @(posedge clk);
      axi.ar_valid = 1'b0;

      while (!axi.r_valid) @(posedge clk);
      data = axi.r_data;
      @(posedge clk);
      axi.r_ready = 1'b0;
    end
  endtask

  task push_input_word(input logic [63:0] data);
    logic [63:0] s;
    begin
      axi_read(64'h18, s);
      while (s[1] === 1'b1) begin
        repeat (20) @(posedge clk);
        axi_read(64'h18, s);
      end
      axi_write(64'h08, data);
      // TUMCREATE DEBUG (2026-06-19): TB-side push counter for Verify phase.
      // Compare against bridge's brg_push_ctr to detect silent FIFO drops.
`ifdef BRG_DEBUG
      if (vy_active === 1'b1) begin
        tb_vy_push_ctr = tb_vy_push_ctr + 1;
        $display("[TB %0t] PUSH vy_idx=%0d data=0x%016x", $time, tb_vy_push_ctr, data);
      end
`endif
    end
  endtask

  // ----------------------------- Main test sequence -----------------------------
  initial begin
    axi.aw_valid = 1'b0; axi.w_valid = 1'b0; axi.b_ready = 1'b0;
    axi.ar_valid = 1'b0; axi.r_ready = 1'b0;

    // TUMCREATE M-A5: branched on `SEC_LVL for KAT filenames
    if (`SEC_LVL == 2) begin
      $readmemh("KeyGen_seed_44.txt",     seed, 0, 0);
      $readmemh("SigGen_message_44.txt",  message, 0, 0);
      $readmemh("SigGen_mlen_44.txt",     mlen, 0, 0);
      $readmemh("SigGen_ctx_44.txt",      ctx, 0, 0);
      $readmemh("SigGen_ctxlen_44.txt",   ctxlen, 0, 0);
      $readmemh("KeyGen_pk_44.txt",       pk_kat, 0, 0);
      $readmemh("KeyGen_sk_44.txt",       sk_kat, 0, 0);
      $readmemh("SigGen_signature_44.txt", sig_kat, 0, 0);
      $readmemh("SigGen_sk_44.txt",       sg_sk_kat, 0, 0);
    end else if (`SEC_LVL == 3) begin
      $readmemh("KeyGen_seed_65.txt",     seed, 0, 0);
      $readmemh("SigGen_message_65.txt",  message, 0, 0);
      $readmemh("SigGen_mlen_65.txt",     mlen, 0, 0);
      $readmemh("SigGen_ctx_65.txt",      ctx, 0, 0);
      $readmemh("SigGen_ctxlen_65.txt",   ctxlen, 0, 0);
      $readmemh("KeyGen_pk_65.txt",       pk_kat, 0, 0);
      $readmemh("KeyGen_sk_65.txt",       sk_kat, 0, 0);
      $readmemh("SigGen_signature_65.txt", sig_kat, 0, 0);
      $readmemh("SigGen_sk_65.txt",       sg_sk_kat, 0, 0);
    end else begin
      $readmemh("KeyGen_seed_87.txt",     seed, 0, 0);
      $readmemh("SigGen_message_87.txt",  message, 0, 0);
      $readmemh("SigGen_mlen_87.txt",     mlen, 0, 0);
      $readmemh("SigGen_ctx_87.txt",      ctx, 0, 0);
      $readmemh("SigGen_ctxlen_87.txt",   ctxlen, 0, 0);
      $readmemh("KeyGen_pk_87.txt",       pk_kat, 0, 0);
      $readmemh("KeyGen_sk_87.txt",       sk_kat, 0, 0);
      $readmemh("SigGen_signature_87.txt", sig_kat, 0, 0);
      $readmemh("SigGen_sk_87.txt",       sg_sk_kat, 0, 0);
    end

    c = 0;
    pk_out = 0;
    sk_out = 0;
    sig_out = 0;

    // ---------- Build message_fmtd ----------
    message_fmtd[c] = 0;
    message_fmtd[c][0 +: 8] = 8'd0;
    message_fmtd[c][8 +: 8] = ctxlen[c][7:0];
    for (i = 0; i < ctxlen[c]; i = i + 1) begin
      message_fmtd[c][16 + i*8 +: 8] = ctx[c][(`CTX_BYTES - ctxlen[c])*8 + i*8 +: 8];
    end
    for (i = 0; i < mlen[c]; i = i + 1) begin
      message_fmtd[c][16 + ctxlen[c]*8 + i*8 +: 8] = message[c][(MAX_MLEN - mlen[c]*8) + i*8 +: 8];
    end
    fmt_byte_len = 2 + ctxlen[c] + mlen[c];
    fmt_word_len = (fmt_byte_len + 7) / 8;
    $display("=== [e2e] KAT #%0d (sec_lvl=%0d): mlen=%0d ctxlen=%0d, fmt_words=%0d ===",
             c, `SEC_LVL, mlen[c], ctxlen[c], fmt_word_len);

    // ---------- Reset ----------
    rst_n = 0;
    repeat (20) @(posedge clk);
    rst_n = 1;
    repeat (5) @(posedge clk);

    // =====================================================================
    // PHASE 1: KeyGen (mode=0)
    // =====================================================================
    $display("");
    $display("=== Phase 1: KeyGen ===");
    kg_start = $time;

    // Push seed (4 words) to prime FIFO
    for (i = 0; i < RHO_WORDS; i = i + 1)
      push_input_word(seed[c][i*64 +: 64]);

    // TUMCREATE: CTRL = (sec_lvl << 3) | (mode=0 << 1) | start=1 (KeyGen)
    axi_write(64'h00, ((`SEC_LVL & 8'h07) << 3) | (8'h00 << 1) | 8'h01);
    $display("  Wrote CTRL=%02xh (KeyGen, sec_lvl=%0d)", ((`SEC_LVL & 8'h07) << 3) | 8'h01, `SEC_LVL);

    // Drain KeyGen output
    wr_idx = 0;
    while (wr_idx < KG_OUT_TOTAL) begin
      axi_read(64'h18, status_r);
      if (status_r[2] === 1'b0) begin
        axi_read(64'h10, data_r);
        if (wr_idx < RHO_W_END) begin
          pk_out[wr_idx*64 +: 64] = data_r;
          sk_out[wr_idx*64 +: 64] = data_r;
        end else if (wr_idx < K_W_END) begin
          sk_out[`SKPK_RHO_WIDTH + (wr_idx - RHO_W_END)*64 +: 64] = data_r;
        end else if (wr_idx < S1_W_END) begin
          sk_out[`SKPK_RHO_WIDTH + `SK_K_WIDTH + `SK_tr_WIDTH + (wr_idx - K_W_END)*64 +: 64] = data_r;
        end else if (wr_idx < S2_W_END) begin
          sk_out[`SKPK_RHO_WIDTH + `SK_K_WIDTH + `SK_tr_WIDTH + SK_s1_BYTES_L*8 + (wr_idx - S1_W_END)*64 +: 64] = data_r;
        end else if (wr_idx < T1_W_END) begin
          pk_out[`SKPK_RHO_WIDTH + (wr_idx - S2_W_END)*64 +: 64] = data_r;
        end else if (wr_idx < T0_W_END) begin
          sk_out[`SKPK_RHO_WIDTH + `SK_K_WIDTH + `SK_tr_WIDTH + SK_s1_BYTES_L*8 + SK_s2_BYTES_L*8 + (wr_idx - T1_W_END)*64 +: 64] = data_r;
        end else begin
          sk_out[`SKPK_RHO_WIDTH + `SK_K_WIDTH + (wr_idx - T0_W_END)*64 +: 64] = data_r;
        end
        wr_idx = wr_idx + 1;
      end else begin
        repeat (20) @(posedge clk);
      end
    end
    kg_cycles = ($time - kg_start) / 10;
    $display("  KeyGen complete: %0d words drained, cycles=%0d", wr_idx, kg_cycles);

    // KAT comparison for KeyGen output
    kg_mismatches = 0;
    for (i = 0; i < PK_BYTES_L; i = i + 1) begin
      if (pk_out[i*8 +: 8] !== pk_kat[0][i*8 +: 8]) begin
        if (kg_mismatches < 3)
          $display("  [KG PK mismatch] byte %0d: got %h, KAT %h", i, pk_out[i*8 +: 8], pk_kat[0][i*8 +: 8]);
        kg_mismatches = kg_mismatches + 1;
      end
    end
    for (i = 0; i < SK_BYTES_L; i = i + 1) begin
      if (sk_out[i*8 +: 8] !== sk_kat[0][i*8 +: 8]) begin
        if (kg_mismatches < 3)
          $display("  [KG SK mismatch] byte %0d: got %h, KAT %h", i, sk_out[i*8 +: 8], sk_kat[0][i*8 +: 8]);
        kg_mismatches = kg_mismatches + 1;
      end
    end
    if (kg_mismatches == 0)
      $display("  [KAT check] KeyGen: PK+SK match KAT reference");
    else
      $display("  [KAT check] KeyGen: %0d byte mismatches vs KAT", kg_mismatches);

    // Wait for bridge to settle
    repeat (100) @(posedge clk);

    // =====================================================================
    // PHASE 2: Sign (mode=2) using sk_out + KAT message
    // =====================================================================
    $display("");
    $display("=== Phase 2: Sign ===");
    sg_start = $time;

    // Clear CTRL start bit so ctrl_start_rise fires for Phase 2.
    axi_write(64'h00, 64'h00);
    $display("  Wrote CTRL=0x00 (clear start bit)");
    repeat (10) @(posedge clk);

    // Push SK rho word 0 to prime FIFO
    push_input_word(sk_out[0*64 +: 64]);

    // TUMCREATE: CTRL = (sec_lvl << 3) | (mode=2 << 1) | start=1 (Sign)
    axi_write(64'h00, ((`SEC_LVL & 8'h07) << 3) | (8'h02 << 1) | 8'h01);
    $display("  Wrote CTRL=%02xh (Sign, sec_lvl=%0d)", ((`SEC_LVL & 8'h07) << 3) | (8'h02 << 1) | 8'h01, `SEC_LVL);

    // Push SK rho words 1..3
    for (i = 1; i < RHO_WORDS; i = i + 1)
      push_input_word(sk_out[i*64 +: 64]);

    // mlen + ctxlen combined
    mlen_ctxlen_word = {48'd0, mlen[c] + ctxlen[c]};
    push_input_word(mlen_ctxlen_word);

    // SK tr (TR_WORDS words) at sk[SKPK_RHO+SK_K+:]
    for (i = 0; i < TR_WORDS; i = i + 1)
      push_input_word(sk_out[`SKPK_RHO_WIDTH + `SK_K_WIDTH + i*64 +: 64]);

    // message_fmtd
    for (i = 0; i < fmt_word_len; i = i + 1)
      push_input_word(message_fmtd[c][i*64 +: 64]);

    // SK K (K_WORDS words) at sk[SKPK_RHO+:]
    for (i = 0; i < K_WORDS; i = i + 1)
      push_input_word(sk_out[`SKPK_RHO_WIDTH + i*64 +: 64]);

    // rnd (RND_WORDS words, zeros)
    for (i = 0; i < RND_WORDS; i = i + 1)
      push_input_word(64'd0);

    // SK s1 at sk[SKPK_RHO+SK_K+SK_tr+:]
    for (i = 0; i < S1_WORDS; i = i + 1)
      push_input_word(sk_out[`SKPK_RHO_WIDTH + `SK_K_WIDTH + `SK_tr_WIDTH + i*64 +: 64]);

    // SK s2 at sk[SKPK_RHO+SK_K+SK_tr+SK_s1+:]
    for (i = 0; i < S2_WORDS; i = i + 1)
      push_input_word(sk_out[`SKPK_RHO_WIDTH + `SK_K_WIDTH + `SK_tr_WIDTH + SK_s1_BYTES_L*8 + i*64 +: 64]);

    // SK t0 at sk[SKPK_RHO+SK_K+SK_tr+SK_s1+SK_s2+:]
    for (i = 0; i < T0_WORDS; i = i + 1)
      push_input_word(sk_out[`SKPK_RHO_WIDTH + `SK_K_WIDTH + `SK_tr_WIDTH + SK_s1_BYTES_L*8 + SK_s2_BYTES_L*8 + i*64 +: 64]);

    // Drain Sign output: z + h + ctilde
    recv_idx = 0;
    while (recv_idx < SG_OUT_TOTAL) begin
      axi_read(64'h18, status_r);
      if (status_r[2] === 1'b0) begin
        axi_read(64'h10, data_r);
        if (recv_idx < z_WORDS_OUT) begin
          // z: words 0..z_WORDS_OUT-1 → sig_out[CTILDE_W + recv_idx*64 +:]
          sig_out[CTILDE_W + recv_idx*64 +: 64] = data_r;
        end else if (recv_idx < z_WORDS_OUT + h_WORDS_OUT) begin
          // h → sig_out[CTILDE_W + z_WIDTH_L + (recv_idx-z_WORDS_OUT)*64 +:]
          sig_out[CTILDE_W + z_WIDTH_L + (recv_idx - z_WORDS_OUT)*64 +: 64] = data_r;
        end else begin
          // ctilde → sig_out[(recv_idx-z_WORDS_OUT-h_WORDS_OUT)*64 +:]
          sig_out[(recv_idx - z_WORDS_OUT - h_WORDS_OUT)*64 +: 64] = data_r;
        end
        recv_idx = recv_idx + 1;
      end else begin
        repeat (50) @(posedge clk);
      end
    end
    sg_cycles = ($time - sg_start) / 10;
    $display("  Sign complete: %0d words drained, cycles=%0d", recv_idx, sg_cycles);

    // TUMCREATE DEBUG (2026-06-18): dump first/last sig bytes for inspection.
    // sig_out layout: [ctilde 32B][z 2304B][h 88B padded]
    $display("  [SG dump] ctilde w0..3: %h %h %h %h",
             sig_out[0*64+:64], sig_out[1*64+:64], sig_out[2*64+:64], sig_out[3*64+:64]);
    $display("  [SG dump] z w0..3:      %h %h %h %h",
             sig_out[CTILDE_W+0*64+:64], sig_out[CTILDE_W+1*64+:64],
             sig_out[CTILDE_W+2*64+:64], sig_out[CTILDE_W+3*64+:64]);
    $display("  [SG dump] z w284..287:  %h %h %h %h",
             sig_out[CTILDE_W+284*64+:64], sig_out[CTILDE_W+285*64+:64],
             sig_out[CTILDE_W+286*64+:64], sig_out[CTILDE_W+287*64+:64]);
    $display("  [SG dump] h w0..3:      %h %h %h %h",
             sig_out[CTILDE_W+z_WIDTH_L+0*64+:64], sig_out[CTILDE_W+z_WIDTH_L+1*64+:64],
             sig_out[CTILDE_W+z_WIDTH_L+2*64+:64], sig_out[CTILDE_W+z_WIDTH_L+3*64+:64]);
    $display("  [SG dump] h w7..10:     %h %h %h %h",
             sig_out[CTILDE_W+z_WIDTH_L+7*64+:64], sig_out[CTILDE_W+z_WIDTH_L+8*64+:64],
             sig_out[CTILDE_W+z_WIDTH_L+9*64+:64], sig_out[CTILDE_W+z_WIDTH_L+10*64+:64]);
    // Dump first 8 bytes of each h word to check omega termination
    for (i = 0; i < 11; i = i + 1) begin
      $display("  [SG dump] h_word[%0d] = %h  (byte0..7: %h %h %h %h %h %h %h %h)",
               i, sig_out[CTILDE_W+z_WIDTH_L+i*64+:64],
               sig_out[CTILDE_W+z_WIDTH_L+i*64+0*8+:8],
               sig_out[CTILDE_W+z_WIDTH_L+i*64+1*8+:8],
               sig_out[CTILDE_W+z_WIDTH_L+i*64+2*8+:8],
               sig_out[CTILDE_W+z_WIDTH_L+i*64+3*8+:8],
               sig_out[CTILDE_W+z_WIDTH_L+i*64+4*8+:8],
               sig_out[CTILDE_W+z_WIDTH_L+i*64+5*8+:8],
               sig_out[CTILDE_W+z_WIDTH_L+i*64+6*8+:8],
               sig_out[CTILDE_W+z_WIDTH_L+i*64+7*8+:8]);
    end

    // TUMCREATE DEBUG (2026-06-18): dump full sig_out bytes for offline Verify@2 test
    $display("  [SG dump full] begin sig_out bytes (byte_idx byte_val hex):");
    for (i = 0; i < SIG_BYTES_L; i = i + 1) begin
      $display("  [SIGBYTE] %0d %h", i, sig_out[i*8 +: 8]);
    end
    $display("  [SG dump full] end sig_out bytes");

    // Sign KAT comparison only meaningful if KeyGen-produced SK matches SigGen KAT SK
    sk_match_sg = 1;
    for (i = 0; i < SK_BYTES_L; i = i + 1) begin
      if (sk_out[i*8 +: 8] !== sg_sk_kat[0][i*8 +: 8]) begin
        sk_match_sg = 0;
        i = SK_BYTES_L;  // break
      end
    end

    if (sk_match_sg) begin
      sg_mismatches = 0;
      for (i = 0; i < SIG_BYTES_L; i = i + 1) begin
        if (sig_out[i*8 +: 8] !== sig_kat[0][i*8 +: 8]) begin
          if (sg_mismatches < 3)
            $display("  [SG mismatch] byte %0d: got %h, KAT %h", i, sig_out[i*8 +: 8], sig_kat[0][i*8 +: 8]);
          sg_mismatches = sg_mismatches + 1;
        end
      end
      if (sg_mismatches == 0)
        $display("  [KAT check] Sign: signature matches KAT reference (SK matches SigGen KAT)");
      else
        $display("  [KAT check] Sign: %0d byte mismatches vs KAT (SK matches but sig differs — bug?)", sg_mismatches);
    end else begin
      $display("  [KAT check] Sign: SKIPPED — e2e KeyGen SK differs from SigGen KAT SK (expected: different key material)");
      $display("                         Sign output is validated functionally by Verify(fail=0) below");
    end

    repeat (100) @(posedge clk);

    // =====================================================================
    // PHASE 3: Verify (mode=1) using pk_out + sig_out + KAT message
    // =====================================================================
    $display("");
    $display("=== Phase 3: Verify ===");
    vy_start = $time;
`ifdef BRG_DEBUG
    tb_vy_push_ctr = 0;
    vy_active = 1'b1;
    $display("[TB %0t] VY_ACTIVE=1 — TB push tracking enabled", $time);
`endif

    // Clear CTRL start bit so ctrl_start_rise fires for Phase 3.
    axi_write(64'h00, 64'h00);
    $display("  Wrote CTRL=0x00 (clear start bit)");
    repeat (10) @(posedge clk);

    // Push PK rho word 0 to prime FIFO
    push_input_word(pk_out[0*64 +: 64]);

    // TUMCREATE: CTRL = (sec_lvl << 3) | (mode=1 << 1) | start=1 (Verify)
    axi_write(64'h00, ((`SEC_LVL & 8'h07) << 3) | (8'h01 << 1) | 8'h01);
    $display("  Wrote CTRL=%02xh (Verify, sec_lvl=%0d)", ((`SEC_LVL & 8'h07) << 3) | (8'h01 << 1) | 8'h01, `SEC_LVL);

    // PK rho words 1..3
    for (i = 1; i < RHO_WORDS; i = i + 1)
      push_input_word(pk_out[i*64 +: 64]);

    // c_tilde from sig[0..CTILDE_WORDS_OUT-1]
    for (i = 0; i < CTILDE_WORDS_OUT; i = i + 1)
      push_input_word(sig_out[i*64 +: 64]);

    // z from sig[CTILDE_W +:]
    for (i = 0; i < z_WORDS_OUT; i = i + 1)
      push_input_word(sig_out[CTILDE_W + i*64 +: 64]);

    // PK t1 from pk[SKPK_RHO +:]
    for (i = 0; i < T1_WORDS; i = i + 1)
      push_input_word(pk_out[`SKPK_RHO_WIDTH + i*64 +: 64]);

    // mlen + ctxlen combined
    push_input_word(mlen_ctxlen_word);

    // message_fmtd
    for (i = 0; i < fmt_word_len; i = i + 1)
      push_input_word(message_fmtd[c][i*64 +: 64]);

    // h from sig[CTILDE_W + z_WIDTH_L +:]
    for (i = 0; i < h_WORDS_OUT; i = i + 1)
      push_input_word(sig_out[CTILDE_W + z_WIDTH_L + i*64 +: 64]);

`ifdef BRG_DEBUG
    $display("[TB %0t] VY_PUSHES_COMPLETE tb_vy_push_ctr=%0d", $time, tb_vy_push_ctr);
`endif

    // Drain 1 word: fail bit
    drain_wait = 0;
    result_word = 64'hFFFFFFFFFFFFFFFF;
    begin : vy_drain
      while (drain_wait < 500000) begin
        axi_read(64'h18, status_r);
        if (status_r[2] === 1'b0) begin
          axi_read(64'h10, result_word);
          result_fail = result_word[0];
          disable vy_drain;
        end else begin
          drain_wait = drain_wait + 50;
          repeat (50) @(posedge clk);
        end
      end
    end
    vy_cycles = ($time - vy_start) / 10;
    $display("  Verify complete: result_word=0x%h (fail=%0d), cycles=%0d", result_word, result_fail, vy_cycles);

    // =====================================================================
    // Final verdict
    // =====================================================================
    $display("");
    $display("============================================================");
    $display("=== [e2e] Phase cycles: KG=%0d  Sign=%0d  Verify=%0d", kg_cycles, sg_cycles, vy_cycles);
    if (result_fail === 1'b0) begin
      $display("=== [e2e] RESULT: PASS — Verify accepted sig from chained KeyGen+Sign ===");
      $display("testbench done - PASS");
    end else begin
      $display("=== [e2e] RESULT: FAIL — Verify rejected sig (fail=%0d, expected 0=valid) ===", result_fail);
      $display("testbench done - FAIL");
    end
    $display("============================================================");

    $finish;
  end

  // ----------------------------- Watchdog -----------------------------
  initial begin
    #2_000_000_000; // 2s — e2e runs all three phases
    $display("FAIL: watchdog timeout — e2e sim hung");
    $display("testbench done - FAIL");
    $finish;
  end

endmodule
