// Bridge testbench for ML-DSA KeyGen.
// Drives axi_mldsa_bridge via a minimal AXI4 master BFM (single-beat transactions).
// The bridge wraps combined_top (the accelerator). Output is compared byte-for-byte
// against the NIST KAT.
//
// Register map (byte offsets, 64-bit data):
//   0x00 CTRL     [WO]  [0]=start  [2:1]=mode  [5:3]=sec_lvl
//   0x08 DATA_IN  [WO]  push 64-bit word to input FIFO
//   0x10 DATA_OUT [RO]  pop 64-bit word from output FIFO
//   0x18 STATUS   [RO]  [0]=in_empty [2]=out_empty [6]=busy
//   0x20 DIAG     [RO]  accelerator internal state

`include "mldsa_params.v"
`include "axi/typedef.svh"
`include "axi/assign.svh"

`timescale 1ns / 1ps

module tb_keygen_bridge;

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
  reg [`SEED_WIDTH - 1 : 0]   seed_3  [NUM_TV - 1 : 0];
  reg [0 : `PK_WIDTH_3 - 1]   pk_3    [NUM_TV - 1 : 0];
  reg [0 : `SK_WIDTH_3 - 1]   sk_3    [NUM_TV - 1 : 0];

  // Captured output buffers (same layout as standalone TB)
  reg [0 : `PK_WIDTH_3 - 1]   pk_out;
  reg [0 : `SK_WIDTH_3 - 1]   sk_out;

  integer c;       // KAT index
  integer i;       // byte index for compare
  integer wr_idx;  // word index for DATA_OUT reads

  // ----------------------------- AXI Master BFM tasks -----------------------------
  // Single-beat AXI4 write (len=0). Bridges to AXI-Lite via axi_to_axi_lite.
  task axi_write(input logic [63:0] addr, input logic [63:0] data);
    begin
      // AW channel
      axi.aw_id      = 5'b0;
      axi.aw_addr    = addr;
      axi.aw_len     = 8'b0;
      axi.aw_size    = 3'b011; // 8 bytes
      axi.aw_burst   = 2'b00;  // fixed
      axi.aw_lock    = 1'b0;
      axi.aw_cache   = 4'b0;
      axi.aw_prot    = 3'b0;
      axi.aw_qos     = 4'b0;
      axi.aw_region  = 4'b0;
      axi.aw_atop    = 5'b0;
      axi.aw_user    = 1'b0;
      axi.aw_valid   = 1'b1;
      // W channel
      axi.w_data     = data;
      axi.w_strb     = 8'hFF;
      axi.w_last     = 1'b1;
      axi.w_user     = 1'b0;
      axi.w_valid    = 1'b1;
      // B channel ready
      axi.b_ready    = 1'b1;

      // Wait for aw_ready and w_ready (may come in any order)
      while (!(axi.aw_ready && axi.w_ready)) begin
        @(posedge clk);
        if (axi.aw_ready) axi.aw_valid = 1'b0;
        if (axi.w_ready)  axi.w_valid  = 1'b0;
      end
      @(posedge clk);
      axi.aw_valid = 1'b0;
      axi.w_valid  = 1'b0;

      // Wait for b_valid
      while (!axi.b_valid) @(posedge clk);
      @(posedge clk);
      axi.b_ready = 1'b0;
    end
  endtask

  // Single-beat AXI4 read (len=0).
  task axi_read(input logic [63:0] addr, output logic [63:0] data);
    begin
      // AR channel
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
      // R channel ready
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

  // ----------------------------- Main test sequence -----------------------------
  logic [63:0] status_r;
  logic [63:0] data_r;
  integer start_time;
  integer total_cycles;
  integer wrong_pk_bytes, wrong_sk_bytes;

  initial begin
    // Initialize AXI signals
    axi.aw_valid = 1'b0; axi.w_valid = 1'b0; axi.b_ready = 1'b0;
    axi.ar_valid = 1'b0; axi.r_ready = 1'b0;

    // Load KAT
    $readmemh("KeyGen_seed_65.txt", seed_3, 0, 0);
    $readmemh("KeyGen_pk_65.txt",   pk_3, 0, 0);
    $readmemh("KeyGen_sk_65.txt",   sk_3, 0, 0);

    pk_out = 0;
    sk_out = 0;
    c = 0;
    wrong_pk_bytes = 0;
    wrong_sk_bytes = 0;

    // ---------- Reset ----------
    rst_n = 0;
    repeat (20) @(posedge clk);
    rst_n = 1;
    repeat (5) @(posedge clk);

    $display("=== [Bridge KeyGen] Starting KAT #%0d ===", c);
    start_time = $time;

    // ---------- Push 4 seed words via DATA_IN ----------
    // Word order: MSB-first (seed[255:192], then 191:128, 127:64, 63:0)
    // The standalone TB sends word 0 during init phase too, then 1..3 during send.
    // For the bridge, just push all 4 directly.
    axi_write(64'h08, seed_3[c][`SEED_WIDTH - 1   -: 64]);
    axi_write(64'h08, seed_3[c][`SEED_WIDTH - 65  -: 64]);
    axi_write(64'h08, seed_3[c][`SEED_WIDTH - 129 -: 64]);
    axi_write(64'h08, seed_3[c][`SEED_WIDTH - 193 -: 64]);
    $display("  Pushed 4 seed words. SEED=%h...", seed_3[c][255:0]);

    // ---------- Start KeyGen ----------
    // CTRL = (sec_lvl=3 << 3) | (mode=0 << 1) | start=1 = 0x19
    axi_write(64'h00, 64'h19);
    $display("  Wrote CTRL=0x19 (mode=KeyGen, sec_lvl=3, start=1)");

    // ---------- Drain DATA_OUT continuously until all 744 words received ----------
    // Output FIFO is only 128 deep, so we MUST drain as the accelerator produces.
    // Otherwise FIFO fills, ready_o_o drops, accelerator stalls.
    // Word order: rho(4) -> K(4) -> s1(80) -> s2(96) -> t1(240) -> t0(312) -> tr(8) = 744 total
    wr_idx = 0;
    while (wr_idx < 744) begin
      axi_read(64'h18, status_r);
      if (status_r[2] === 1'b0) begin  // !out_empty
        axi_read(64'h10, data_r);
        // Route word to appropriate buffer based on global index
        if (wr_idx < 4) begin
          // rho: words 0-3 -> pk[0+] AND sk[0+]
          pk_out[wr_idx*64 +: 64] = data_r;
          sk_out[wr_idx*64 +: 64] = data_r;
        end else if (wr_idx < 8) begin
          // K: words 4-7 -> sk[RHO+]
          sk_out[`SKPK_RHO_WIDTH + (wr_idx-4)*64 +: 64] = data_r;
        end else if (wr_idx < 88) begin
          // s1: words 8-87 -> sk[RHO+K+tr+]
          sk_out[`SKPK_RHO_WIDTH + `SK_K_WIDTH + `SK_tr_WIDTH + (wr_idx-8)*64 +: 64] = data_r;
        end else if (wr_idx < 184) begin
          // s2: words 88-183 -> sk[RHO+K+tr+s1+]
          sk_out[`SKPK_RHO_WIDTH + `SK_K_WIDTH + `SK_tr_WIDTH + `SK_s1_WIDTH_3 + (wr_idx-88)*64 +: 64] = data_r;
        end else if (wr_idx < 424) begin
          // t1: words 184-423 -> pk[RHO+]
          pk_out[`SKPK_RHO_WIDTH + (wr_idx-184)*64 +: 64] = data_r;
        end else if (wr_idx < 736) begin
          // t0: words 424-735 -> sk[RHO+K+tr+s1+s2+]
          sk_out[`SKPK_RHO_WIDTH + `SK_K_WIDTH + `SK_tr_WIDTH + `SK_s1_WIDTH_3 + `SK_s2_WIDTH_3 + (wr_idx-424)*64 +: 64] = data_r;
        end else begin
          // tr: words 736-743 -> sk[RHO+K+]  (tr is sent LAST by accelerator)
          sk_out[`SKPK_RHO_WIDTH + `SK_K_WIDTH + (wr_idx-736)*64 +: 64] = data_r;
        end
        wr_idx = wr_idx + 1;
        if (wr_idx % 100 == 0) $display("  Drain progress: %0d/744 words", wr_idx);
      end else begin
        // FIFO empty: wait a bit for accelerator to produce more
        repeat (20) @(posedge clk);
      end
    end
    total_cycles = ($time - start_time) / 10;
    $display("  Drain complete: %0d words, STATUS=%b, cycles=%0d", wr_idx, status_r[6:0], total_cycles);

    // ---------- Compare PK ----------
    for (i = 0; i < `PK_BYTES_3; i = i + 1) begin
      if (pk_out[i*8 +: 8] !== pk_3[c][i*8 +: 8]) begin
        wrong_pk_bytes = wrong_pk_bytes + 1;
        if (wrong_pk_bytes <= 10) begin
          $display("[Bridge KeyGen KAT#%0d, byte pk{%0d}] WRONG: Expected %h, received %h",
                   c, i+1, pk_3[c][i*8 +: 8], pk_out[i*8 +: 8]);
        end
      end
    end

    // ---------- Compare SK ----------
    for (i = 0; i < `SK_BYTES_3; i = i + 1) begin
      if (sk_out[i*8 +: 8] !== sk_3[c][i*8 +: 8]) begin
        wrong_sk_bytes = wrong_sk_bytes + 1;
        if (wrong_sk_bytes <= 10) begin
          $display("[Bridge KeyGen KAT#%0d, byte sk{%0d}] WRONG: Expected %h, received %h",
                   c, i+1, sk_3[c][i*8 +: 8], sk_out[i*8 +: 8]);
        end
      end
    end

    $display("");
    $display("=== [Bridge KeyGen] RESULT: PK wrong=%0d / %0d, SK wrong=%0d / %0d, cycles=%0d ===",
             wrong_pk_bytes, `PK_BYTES_3, wrong_sk_bytes, `SK_BYTES_3, total_cycles);

    if (wrong_pk_bytes == 0 && wrong_sk_bytes == 0) begin
      $display("testbench done - PASS");
    end else begin
      $display("testbench done - FAIL");
    end

    $finish;
  end

  // ----------------------------- Watchdog -----------------------------
  initial begin
    #200_000_000; // 200ms = 20M cycles at 10ns
    $display("FAIL: watchdog timeout — bridge sim hung");
    $finish;
  end

endmodule
