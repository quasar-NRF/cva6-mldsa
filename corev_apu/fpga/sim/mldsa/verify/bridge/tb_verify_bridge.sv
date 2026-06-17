// ==================================================
// Giulio Golinelli - golinelli.giulio13@gmail.com
// TUMCREATE QUASAR RESEARCH ENGINEER
// Modified: 2026-06-17
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
// Verify input word sequence (sec_lvl=3, K=6, L=5):
//   1. PK rho       : 4 words   (32B)
//   2. c_tilde      : 6 words   (48B)
//   3. z            : 400 words (3200B)
//   4. PK t1        : 240 words (1920B)
//   5. mlen+ctxlen  : 1 word
//   6. message_fmtd : ceil((2 + ctxlen + mlen) / 8) words
//   7. h            : 8 words   (61B, last padded)
//
// Verify output: 1 word, bit 0 = fail (0=valid, 1=invalid)

`include "mldsa_params.v"
`include "axi/typedef.svh"
`include "axi/assign.svh"

`timescale 1ns / 1ps

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

  // ----------------------------- KAT storage (sec_lvl=3 only) -----------------------------
  localparam NUM_TV = 1;
  localparam MAX_MLEN_3 = 8192*8;

  // Raw KAT inputs
  reg [0 : `PK_BYTES_3*8 - 1]    pk_3      [NUM_TV - 1 : 0];
  reg [0 : MAX_MLEN_3 - 1]       message_3 [NUM_TV - 1 : 0];
  reg [31:0]                     mlen_3    [NUM_TV - 1 : 0];
  reg [0 : `CTX_WIDTH - 1]       context_3 [NUM_TV - 1 : 0];
  reg [31:0]                     ctxlen_3  [NUM_TV - 1 : 0];
  reg [0 : `SIG_WIDTH_3 - 1]     sig_3     [NUM_TV - 1 : 0];
  // Expected output: 1 bit per KAT (0=valid, 1=invalid)
  reg [0 : 0]                    verif_3   [NUM_TV - 1 : 0];

  // Formatted message buffer: [0] || ctxlen || ctx || msg
  reg [0 : MAX_MLEN_3 + 2*8 + `CTX_WIDTH - 1] message_fmtd_3 [NUM_TV - 1 : 0];

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

    // Load KAT
    $readmemh("SigVer_pk_65.txt",         pk_3, 0, 0);
    $readmemh("SigVer_message_65.txt",    message_3, 0, 0);
    $readmemh("SigVer_mlen_65.txt",       mlen_3, 0, 0);
    $readmemh("SigVer_ctx_65.txt",        context_3, 0, 0);
    $readmemh("SigVer_ctxlen_65.txt",     ctxlen_3, 0, 0);
    $readmemh("SigVer_signature_65.txt",  sig_3, 0, 0);
    $readmemb("SigVer_result_65.txt",     verif_3);

    c = 0;

    // ---------- Build message_fmtd ----------
    // Layout: [0] (1B) || ctxlen (1B) || ctx (ctxlen B) || message (mlen B)
    message_fmtd_3[c] = 0;
    message_fmtd_3[c][0 +: 8]  = 8'd0;
    message_fmtd_3[c][8 +: 8]  = ctxlen_3[c][7:0];
    for (i = 0; i < ctxlen_3[c]; i = i + 1) begin
      message_fmtd_3[c][16 + i*8 +: 8] = context_3[c][(`CTX_BYTES - ctxlen_3[c])*8 + i*8 +: 8];
    end
    for (i = 0; i < mlen_3[c]; i = i + 1) begin
      message_fmtd_3[c][16 + ctxlen_3[c]*8 + i*8 +: 8] = message_3[c][(MAX_MLEN_3 - mlen_3[c]*8) + i*8 +: 8];
    end
    fmt_byte_len = 2 + ctxlen_3[c] + mlen_3[c];
    fmt_word_len = (fmt_byte_len + 7) / 8;
    $display("=== [Bridge Verify] KAT #%0d: mlen=%0d ctxlen=%0d, fmt_bytes=%0d fmt_words=%0d, expected_fail=%0d ===",
             c, mlen_3[c], ctxlen_3[c], fmt_byte_len, fmt_word_len, verif_3[c]);

    // ---------- Reset ----------
    rst_n = 0;
    repeat (20) @(posedge clk);
    rst_n = 1;
    repeat (5) @(posedge clk);

    start_time = $time;

    // ---------- Push FIRST input word to prime FIFO ----------
    push_input_word(pk_3[c][0*64 +: 64]);  // PK rho word 0

    // ---------- Start Verify NOW ----------
    // mode=1=Verify, sec_lvl=3, start=1: CTRL = (3<<3) | (1<<1) | 1 = 24|2|1 = 0x1B
    axi_write(64'h00, 64'h1B);
    $display("  Wrote CTRL=0x1B (mode=Verify=1, sec_lvl=3, start=1) after priming with 1 word");

    // ---------- Push remaining input words ----------
    // 1. PK rho words 1..3 (word 0 already pushed)
    for (i = 1; i < 4; i = i + 1)
      push_input_word(pk_3[c][i*64 +: 64]);

    // 2. c_tilde (6 words) from sig[0..5]
    for (i = 0; i < 6; i = i + 1)
      push_input_word(sig_3[c][i*64 +: 64]);

    // 3. z (400 words) from sig[CTILDE_WIDTH +:]
    for (i = 0; i < 400; i = i + 1)
      push_input_word(sig_3[c][`CTILDE_WIDTH_3 + i*64 +: 64]);

    // 4. PK t1 (240 words) from pk[SKPK_RHO_WIDTH +:]
    for (i = 0; i < 240; i = i + 1)
      push_input_word(pk_3[c][`SKPK_RHO_WIDTH + i*64 +: 64]);

    // 5. mlen + ctxlen combined (1 word)
    mlen_ctxlen_word = {48'd0, mlen_3[c] + ctxlen_3[c]};
    push_input_word(mlen_ctxlen_word);

    // 6. message_fmtd
    for (i = 0; i < fmt_word_len; i = i + 1)
      push_input_word(message_fmtd_3[c][i*64 +: 64]);

    // 7. h (8 words) from sig[CTILDE_WIDTH + z_WIDTH +:]
    for (i = 0; i < 8; i = i + 1)
      push_input_word(sig_3[c][`CTILDE_WIDTH_3 + `z_WIDTH_3 + i*64 +: 64]);

    total_input_words = 4 + 6 + 400 + 240 + 1 + fmt_word_len + 8;
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
    if (result_fail === verif_3[c][0]) begin
      $display("=== [Bridge Verify] RESULT: PASS (fail=%0d matches expected=%0d), cycles=%0d ===",
               result_fail, verif_3[c][0], total_cycles);
      $display("testbench done - PASS");
    end else begin
      $display("=== [Bridge Verify] RESULT: FAIL (got fail=%0d, expected=%0d), cycles=%0d ===",
               result_fail, verif_3[c][0], total_cycles);
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
