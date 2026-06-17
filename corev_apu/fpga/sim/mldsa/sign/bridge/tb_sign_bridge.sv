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
// Sign input word sequence (sec_lvl=3, K=6, L=5):
//   1. SK rho       : 4 words   (32B)
//   2. mlen+ctxlen  : 1 word
//   3. SK tr        : 8 words   (64B)
//   4. message_fmtd : ceil((2 + ctxlen + mlen) / 8) words
//   5. SK K         : 4 words   (32B)
//   6. rnd          : 4 words   (32B, zeros)
//   7. SK s1        : 80 words  (640B)
//   8. SK s2        : 96 words  (768B)
//   9. SK t0        : 312 words (2496B)
//
// Sign output word sequence (in receive order):
//   1. z    : 400 words (3200B) — written to sig_out[CTILDE_WIDTH +:]
//   2. h    : 8 words   (61B, last padded) — written to sig_out[CTILDE_WIDTH + z_WIDTH +:]
//   3. ctilde : 6 words (48B) — written to sig_out[0 +:]

`include "mldsa_params.v"
`include "axi/typedef.svh"
`include "axi/assign.svh"

`timescale 1ns / 1ps

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

  // ----------------------------- KAT storage (sec_lvl=3 only) -----------------------------
  localparam NUM_TV = 1;
  localparam MAX_MLEN_3 = 8192*8;

  // Raw KAT inputs
  reg [0 : `SK_WIDTH_3 - 1]      sk_3      [NUM_TV - 1 : 0];
  reg [0 : MAX_MLEN_3 - 1]       message_3 [NUM_TV - 1 : 0];
  reg [31:0]                     mlen_3    [NUM_TV - 1 : 0];
  reg [0 : `CTX_WIDTH - 1]       context_3 [NUM_TV - 1 : 0];
  reg [31:0]                     ctxlen_3  [NUM_TV - 1 : 0];
  // Expected output
  reg [0 : `SIG_WIDTH_3 - 1]     sig_3     [NUM_TV - 1 : 0];

  // Formatted message buffer: [0] || ctxlen || ctx || msg
  reg [0 : MAX_MLEN_3 + 2*8 + `CTX_WIDTH - 1] message_fmtd_3 [NUM_TV - 1 : 0];

  // Captured signature output
  reg [0 : `SIG_WIDTH_3 - 1]     sig_out;

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

    // Load KAT
    $readmemh("SigGen_sk_65.txt",         sk_3, 0, 0);
    $readmemh("SigGen_message_65.txt",    message_3, 0, 0);
    $readmemh("SigGen_mlen_65.txt",       mlen_3, 0, 0);
    $readmemh("SigGen_ctx_65.txt",        context_3, 0, 0);
    $readmemh("SigGen_ctxlen_65.txt",     ctxlen_3, 0, 0);
    $readmemh("SigGen_signature_65.txt",  sig_3, 0, 0);

    sig_out = 0;
    c = 0;
    wrong_sig_bytes = 0;
    recv_idx = 0;

    // ---------- Build message_fmtd ----------
    // Layout: [0] (1B) || ctxlen (1B) || ctx (ctxlen B) || message (mlen B)
    message_fmtd_3[c] = 0;
    message_fmtd_3[c][0 +: 8]  = 8'd0;
    message_fmtd_3[c][8 +: 8]  = ctxlen_3[c][7:0];
    for (i = 0; i < ctxlen_3[c]; i = i + 1) begin
      message_fmtd_3[c][16 + i*8 +: 8] = context_3[c][(255-ctxlen_3[c])*8 + i*8 +: 8];
    end
    for (i = 0; i < mlen_3[c]; i = i + 1) begin
      message_fmtd_3[c][16 + ctxlen_3[c]*8 + i*8 +: 8] = message_3[c][(MAX_MLEN_3 - mlen_3[c]*8) + i*8 +: 8];
    end
    fmt_byte_len = 2 + ctxlen_3[c] + mlen_3[c];
    fmt_word_len = (fmt_byte_len + 7) / 8;
    $display("=== [Bridge Sign] KAT #%0d: mlen=%0d ctxlen=%0d, fmt_bytes=%0d fmt_words=%0d ===",
             c, mlen_3[c], ctxlen_3[c], fmt_byte_len, fmt_word_len);

    // ---------- Reset ----------
    rst_n = 0;
    repeat (20) @(posedge clk);
    rst_n = 1;
    repeat (5) @(posedge clk);

    start_time = $time;

    // ---------- Push FIRST input word to prime FIFO (bridge requires in_count != 0 at CTRL write) ----------
    push_input_word(sk_3[c][0*64 +: 64]);  // SK rho word 0

    // ---------- Start Sign NOW so accelerator drains FIFO as we fill it ----------
    // fix: was 0x1B (mode=1=Verify). Sign requires mode=2 in combined_top's
    // case({mode,cstate0}) — {2'd2,FSM0_*}. mode=2 << 1 = 0x4, so CTRL =
    // (sec_lvl=3 << 3) | (mode=2 << 1) | start=1 = 24|4|1 = 29 = 0x1D.
    // With mode=1 the FSM was running VY_* (Verify) states which share state
    // encodings with FSM0_* — probe showed cstate0=5 (VY_NTT_T1, not NTT_S2).
    axi_write(64'h00, 64'h1D);
    $display("  Wrote CTRL=0x1D (mode=Sign=2, sec_lvl=3, start=1) after priming with 1 word");

    // ---------- Push remaining input words ----------
    // 1. SK rho words 1..3 (word 0 already pushed)
    for (i = 1; i < 4; i = i + 1)
      push_input_word(sk_3[c][i*64 +: 64]);

    // 2. mlen + ctxlen combined (1 word)
    mlen_ctxlen_word = {48'd0, mlen_3[c] + ctxlen_3[c]};
    push_input_word(mlen_ctxlen_word);

    // 3. SK tr (8 words)
    for (i = 0; i < 8; i = i + 1)
      push_input_word(sk_3[c][`SKPK_RHO_WIDTH + `SK_K_WIDTH + i*64 +: 64]);

    // 4. message_fmtd
    for (i = 0; i < fmt_word_len; i = i + 1)
      push_input_word(message_fmtd_3[c][i*64 +: 64]);

    // 5. SK K (4 words)
    for (i = 0; i < 4; i = i + 1)
      push_input_word(sk_3[c][`SKPK_RHO_WIDTH + i*64 +: 64]);

    // 6. rnd (4 words, all zeros)
    for (i = 0; i < 4; i = i + 1)
      push_input_word(64'd0);

    // 7. SK s1 (80 words)
    for (i = 0; i < 80; i = i + 1)
      push_input_word(sk_3[c][`SKPK_RHO_WIDTH + `SK_K_WIDTH + `SK_tr_WIDTH + i*64 +: 64]);

    // 8. SK s2 (96 words)
    for (i = 0; i < 96; i = i + 1)
      push_input_word(sk_3[c][`SKPK_RHO_WIDTH + `SK_K_WIDTH + `SK_tr_WIDTH + `SK_s1_WIDTH_3 + i*64 +: 64]);

    // 9. SK t0 (312 words)
    for (i = 0; i < 312; i = i + 1)
      push_input_word(sk_3[c][`SKPK_RHO_WIDTH + `SK_K_WIDTH + `SK_tr_WIDTH + `SK_s1_WIDTH_3 + `SK_s2_WIDTH_3 + i*64 +: 64]);

    total_input_words = 4 + 1 + 8 + fmt_word_len + 4 + 4 + 80 + 96 + 312;
    $display("  Pushed %0d input words total. Draining output...", total_input_words);

    // ---------- Drain DATA_OUT continuously ----------
    // Output order: z(400 words) → h(8 words) → ctilde(6 words) = 414 total
    total_output_words = 400 + 8 + 6;
    recv_idx = 0;
    while (recv_idx < total_output_words) begin
      axi_read(64'h18, status_r);
      if (status_r[2] === 1'b0) begin  // !out_empty
        axi_read(64'h10, data_r);
        // Route based on word index
        if (recv_idx < 400) begin
          // z: words 0..399 → sig_out[CTILDE_WIDTH + recv_idx*64 +:]
          sig_out[`CTILDE_WIDTH_3 + recv_idx*64 +: 64] = data_r;
        end else if (recv_idx < 408) begin
          // h: words 400..407 → sig_out[CTILDE_WIDTH + z_WIDTH + (recv_idx-400)*64 +:]
          sig_out[`CTILDE_WIDTH_3 + `z_WIDTH_3 + (recv_idx-400)*64 +: 64] = data_r;
        end else begin
          // ctilde: words 408..413 → sig_out[0 + (recv_idx-408)*64 +:]
          sig_out[(recv_idx-408)*64 +: 64] = data_r;
        end
        recv_idx = recv_idx + 1;
      end else begin
        repeat (50) @(posedge clk);
      end
    end
    total_cycles = ($time - start_time) / 10;
    $display("  Drain complete: %0d words, cycles=%0d", recv_idx, total_cycles);

    // ---------- Compare SIG ----------
    // Track first/last wrong byte and per-region counts for diagnostics.
    first_wrong = -1; last_wrong = -1;
    wrong_ctilde = 0; wrong_z = 0; wrong_h = 0;
    for (i = 0; i < `SIG_BYTES_3; i = i + 1) begin
      if (sig_out[i*8 +: 8] !== sig_3[c][i*8 +: 8]) begin
        wrong_sig_bytes = wrong_sig_bytes + 1;
        if (first_wrong < 0) first_wrong = i;
        last_wrong = i;
        if      (i < 48)              wrong_ctilde = wrong_ctilde + 1;
        else if (i < 48 + 3200)       wrong_z      = wrong_z + 1;
        else                          wrong_h      = wrong_h + 1;
        if (wrong_sig_bytes <= 10) begin
          $display("[Bridge Sign KAT#%0d, byte sig{%0d}] WRONG: Expected %h, received %h",
                   c, i+1, sig_3[c][i*8 +: 8], sig_out[i*8 +: 8]);
        end
      end
    end
    $display("  WRONG byte range: [%0d .. %0d] (count=%0d)", first_wrong, last_wrong, wrong_sig_bytes);
    $display("  Per-region: ctilde=%0d/48  z=%0d/3200  h=%0d/61",
             wrong_ctilde, wrong_z, wrong_h);
    // Dump expected AND received words 168..260 (z) and 400..413 (h + ctilde) for byte-level comparison
    $display("  --- Expected (from KAT sig_3) ---");
    for (i = 168; i <= 260; i = i + 1) begin
      $display("  EXP word[%0d] = %h", i, sig_3[c][`CTILDE_WIDTH_3 + i*64 +: 64]);
    end
    $display("  --- Received (from bridge) ---");
    for (i = 168; i <= 260; i = i + 1) begin
      $display("  RECV word[%0d] = %h", i, sig_out[`CTILDE_WIDTH_3 + i*64 +: 64]);
    end
    $display("  --- Expected h+ctilde words 400..413 ---");
    for (i = 400; i <= 413; i = i + 1) begin
      $display("  EXP word[%0d] = %h", i, sig_3[c][`CTILDE_WIDTH_3 + i*64 +: 64]);
    end
    $display("  --- Received h+ctilde words 400..413 ---");
    for (i = 400; i <= 413; i = i + 1) begin
      $display("  RECV word[%0d] = %h", i, sig_out[`CTILDE_WIDTH_3 + i*64 +: 64]);
    end

    $display("");
    $display("=== [Bridge Sign] RESULT: SIG wrong=%0d / %0d, cycles=%0d ===",
             wrong_sig_bytes, `SIG_BYTES_3, total_cycles);

    if (wrong_sig_bytes == 0) begin
      $display("testbench done - PASS");
    end else begin
      $display("testbench done - FAIL");
    end

    $finish;
  end

  // fix: PROBE debug removed after T0 stall fix verified.
  // Watchdog retained to catch any future regressions.

  // ----------------------------- Watchdog -----------------------------
  initial begin
    #500_000_000; // 500ms — long enough for Sign with bridge overhead
    $display("FAIL: watchdog timeout — bridge Sign sim hung");
    $finish;
  end

endmodule
