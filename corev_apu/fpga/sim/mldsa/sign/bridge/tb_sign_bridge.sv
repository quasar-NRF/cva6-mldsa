// ==================================================
// Giulio Golinelli - golinelli.giulio13@gmail.com
// TUMCREATE QUASAR RESEARCH ENGINEER
// Modified: 2026-06-18
// This file contains modifications vs. the upstream
// CVA6 / ML-DSA-OSH source fork.
// ==================================================

// Bridge testbench for ML-DSA Sign.
// Drives axi_mldsa_bridge via a minimal AXI4 master BFM (single-beat transactions).
// The bridge wraps combined_top (the accelerator). Output signature is compared
// byte-for-byte against the NIST KAT.
//
// Register map (byte offsets, 64-bit data):
//   0x00 CTRL     [WO]  [0]=start  [2:1]=mode  [5:3]=sec_lvl
//   0x08 DATA_IN  [WO]  push 64-bit word to input FIFO
//   0x10 DATA_OUT [RO]  pop 64-bit word from output FIFO
//   0x18 STATUS   [RO]  [0]=in_empty [2]=out_empty [6]=busy
//   0x20 DIAG     [RO]  accelerator internal state
//
// TUMCREATE (M-A3, 2026-06-18): TB now level-aware. KAT arrays sized for sec_lvl=5
// (largest); level-specific word counts via localparams selected by `SEC_LVL;
// KAT filenames branched on `SEC_LVL.

`include "mldsa_params.v"
`include "axi/typedef.svh"
`include "axi/assign.svh"

`timescale 1ns / 1ps

// TUMCREATE: Compile-time security level. Forwarded via xvlog/xelab -d SEC_LVL=X.
// Default 3 (ML-DSA-65) for backward compatibility.
`ifndef SEC_LVL
  `define SEC_LVL 3
`endif

module tb_sign_bridge;

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

  // ----------------------------- Level-mapping localparams (TUMCREATE M-A3) -----------------------------
  localparam integer SK_BYTES_L     = (`SEC_LVL == 2) ? `SK_BYTES_2   : (`SEC_LVL == 3) ? `SK_BYTES_3   : `SK_BYTES_5;
  localparam integer SK_s1_BYTES_L  = (`SEC_LVL == 2) ? `SK_s1_BYTES_2 : (`SEC_LVL == 3) ? `SK_s1_BYTES_3 : `SK_s1_BYTES_5;
  localparam integer SK_s2_BYTES_L  = (`SEC_LVL == 2) ? `SK_s2_BYTES_2 : (`SEC_LVL == 3) ? `SK_s2_BYTES_3 : `SK_s2_BYTES_5;
  localparam integer SK_t0_BYTES_L  = (`SEC_LVL == 2) ? `SK_t0_BYTES_2 : (`SEC_LVL == 3) ? `SK_t0_BYTES_3 : `SK_t0_BYTES_5;
  localparam integer SIG_BYTES_L    = (`SEC_LVL == 2) ? `SIG_BYTES_2   : (`SEC_LVL == 3) ? `SIG_BYTES_3   : `SIG_BYTES_5;
  localparam integer CTILDE_BYTES_L = (`SEC_LVL == 2) ? `CTILDE_BYTES_2 : (`SEC_LVL == 3) ? `CTILDE_BYTES_3 : `CTILDE_BYTES_5;
  localparam integer z_BYTES_L      = (`SEC_LVL == 2) ? `z_BYTES_2     : (`SEC_LVL == 3) ? `z_BYTES_3     : `z_BYTES_5;
  localparam integer h_BYTES_L      = (`SEC_LVL == 2) ? `h_BYTES_2     : (`SEC_LVL == 3) ? `h_BYTES_3     : `h_BYTES_5;

  // Per-region word counts (each word = 8 bytes)
  localparam integer RHO_WORDS  = 4;                                // 32 bytes
  localparam integer K_WORDS    = 4;                                // 32 bytes
  localparam integer TR_WORDS   = 8;                                // 64 bytes
  localparam integer RND_WORDS  = 4;                                // 32 bytes
  localparam integer S1_WORDS   = SK_s1_BYTES_L / 8;
  localparam integer S2_WORDS   = SK_s2_BYTES_L / 8;
  localparam integer T0_WORDS   = SK_t0_BYTES_L / 8;

  // Output word counts (z and ctilde are exact in bytes; h padded to word boundary)
  localparam integer z_WORDS_OUT     = z_BYTES_L / 8;       // 288 / 400 / 560
  localparam integer h_WORDS_OUT     = (h_BYTES_L + 7) / 8; // 11 / 8 / 11 (with padding)
  localparam integer CTILDE_WORDS_OUT = CTILDE_BYTES_L / 8; // 4 / 6 / 8
  localparam integer TOTAL_OUT_WORDS = z_WORDS_OUT + h_WORDS_OUT + CTILDE_WORDS_OUT;

  // ----------------------------- KAT storage (level-specific widths) -----------------------------
  // TUMCREATE M-A3 (2026-06-18): width MUST match KAT line length exactly.
  // Earlier attempt used a widest-case container but XSIM $readmemh mis-aligns
  // when the loaded hex string is shorter than the container width.
  localparam integer SK_ARR_W  = (`SEC_LVL == 2) ? `SK_WIDTH_2  : (`SEC_LVL == 3) ? `SK_WIDTH_3  : `SK_WIDTH_5;
  localparam integer SIG_ARR_W = (`SEC_LVL == 2) ? `SIG_WIDTH_2 : (`SEC_LVL == 3) ? `SIG_WIDTH_3 : `SIG_WIDTH_5;
  localparam NUM_TV = 1;
  localparam MAX_MLEN = 8192*8;

  // Raw KAT inputs
  reg [0 : SK_ARR_W - 1]       sk      [NUM_TV - 1 : 0];
  reg [0 : MAX_MLEN - 1]       message [NUM_TV - 1 : 0];
  reg [31:0]                   mlen    [NUM_TV - 1 : 0];
  reg [0 : `CTX_WIDTH - 1]     ctx      [NUM_TV - 1 : 0];
  reg [31:0]                   ctxlen  [NUM_TV - 1 : 0];
  reg [0 : SIG_ARR_W - 1]      sig     [NUM_TV - 1 : 0];

  // Formatted message buffer: [0] || ctxlen || ctx || msg
  reg [0 : MAX_MLEN + 2*8 + `CTX_WIDTH - 1] message_fmtd [NUM_TV - 1 : 0];

  // Captured signature output (level-specific width)
  reg [0 : SIG_ARR_W - 1]      sig_out;

  integer c, i, j;
  integer wr_idx;          // input word index
  integer recv_idx;        // output word index (z, then h, then ctilde)
  integer fmt_byte_len;    // total bytes in message_fmtd
  integer fmt_word_len;    // total words in message_fmtd (ceil)
  integer total_input_words;
  integer total_output_words;
  integer wrong_sig_bytes;
  integer first_wrong, last_wrong;
  integer wrong_ctilde, wrong_z, wrong_h;

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

  // Helper: push one input word, with optional STATUS poll to avoid input FIFO overflow
  task push_input_word(input logic [63:0] data);
    logic [63:0] status_r;
    begin
      // Check input FIFO not full before pushing (STATUS[1]=in_full)
      axi_read(64'h18, status_r);
      while (status_r[1] === 1'b1) begin
        repeat (20) @(posedge clk);
        axi_read(64'h18, status_r);
      end
      axi_write(64'h08, data);
    end
  endtask

  // ----------------------------- Main test sequence -----------------------------
  logic [63:0] status_r;
  logic [63:0] data_r;
  integer start_time;
  integer total_cycles;
  logic [63:0] mlen_ctxlen_word;
  logic [63:0] cur_word;

  initial begin
    // Initialize AXI signals
    axi.aw_valid = 1'b0; axi.w_valid = 1'b0; axi.b_ready = 1'b0;
    axi.ar_valid = 1'b0; axi.r_ready = 1'b0;

    // Load KAT (TUMCREATE M-A3: branched on `SEC_LVL)
    if (`SEC_LVL == 2) begin
      $readmemh("SigGen_sk_44.txt",         sk, 0, 0);
      $readmemh("SigGen_message_44.txt",    message, 0, 0);
      $readmemh("SigGen_mlen_44.txt",       mlen, 0, 0);
      $readmemh("SigGen_ctx_44.txt",        ctx, 0, 0);
      $readmemh("SigGen_ctxlen_44.txt",     ctxlen, 0, 0);
      $readmemh("SigGen_signature_44.txt",  sig, 0, 0);
    end else if (`SEC_LVL == 3) begin
      $readmemh("SigGen_sk_65.txt",         sk, 0, 0);
      $readmemh("SigGen_message_65.txt",    message, 0, 0);
      $readmemh("SigGen_mlen_65.txt",       mlen, 0, 0);
      $readmemh("SigGen_ctx_65.txt",        ctx, 0, 0);
      $readmemh("SigGen_ctxlen_65.txt",     ctxlen, 0, 0);
      $readmemh("SigGen_signature_65.txt",  sig, 0, 0);
    end else begin
      $readmemh("SigGen_sk_87.txt",         sk, 0, 0);
      $readmemh("SigGen_message_87.txt",    message, 0, 0);
      $readmemh("SigGen_mlen_87.txt",       mlen, 0, 0);
      $readmemh("SigGen_ctx_87.txt",        ctx, 0, 0);
      $readmemh("SigGen_ctxlen_87.txt",     ctxlen, 0, 0);
      $readmemh("SigGen_signature_87.txt",  sig, 0, 0);
    end

    sig_out = 0;
    c = 0;
    wrong_sig_bytes = 0;
    recv_idx = 0;

    // ---------- Build message_fmtd ----------
    message_fmtd[c] = 0;
    message_fmtd[c][0 +: 8]  = 8'd0;
    message_fmtd[c][8 +: 8]  = ctxlen[c][7:0];
    for (i = 0; i < ctxlen[c]; i = i + 1) begin
      message_fmtd[c][16 + i*8 +: 8] = ctx[c][(255-ctxlen[c])*8 + i*8 +: 8];
    end
    for (i = 0; i < mlen[c]; i = i + 1) begin
      message_fmtd[c][16 + ctxlen[c]*8 + i*8 +: 8] = message[c][(MAX_MLEN - mlen[c]*8) + i*8 +: 8];
    end
    fmt_byte_len = 2 + ctxlen[c] + mlen[c];
    fmt_word_len = (fmt_byte_len + 7) / 8;
    $display("=== [Bridge Sign] KAT #%0d (sec_lvl=%0d): mlen=%0d ctxlen=%0d, fmt_bytes=%0d fmt_words=%0d ===",
             c, `SEC_LVL, mlen[c], ctxlen[c], fmt_byte_len, fmt_word_len);

    // ---------- Reset ----------
    rst_n = 0;
    repeat (20) @(posedge clk);
    rst_n = 1;
    repeat (5) @(posedge clk);

    start_time = $time;

    // ---------- Push FIRST input word to prime FIFO ----------
    push_input_word(sk[c][0*64 +: 64]);  // SK rho word 0

    // ---------- Start Sign NOW ----------
    // TUMCREATE: CTRL = (sec_lvl << 3) | (mode=2 << 1) | start=1.
    // sec_lvl=2 → 0x15; sec_lvl=3 → 0x1D; sec_lvl=5 → 0x2D.
    axi_write(64'h00, ((`SEC_LVL & 8'h07) << 3) | (8'h02 << 1) | 8'h01);
    $display("  Wrote CTRL=%02xh (mode=Sign=2, sec_lvl=%0d, start=1) after priming with 1 word",
             ((`SEC_LVL & 8'h07) << 3) | (8'h02 << 1) | 8'h01, `SEC_LVL);

    // ---------- Push remaining input words ----------
    // 1. SK rho words 1..3 (word 0 already pushed)
    for (i = 1; i < RHO_WORDS; i = i + 1)
      push_input_word(sk[c][i*64 +: 64]);

    // 2. mlen + ctxlen combined (1 word)
    mlen_ctxlen_word = {48'd0, mlen[c] + ctxlen[c]};
    push_input_word(mlen_ctxlen_word);

    // 3. SK tr (8 words)
    for (i = 0; i < TR_WORDS; i = i + 1)
      push_input_word(sk[c][`SKPK_RHO_WIDTH + `SK_K_WIDTH + i*64 +: 64]);

    // 4. message_fmtd
    for (i = 0; i < fmt_word_len; i = i + 1)
      push_input_word(message_fmtd[c][i*64 +: 64]);

    // 5. SK K (4 words)
    for (i = 0; i < K_WORDS; i = i + 1)
      push_input_word(sk[c][`SKPK_RHO_WIDTH + i*64 +: 64]);

    // 6. rnd (4 words, all zeros)
    for (i = 0; i < RND_WORDS; i = i + 1)
      push_input_word(64'd0);

    // 7. SK s1
    for (i = 0; i < S1_WORDS; i = i + 1)
      push_input_word(sk[c][`SKPK_RHO_WIDTH + `SK_K_WIDTH + `SK_tr_WIDTH + i*64 +: 64]);

    // 8. SK s2
    for (i = 0; i < S2_WORDS; i = i + 1)
      push_input_word(sk[c][`SKPK_RHO_WIDTH + `SK_K_WIDTH + `SK_tr_WIDTH + SK_s1_BYTES_L*8 + i*64 +: 64]);

    // 9. SK t0
    for (i = 0; i < T0_WORDS; i = i + 1)
      push_input_word(sk[c][`SKPK_RHO_WIDTH + `SK_K_WIDTH + `SK_tr_WIDTH + SK_s1_BYTES_L*8 + SK_s2_BYTES_L*8 + i*64 +: 64]);

    total_input_words = RHO_WORDS + 1 + TR_WORDS + fmt_word_len + K_WORDS + RND_WORDS + S1_WORDS + S2_WORDS + T0_WORDS;
    $display("  Pushed %0d input words total. Draining output...", total_input_words);

    // ---------- Drain DATA_OUT continuously ----------
    // Output order: z(z_WORDS_OUT) → h(h_WORDS_OUT) → ctilde(CTILDE_WORDS_OUT)
    // TUMCREATE: byte offsets within sig[] use level-specific CTILDE_WIDTH and z_WIDTH macros.
    total_output_words = TOTAL_OUT_WORDS;
    recv_idx = 0;
    while (recv_idx < total_output_words) begin
      axi_read(64'h18, status_r);
      if (status_r[2] === 1'b0) begin  // !out_empty
        axi_read(64'h10, data_r);
        // Route based on word index
        if (recv_idx < z_WORDS_OUT) begin
          // z: words 0..z_WORDS_OUT-1 → sig_out[CTILDE_WIDTH_L + recv_idx*64 +:]
          sig_out[((`SEC_LVL==2)?`CTILDE_WIDTH_2:(`SEC_LVL==3)?`CTILDE_WIDTH_3:`CTILDE_WIDTH_5) + recv_idx*64 +: 64] = data_r;
        end else if (recv_idx < z_WORDS_OUT + h_WORDS_OUT) begin
          // h → sig_out[CTILDE_WIDTH_L + z_WIDTH_L + (recv_idx-z_WORDS_OUT)*64 +:]
          sig_out[((`SEC_LVL==2)?`CTILDE_WIDTH_2:(`SEC_LVL==3)?`CTILDE_WIDTH_3:`CTILDE_WIDTH_5)
                   + ((`SEC_LVL==2)?`z_WIDTH_2:(`SEC_LVL==3)?`z_WIDTH_3:`z_WIDTH_5)
                   + (recv_idx - z_WORDS_OUT)*64 +: 64] = data_r;
        end else begin
          // ctilde → sig_out[0 + (recv_idx - z_WORDS_OUT - h_WORDS_OUT)*64 +:]
          sig_out[(recv_idx - z_WORDS_OUT - h_WORDS_OUT)*64 +: 64] = data_r;
        end
        recv_idx = recv_idx + 1;
      end else begin
        repeat (50) @(posedge clk);
      end
    end
    total_cycles = ($time - start_time) / 10;
    $display("  Drain complete: %0d words, cycles=%0d", recv_idx, total_cycles);

    // ---------- Compare SIG ----------
    first_wrong = -1; last_wrong = -1;
    wrong_ctilde = 0; wrong_z = 0; wrong_h = 0;
    for (i = 0; i < SIG_BYTES_L; i = i + 1) begin
      if (sig_out[i*8 +: 8] !== sig[c][i*8 +: 8]) begin
        wrong_sig_bytes = wrong_sig_bytes + 1;
        if (first_wrong < 0) first_wrong = i;
        last_wrong = i;
        if      (i < CTILDE_BYTES_L)               wrong_ctilde = wrong_ctilde + 1;
        else if (i < CTILDE_BYTES_L + z_BYTES_L)   wrong_z      = wrong_z + 1;
        else                                        wrong_h      = wrong_h + 1;
        if (wrong_sig_bytes <= 10) begin
          $display("[Bridge Sign KAT#%0d, byte sig{%0d}] WRONG: Expected %h, received %h",
                   c, i+1, sig[c][i*8 +: 8], sig_out[i*8 +: 8]);
        end
      end
    end
    $display("  WRONG byte range: [%0d .. %0d] (count=%0d)", first_wrong, last_wrong, wrong_sig_bytes);
    $display("  Per-region: ctilde=%0d/%0d  z=%0d/%0d  h=%0d/%0d",
             wrong_ctilde, CTILDE_BYTES_L, wrong_z, z_BYTES_L, wrong_h, h_BYTES_L);

    $display("");
    $display("=== [Bridge Sign] RESULT: SIG wrong=%0d / %0d, cycles=%0d ===",
             wrong_sig_bytes, SIG_BYTES_L, total_cycles);

    if (wrong_sig_bytes == 0) begin
      $display("testbench done - PASS");
    end else begin
      $display("testbench done - FAIL");
    end

    $finish;
  end

  // ----------------------------- Watchdog -----------------------------
  initial begin
    #500_000_000; // 500ms — long enough for Sign with bridge overhead
    $display("FAIL: watchdog timeout — bridge Sign sim hung");
    $finish;
  end

endmodule
