// Bridge testbench for ML-DSA end-to-end (KeyGen → Sign → Verify).
// Runs all three phases through axi_mldsa_bridge in sequence using the SAME
// accelerator + bridge instance. Uses KAT seed for KeyGen, then routes the
// accelerator's actual KeyGen output (PK + SK) into Sign, and routes Sign's
// actual signature output into Verify. Final fail bit must be 0 (valid).
//
// This validates the FULL data path through the bridge with realistic data
// (not pre-baked KAT signatures), which is what the FPGA C test code will do.
//
// Register map: see axi_mldsa_bridge.sv header comment.
// Phase CTRL values (sec_lvl=3):
//   KeyGen: mode=0 → CTRL = (3<<3) | (0<<1) | 1 = 0x19
//   Sign:   mode=2 → CTRL = (3<<3) | (2<<1) | 1 = 0x1D
//   Verify: mode=1 → CTRL = (3<<3) | (1<<1) | 1 = 0x1B

`include "mldsa_params.v"
`include "axi/typedef.svh"
`include "axi/assign.svh"

`timescale 1ns / 1ps

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

  // ----------------------------- KAT inputs (sec_lvl=3) -----------------------------
  localparam NUM_TV = 1;
  localparam MAX_MLEN_3 = 8192*8;

  // KeyGen seed
  reg [0 : 256-1]                seed_3    [NUM_TV - 1 : 0];
  // Sign: we use KAT SK only as sanity reference (optional); message from KAT
  reg [0 : MAX_MLEN_3 - 1]       message_3 [NUM_TV - 1 : 0];
  reg [31:0]                     mlen_3    [NUM_TV - 1 : 0];
  reg [0 : `CTX_WIDTH - 1]       context_3 [NUM_TV - 1 : 0];
  reg [31:0]                     ctxlen_3  [NUM_TV - 1 : 0];

  // Phase outputs (filled in by each phase, used as inputs to next phase)
  reg [0 : `PK_WIDTH_3 - 1]      pk_out;
  reg [0 : `SK_WIDTH_3 - 1]      sk_out;
  reg [0 : `SIG_WIDTH_3 - 1]     sig_out;

  // KAT reference vectors for per-phase comparison
  reg [0 : `PK_WIDTH_3 - 1]      pk_kat  [0:0];
  reg [0 : `SK_WIDTH_3 - 1]      sk_kat  [0:0];
  reg [0 : `SIG_WIDTH_3 - 1]     sig_kat [0:0];
  // SigGen KAT SK (separate from KeyGen KAT SK — different key material)
  reg [0 : `SK_WIDTH_3 - 1]      sg_sk_kat [0:0];
  integer kg_mismatches, sg_mismatches;
  integer sk_match_sg;  // 1 = KeyGen SK matches SigGen KAT SK

  // Formatted message buffer (shared by Sign and Verify)
  reg [0 : MAX_MLEN_3 + 2*8 + `CTX_WIDTH - 1] message_fmtd_3 [NUM_TV - 1 : 0];

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
    end
  endtask

  // ----------------------------- Main test sequence -----------------------------
  initial begin
    axi.aw_valid = 1'b0; axi.w_valid = 1'b0; axi.b_ready = 1'b0;
    axi.ar_valid = 1'b0; axi.r_ready = 1'b0;

    // Bounded $readmemh(addr 0..0) — documents that we only consume vector 0
    // from each 25-vector KAT file. (XSIM still emits a "Too many words"
    // warning; run.sh filters it from displayed output.)
    $readmemh("KeyGen_seed_65.txt",     seed_3, 0, 0);
    $readmemh("SigGen_message_65.txt",  message_3, 0, 0);
    $readmemh("SigGen_mlen_65.txt",     mlen_3, 0, 0);
    $readmemh("SigGen_ctx_65.txt",      context_3, 0, 0);
    $readmemh("SigGen_ctxlen_65.txt",   ctxlen_3, 0, 0);

    // KAT reference outputs for per-phase comparison
    $readmemh("KeyGen_pk_65.txt",       pk_kat, 0, 0);
    $readmemh("KeyGen_sk_65.txt",       sk_kat, 0, 0);
    $readmemh("SigGen_signature_65.txt", sig_kat, 0, 0);
    $readmemh("SigGen_sk_65.txt",       sg_sk_kat, 0, 0);

    c = 0;
    pk_out = 0;
    sk_out = 0;
    sig_out = 0;

    // ---------- Build message_fmtd ----------
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
    $display("=== [e2e] KAT #%0d: mlen=%0d ctxlen=%0d, fmt_words=%0d ===",
             c, mlen_3[c], ctxlen_3[c], fmt_word_len);

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
    for (i = 0; i < 4; i = i + 1)
      push_input_word(seed_3[c][i*64 +: 64]);

    // CTRL=0x19 = (3<<3) | (0<<1) | 1 = KeyGen, sec_lvl=3, start
    axi_write(64'h00, 64'h19);
    $display("  Wrote CTRL=0x19 (KeyGen)");

    // Drain 744 words
    wr_idx = 0;
    while (wr_idx < 744) begin
      axi_read(64'h18, status_r);
      if (status_r[2] === 1'b0) begin
        axi_read(64'h10, data_r);
        if (wr_idx < 4) begin
          pk_out[wr_idx*64 +: 64] = data_r;
          sk_out[wr_idx*64 +: 64] = data_r;
        end else if (wr_idx < 8) begin
          sk_out[`SKPK_RHO_WIDTH + (wr_idx-4)*64 +: 64] = data_r;
        end else if (wr_idx < 88) begin
          sk_out[`SKPK_RHO_WIDTH + `SK_K_WIDTH + `SK_tr_WIDTH + (wr_idx-8)*64 +: 64] = data_r;
        end else if (wr_idx < 184) begin
          sk_out[`SKPK_RHO_WIDTH + `SK_K_WIDTH + `SK_tr_WIDTH + `SK_s1_WIDTH_3 + (wr_idx-88)*64 +: 64] = data_r;
        end else if (wr_idx < 424) begin
          pk_out[`SKPK_RHO_WIDTH + (wr_idx-184)*64 +: 64] = data_r;
        end else if (wr_idx < 736) begin
          sk_out[`SKPK_RHO_WIDTH + `SK_K_WIDTH + `SK_tr_WIDTH + `SK_s1_WIDTH_3 + `SK_s2_WIDTH_3 + (wr_idx-424)*64 +: 64] = data_r;
        end else begin
          sk_out[`SKPK_RHO_WIDTH + `SK_K_WIDTH + (wr_idx-736)*64 +: 64] = data_r;
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
    for (i = 0; i < `PK_BYTES_3; i = i + 1) begin
      if (pk_out[i*8 +: 8] !== pk_kat[0][i*8 +: 8]) begin
        if (kg_mismatches < 3)
          $display("  [KG PK mismatch] byte %0d: got %h, KAT %h", i, pk_out[i*8 +: 8], pk_kat[0][i*8 +: 8]);
        kg_mismatches = kg_mismatches + 1;
      end
    end
    for (i = 0; i < `SK_BYTES_3; i = i + 1) begin
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

    // Wait for bridge to settle (input FIFO should already be empty)
    repeat (100) @(posedge clk);

    // =====================================================================
    // PHASE 2: Sign (mode=2) using sk_out + KAT message
    // =====================================================================
    $display("");
    $display("=== Phase 2: Sign ===");
    sg_start = $time;

    // fix: clear CTRL start bit before re-asserting so ctrl_start_rise fires.
    // Without this, ctrl_start stays at 1 from Phase 1's CTRL=0x19 write, so
    // the bridge's rising-edge detector never triggers the 2-phase start
    // sequence (RST_CYCLES + START_DELAY) for Phase 2. The accelerator stays
    // in IDLE and Sign hangs forever waiting for ready_i.
    axi_write(64'h00, 64'h00);
    $display("  Wrote CTRL=0x00 (clear start bit)");
    repeat (10) @(posedge clk);

    // Push SK rho word 0 to prime FIFO
    push_input_word(sk_out[0*64 +: 64]);

    // CTRL=0x1D = (3<<3) | (2<<1) | 1 = Sign, sec_lvl=3, start
    axi_write(64'h00, 64'h1D);
    $display("  Wrote CTRL=0x1D (Sign)");

    // Push SK rho words 1..3
    for (i = 1; i < 4; i = i + 1)
      push_input_word(sk_out[i*64 +: 64]);

    // mlen + ctxlen combined
    mlen_ctxlen_word = {48'd0, mlen_3[c] + ctxlen_3[c]};
    push_input_word(mlen_ctxlen_word);

    // SK tr (8 words) at sk[SKPK_RHO+SK_K+:]
    for (i = 0; i < 8; i = i + 1)
      push_input_word(sk_out[`SKPK_RHO_WIDTH + `SK_K_WIDTH + i*64 +: 64]);

    // message_fmtd
    for (i = 0; i < fmt_word_len; i = i + 1)
      push_input_word(message_fmtd_3[c][i*64 +: 64]);

    // SK K (4 words) at sk[SKPK_RHO+:]
    for (i = 0; i < 4; i = i + 1)
      push_input_word(sk_out[`SKPK_RHO_WIDTH + i*64 +: 64]);

    // rnd (4 words, zeros)
    for (i = 0; i < 4; i = i + 1)
      push_input_word(64'd0);

    // SK s1 (80 words) at sk[SKPK_RHO+SK_K+SK_tr+:]
    for (i = 0; i < 80; i = i + 1)
      push_input_word(sk_out[`SKPK_RHO_WIDTH + `SK_K_WIDTH + `SK_tr_WIDTH + i*64 +: 64]);

    // SK s2 (96 words) at sk[SKPK_RHO+SK_K+SK_tr+SK_s1+:]
    for (i = 0; i < 96; i = i + 1)
      push_input_word(sk_out[`SKPK_RHO_WIDTH + `SK_K_WIDTH + `SK_tr_WIDTH + `SK_s1_WIDTH_3 + i*64 +: 64]);

    // SK t0 (312 words) at sk[SKPK_RHO+SK_K+SK_tr+SK_s1+SK_s2+:]
    for (i = 0; i < 312; i = i + 1)
      push_input_word(sk_out[`SKPK_RHO_WIDTH + `SK_K_WIDTH + `SK_tr_WIDTH + `SK_s1_WIDTH_3 + `SK_s2_WIDTH_3 + i*64 +: 64]);

    // Drain 414 words: z(400) + h(8) + ctilde(6)
    recv_idx = 0;
    while (recv_idx < 414) begin
      axi_read(64'h18, status_r);
      if (status_r[2] === 1'b0) begin
        axi_read(64'h10, data_r);
        if (recv_idx < 400) begin
          // z: words 0..399 → sig_out[CTILDE_WIDTH + recv_idx*64 +:]
          sig_out[`CTILDE_WIDTH_3 + recv_idx*64 +: 64] = data_r;
        end else if (recv_idx < 408) begin
          // h: words 400..407 → sig_out[CTILDE_WIDTH + z_WIDTH + (recv_idx-400)*64 +:]
          sig_out[`CTILDE_WIDTH_3 + `z_WIDTH_3 + (recv_idx-400)*64 +: 64] = data_r;
        end else begin
          // ctilde: words 408..413 → sig_out[(recv_idx-408)*64 +:]
          sig_out[(recv_idx-408)*64 +: 64] = data_r;
        end
        recv_idx = recv_idx + 1;
      end else begin
        repeat (50) @(posedge clk);
      end
    end
    sg_cycles = ($time - sg_start) / 10;
    $display("  Sign complete: %0d words drained, cycles=%0d", recv_idx, sg_cycles);

    // Sign KAT comparison is only meaningful if the KeyGen-produced SK
    // matches the SigGen KAT SK. If they differ (different key material),
    // the signature will validly differ from the KAT signature.
    sk_match_sg = 1;
    for (i = 0; i < `SK_BYTES_3; i = i + 1) begin
      if (sk_out[i*8 +: 8] !== sg_sk_kat[0][i*8 +: 8]) begin
        sk_match_sg = 0;
        i = `SK_BYTES_3;  // break
      end
    end

    if (sk_match_sg) begin
      sg_mismatches = 0;
      for (i = 0; i < `SIG_BYTES_3; i = i + 1) begin
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

    // fix: clear CTRL start bit so ctrl_start_rise fires for Phase 3.
    axi_write(64'h00, 64'h00);
    $display("  Wrote CTRL=0x00 (clear start bit)");
    repeat (10) @(posedge clk);

    // Push PK rho word 0 to prime FIFO
    push_input_word(pk_out[0*64 +: 64]);

    // CTRL=0x1B = (3<<3) | (1<<1) | 1 = Verify, sec_lvl=3, start
    axi_write(64'h00, 64'h1B);
    $display("  Wrote CTRL=0x1B (Verify)");

    // PK rho words 1..3
    for (i = 1; i < 4; i = i + 1)
      push_input_word(pk_out[i*64 +: 64]);

    // c_tilde (6 words) from sig[0..5]
    for (i = 0; i < 6; i = i + 1)
      push_input_word(sig_out[i*64 +: 64]);

    // z (400 words) from sig[CTILDE_WIDTH +:]
    for (i = 0; i < 400; i = i + 1)
      push_input_word(sig_out[`CTILDE_WIDTH_3 + i*64 +: 64]);

    // PK t1 (240 words) from pk[SKPK_RHO +:]
    for (i = 0; i < 240; i = i + 1)
      push_input_word(pk_out[`SKPK_RHO_WIDTH + i*64 +: 64]);

    // mlen + ctxlen combined
    push_input_word(mlen_ctxlen_word);

    // message_fmtd
    for (i = 0; i < fmt_word_len; i = i + 1)
      push_input_word(message_fmtd_3[c][i*64 +: 64]);

    // h (8 words) from sig[CTILDE_WIDTH + z_WIDTH +:]
    for (i = 0; i < 8; i = i + 1)
      push_input_word(sig_out[`CTILDE_WIDTH_3 + `z_WIDTH_3 + i*64 +: 64]);

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
