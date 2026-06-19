// ==================================================
// Giulio Golinelli - golinelli.giulio13@gmail.com
// TUMCREATE QUASAR RESEARCH ENGINEER
// Modified: 2026-06-18
// This file contains modifications vs. the upstream
// CVA6 / ML-DSA-OSH source fork.
// ==================================================

// Bridge testbench for ML-DSA Verify.
// Drives axi_mldsa_bridge via a minimal AXI4 master BFM (single-beat transactions).
// The bridge wraps combined_top (the accelerator). Output fail bit is compared
// against the NIST SigVer KAT expected result.
//
// Register map (byte offsets, 64-bit data):
//   0x00 CTRL     [WO]  [0]=start  [2:1]=mode  [5:3]=sec_lvl
//   0x08 DATA_IN  [WO]  push 64-bit word to input FIFO
//   0x10 DATA_OUT [RO]  pop 64-bit word from output FIFO
//   0x18 STATUS   [RO]  [0]=in_empty [2]=out_empty [6]=busy
//   0x20 DIAG     [RO]  accelerator internal state
//
// TUMCREATE (M-A4, 2026-06-18): TB now level-aware. KAT arrays sized for the
// active level only (XSIM $readmemh mis-aligns when container is wider than
// KAT line); word counts and offsets via localparams selected by `SEC_LVL;
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

module tb_verify_bridge;

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

  // ----------------------------- Level-mapping localparams (TUMCREATE M-A4) -----------------------------
  localparam integer PK_BYTES_L     = (`SEC_LVL == 2) ? `PK_BYTES_2   : (`SEC_LVL == 3) ? `PK_BYTES_3   : `PK_BYTES_5;
  localparam integer SK_s1_BYTES_L  = (`SEC_LVL == 2) ? `SK_s1_BYTES_2 : (`SEC_LVL == 3) ? `SK_s1_BYTES_3 : `SK_s1_BYTES_5;
  localparam integer SK_s2_BYTES_L  = (`SEC_LVL == 2) ? `SK_s2_BYTES_2 : (`SEC_LVL == 3) ? `SK_s2_BYTES_3 : `SK_s2_BYTES_5;
  localparam integer SK_t0_BYTES_L  = (`SEC_LVL == 2) ? `SK_t0_BYTES_2 : (`SEC_LVL == 3) ? `SK_t0_BYTES_3 : `SK_t0_BYTES_5;
  localparam integer PK_t1_BYTES_L  = (`SEC_LVL == 2) ? `PK_t1_BYTES_2 : (`SEC_LVL == 3) ? `PK_t1_BYTES_3 : `PK_t1_BYTES_5;
  localparam integer SIG_BYTES_L    = (`SEC_LVL == 2) ? `SIG_BYTES_2   : (`SEC_LVL == 3) ? `SIG_BYTES_3   : `SIG_BYTES_5;
  localparam integer CTILDE_BYTES_L = (`SEC_LVL == 2) ? `CTILDE_BYTES_2 : (`SEC_LVL == 3) ? `CTILDE_BYTES_3 : `CTILDE_BYTES_5;
  localparam integer z_BYTES_L      = (`SEC_LVL == 2) ? `z_BYTES_2     : (`SEC_LVL == 3) ? `z_BYTES_3     : `z_BYTES_5;
  localparam integer h_BYTES_L      = (`SEC_LVL == 2) ? `h_BYTES_2     : (`SEC_LVL == 3) ? `h_BYTES_3     : `h_BYTES_5;

  localparam integer PK_ARR_W  = (`SEC_LVL == 2) ? `PK_WIDTH_2  : (`SEC_LVL == 3) ? `PK_WIDTH_3  : `PK_WIDTH_5;
  localparam integer SIG_ARR_W = (`SEC_LVL == 2) ? `SIG_WIDTH_2 : (`SEC_LVL == 3) ? `SIG_WIDTH_3 : `SIG_WIDTH_5;
  localparam integer CTILDE_W  = (`SEC_LVL == 2) ? `CTILDE_WIDTH_2 : (`SEC_LVL == 3) ? `CTILDE_WIDTH_3 : `CTILDE_WIDTH_5;
  localparam integer z_WIDTH_L = (`SEC_LVL == 2) ? `z_WIDTH_2   : (`SEC_LVL == 3) ? `z_WIDTH_3   : `z_WIDTH_5;

  // Per-region word counts (each word = 8 bytes)
  localparam integer RHO_WORDS      = 4;
  localparam integer CTILDE_WORDS   = CTILDE_BYTES_L / 8;     // 4 / 6 / 8
  localparam integer z_WORDS        = z_BYTES_L / 8;          // 288 / 400 / 560
  localparam integer T1_WORDS       = PK_t1_BYTES_L / 8;      // 160 / 240 / 320
  localparam integer h_WORDS        = (h_BYTES_L + 7) / 8;    // 11 / 8 / 11 (padded)

  // ----------------------------- KAT storage (level-specific widths) -----------------------------
  localparam NUM_TV = 1;
  localparam MAX_MLEN = 8192*8;

  reg [0 : PK_ARR_W - 1]        pk        [NUM_TV - 1 : 0];
  reg [0 : MAX_MLEN - 1]        message   [NUM_TV - 1 : 0];
  reg [31:0]                    mlen      [NUM_TV - 1 : 0];
  reg [0 : `CTX_WIDTH - 1]      ctx       [NUM_TV - 1 : 0];
  reg [31:0]                    ctxlen    [NUM_TV - 1 : 0];
  reg [0 : SIG_ARR_W - 1]       sig       [NUM_TV - 1 : 0];
  // Expected output: 1 bit per KAT (0=valid, 1=invalid)
  reg [0 : 0]                   verif     [NUM_TV - 1 : 0];

  // Formatted message buffer: [0] || ctxlen || ctx || msg
  reg [0 : MAX_MLEN + 2*8 + `CTX_WIDTH - 1] message_fmtd [NUM_TV - 1 : 0];

  integer c, i, j;
  integer wr_idx;
  integer fmt_byte_len;
  integer fmt_word_len;
  integer total_input_words;
  integer total_output_words;
  logic [63:0] mlen_ctxlen_word;
  logic [63:0] result_word;
  logic        result_fail;

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
  integer start_time;
  integer total_cycles;
  integer drain_wait_cycles;

  initial begin
    // Initialize AXI signals
    axi.aw_valid = 1'b0; axi.w_valid = 1'b0; axi.b_ready = 1'b0;
    axi.ar_valid = 1'b0; axi.r_ready = 1'b0;

    // Load KAT (TUMCREATE M-A4: branched on `SEC_LVL)
    if (`SEC_LVL == 2) begin
      $readmemh("SigVer_pk_44.txt",         pk, 0, 0);
      $readmemh("SigVer_message_44.txt",    message, 0, 0);
      $readmemh("SigVer_mlen_44.txt",       mlen, 0, 0);
      $readmemh("SigVer_ctx_44.txt",        ctx, 0, 0);
      $readmemh("SigVer_ctxlen_44.txt",     ctxlen, 0, 0);
      $readmemh("SigVer_signature_44.txt",  sig, 0, 0);
      $readmemb("SigVer_result_44.txt",     verif);
    end else if (`SEC_LVL == 3) begin
      $readmemh("SigVer_pk_65.txt",         pk, 0, 0);
      $readmemh("SigVer_message_65.txt",    message, 0, 0);
      $readmemh("SigVer_mlen_65.txt",       mlen, 0, 0);
      $readmemh("SigVer_ctx_65.txt",        ctx, 0, 0);
      $readmemh("SigVer_ctxlen_65.txt",     ctxlen, 0, 0);
      $readmemh("SigVer_signature_65.txt",  sig, 0, 0);
      $readmemb("SigVer_result_65.txt",     verif);
    end else begin
      $readmemh("SigVer_pk_87.txt",         pk, 0, 0);
      $readmemh("SigVer_message_87.txt",    message, 0, 0);
      $readmemh("SigVer_mlen_87.txt",       mlen, 0, 0);
      $readmemh("SigVer_ctx_87.txt",        ctx, 0, 0);
      $readmemh("SigVer_ctxlen_87.txt",     ctxlen, 0, 0);
      $readmemh("SigVer_signature_87.txt",  sig, 0, 0);
      $readmemb("SigVer_result_87.txt",     verif);
    end

    c = 0;

    // ---------- Build message_fmtd ----------
    message_fmtd[c] = 0;
    message_fmtd[c][0 +: 8]  = 8'd0;
    message_fmtd[c][8 +: 8]  = ctxlen[c][7:0];
    for (i = 0; i < ctxlen[c]; i = i + 1) begin
      message_fmtd[c][16 + i*8 +: 8] = ctx[c][(`CTX_BYTES - ctxlen[c])*8 + i*8 +: 8];
    end
    for (i = 0; i < mlen[c]; i = i + 1) begin
      message_fmtd[c][16 + ctxlen[c]*8 + i*8 +: 8] = message[c][(MAX_MLEN - mlen[c]*8) + i*8 +: 8];
    end
    fmt_byte_len = 2 + ctxlen[c] + mlen[c];
    fmt_word_len = (fmt_byte_len + 7) / 8;
    $display("=== [Bridge Verify] KAT #%0d (sec_lvl=%0d): mlen=%0d ctxlen=%0d, fmt_bytes=%0d fmt_words=%0d, expected_fail=%0d ===",
             c, `SEC_LVL, mlen[c], ctxlen[c], fmt_byte_len, fmt_word_len, verif[c]);

    // ---------- Reset ----------
    rst_n = 0;
    repeat (20) @(posedge clk);
    rst_n = 1;
    repeat (5) @(posedge clk);

    start_time = $time;

    // ---------- Push FIRST input word to prime FIFO ----------
    push_input_word(pk[c][0*64 +: 64]);  // PK rho word 0

    // ---------- Start Verify NOW ----------
    // TUMCREATE: CTRL = (sec_lvl << 3) | (mode=1 << 1) | start=1.
    // sec_lvl=2 → 0x13; sec_lvl=3 → 0x1B; sec_lvl=5 → 0x2B.
    axi_write(64'h00, ((`SEC_LVL & 8'h07) << 3) | (8'h01 << 1) | 8'h01);
    $display("  Wrote CTRL=%02xh (mode=Verify=1, sec_lvl=%0d, start=1) after priming with 1 word",
             ((`SEC_LVL & 8'h07) << 3) | (8'h01 << 1) | 8'h01, `SEC_LVL);

    // ---------- Push remaining input words ----------
    // 1. PK rho words 1..3 (word 0 already pushed)
    for (i = 1; i < RHO_WORDS; i = i + 1)
      push_input_word(pk[c][i*64 +: 64]);

    // 2. c_tilde from sig[0 +:]
    for (i = 0; i < CTILDE_WORDS; i = i + 1)
      push_input_word(sig[c][i*64 +: 64]);

    // 3. z from sig[CTILDE_WIDTH_L +:]
    for (i = 0; i < z_WORDS; i = i + 1)
      push_input_word(sig[c][CTILDE_W + i*64 +: 64]);

    // 4. PK t1 from pk[SKPK_RHO_WIDTH +:]
    for (i = 0; i < T1_WORDS; i = i + 1)
      push_input_word(pk[c][`SKPK_RHO_WIDTH + i*64 +: 64]);

    // 5. mlen + ctxlen combined (1 word)
    mlen_ctxlen_word = {48'd0, mlen[c] + ctxlen[c]};
    push_input_word(mlen_ctxlen_word);

    // 6. message_fmtd
    for (i = 0; i < fmt_word_len; i = i + 1)
      push_input_word(message_fmtd[c][i*64 +: 64]);

    // 7. h from sig[CTILDE_WIDTH_L + z_WIDTH_L +:]
    for (i = 0; i < h_WORDS; i = i + 1)
      push_input_word(sig[c][CTILDE_W + z_WIDTH_L + i*64 +: 64]);

    total_input_words = RHO_WORDS + CTILDE_WORDS + z_WORDS + T1_WORDS + 1 + fmt_word_len + h_WORDS;
    $display("  Pushed %0d input words total. Draining output...", total_input_words);

    // ---------- Drain DATA_OUT — expect exactly 1 word ----------
    total_output_words = 1;
    drain_wait_cycles = 0;
    result_word = 64'hFFFFFFFFFFFFFFFF;  // sentinel
    begin : drain_loop
      while (drain_wait_cycles < 200000) begin
        axi_read(64'h18, status_r);
        if (status_r[2] === 1'b0) begin  // !out_empty
          axi_read(64'h10, result_word);
          result_fail = result_word[0];
          $display("  Got result word: 0x%h (fail bit = %0d)", result_word, result_fail);
          disable drain_loop;
        end else begin
          drain_wait_cycles = drain_wait_cycles + 50;
          repeat (50) @(posedge clk);
        end
      end
    end

    total_cycles = ($time - start_time) / 10;
    $display("  Drain complete: result_word=0x%h, cycles=%0d", result_word, total_cycles);

    // ---------- Compare ----------
    $display("");
    if (result_fail === verif[c][0]) begin
      $display("=== [Bridge Verify] RESULT: PASS (fail=%0d matches expected=%0d), cycles=%0d ===",
               result_fail, verif[c][0], total_cycles);
      $display("testbench done - PASS");
    end else begin
      $display("=== [Bridge Verify] RESULT: FAIL (got fail=%0d, expected=%0d), cycles=%0d ===",
               result_fail, verif[c][0], total_cycles);
      $display("testbench done - FAIL");
    end

    $finish;
  end

  // ----------------------------- Watchdog -----------------------------
  initial begin
    #500_000_000; // 500ms — verify pipeline should finish within this
    $display("FAIL: watchdog timeout — bridge Verify sim hung");
    $display("testbench done - FAIL");
    $finish;
  end

endmodule
