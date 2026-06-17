// AXI slave bridge to ML-DSA handshake accelerator.
// Uses pulp-platform axi_to_axi_lite + axi_lite_regs for proven protocol handling,
// then converts register reads/writes into the accelerator's valid/ready streaming interface.
//
// Register map (64-bit AXI data width, byte offsets):
//   0x00  CTRL     [WO]  [0]=start  [2:1]=mode  [5:3]=sec_lvl
//   0x08  DATA_IN  [WO]  [63:0]=data word pushed to accelerator input FIFO
//   0x10  DATA_OUT [RO]  [63:0]=data word read from accelerator output FIFO
//   0x18  STATUS   [RO]  [0]=in_empty [1]=in_full [2]=out_empty [3]=out_full
//                               [4]=accel_ready_i [5]=accel_valid_o [6]=busy
//                               bytes 26-27: push_cnt  bytes 28-29: pop_cnt
//   0x20  DIAG     [RO]  Accelerator internal state (see bit field comments below)

`include "axi/typedef.svh"
`include "axi/assign.svh"

module axi_mldsa_bridge #(
    parameter int unsigned AxiAddrWidth = 64,
    parameter int unsigned AxiDataWidth = 64,
    parameter int unsigned AxiIdWidth   = 5,
    parameter int unsigned AxiUserWidth = 1
) (
    input  logic                          clk_i,
    input  logic                          rst_ni,
    // Full AXI4 slave port (connects to crossbar master via AXI_BUS)
    AXI_BUS.Slave                         axi,
    // Accelerator handshake interface
    output logic                          rst_o,
    output logic                          start_o,
    output logic [1:0]                    mode_o,
    output logic [2:0]                    sec_lvl_o,
    output logic                          valid_i_o,
    output logic [AxiDataWidth-1:0]       data_i_o,
    input  logic                          ready_i_i,
    input  logic                          valid_o_i,
    output logic                          ready_o_o,
    input  logic [AxiDataWidth-1:0]       data_o_i,
    // Diagnostic input from accelerator internal state
    input  logic [62:0]                   diag_i
);

    // -----------------------------------------------------------------------
    // Type definitions for full AXI and AXI-Lite
    // -----------------------------------------------------------------------
    typedef logic [AxiAddrWidth-1:0]           addr_t;
    typedef logic [AxiDataWidth-1:0]           data_t;
    typedef logic [AxiDataWidth/8-1:0]         strb_t;
    typedef logic [AxiIdWidth-1:0]             id_t;
    typedef logic [AxiUserWidth-1:0]           user_t;

    `AXI_TYPEDEF_ALL(axi_full,
                     addr_t, id_t, data_t, strb_t, user_t)

    `AXI_LITE_TYPEDEF_ALL(axi_lite, addr_t, data_t, strb_t)

    // -----------------------------------------------------------------------
    // Full AXI struct wires (convert from AXI_BUS interface)
    // -----------------------------------------------------------------------
    axi_full_req_t  axi_req;
    axi_full_resp_t axi_resp;

    `AXI_ASSIGN_TO_REQ(axi_req, axi)
    `AXI_ASSIGN_FROM_RESP(axi, axi_resp)

    // -----------------------------------------------------------------------
    // AXI4 to AXI4-Lite converter
    // -----------------------------------------------------------------------
    axi_lite_req_t  lite_req;
    axi_lite_resp_t lite_resp;

    axi_to_axi_lite #(
        .AxiAddrWidth    ( AxiAddrWidth    ),
        .AxiDataWidth    ( AxiDataWidth    ),
        .AxiIdWidth      ( AxiIdWidth      ),
        .AxiUserWidth    ( AxiUserWidth    ),
        .AxiMaxWriteTxns ( 1               ),
        .AxiMaxReadTxns  ( 1               ),
        .FallThrough     ( 1'b1            ),
        .full_req_t      ( axi_full_req_t  ),
        .full_resp_t     ( axi_full_resp_t ),
        .lite_req_t      ( axi_lite_req_t  ),
        .lite_resp_t     ( axi_lite_resp_t )
    ) i_axi_to_axi_lite (
        .clk_i      ( clk_i     ),
        .rst_ni     ( rst_ni    ),
        .test_i     ( 1'b0      ),
        .slv_req_i  ( axi_req   ),
        .slv_resp_o ( axi_resp  ),
        .mst_req_o  ( lite_req  ),
        .mst_resp_i ( lite_resp )
    );

    // -----------------------------------------------------------------------
    // Register map constants
    // -----------------------------------------------------------------------
    localparam int unsigned RegNumBytes = 40; // 5 x 64-bit = CTRL + DATA_IN + DATA_OUT + STATUS + DIAG
    typedef logic [7:0] byte_t;

    // Bytes 16-39 (DATA_OUT + STATUS + DIAG) are read-only from AXI side
    localparam logic [RegNumBytes-1:0] AxiReadOnly = 40'hFFFFFF0000;

    // All registers reset to 0
    localparam byte_t [RegNumBytes-1:0] RegRstVal = {RegNumBytes{8'h00}};

    // -----------------------------------------------------------------------
    // AXI-Lite register bank
    // -----------------------------------------------------------------------
    logic [RegNumBytes-1:0] wr_active;
    logic [RegNumBytes-1:0] rd_active;
    byte_t [RegNumBytes-1:0] reg_d;
    logic  [RegNumBytes-1:0] reg_load;
    byte_t [RegNumBytes-1:0] reg_q;

    axi_lite_regs #(
        .RegNumBytes  ( RegNumBytes  ),
        .AxiAddrWidth ( AxiAddrWidth ),
        .AxiDataWidth ( AxiDataWidth ),
        .AxiReadOnly  ( AxiReadOnly  ),
        .byte_t       ( byte_t       ),
        .RegRstVal    ( RegRstVal    ),
        .req_lite_t   ( axi_lite_req_t  ),
        .resp_lite_t  ( axi_lite_resp_t )
    ) i_axi_lite_regs (
        .clk_i       ( clk_i      ),
        .rst_ni      ( rst_ni     ),
        .axi_req_i   ( lite_req   ),
        .axi_resp_o  ( lite_resp  ),
        .wr_active_o ( wr_active  ),
        .rd_active_o ( rd_active  ),
        .reg_d_i     ( reg_d      ),
        .reg_load_i  ( reg_load   ),
        .reg_q_o     ( reg_q      )
    );

    // -----------------------------------------------------------------------
    // Extract register fields from axi_lite_regs output (packed byte array)
    // -----------------------------------------------------------------------
    // CTRL at bytes [7:0]
    logic        ctrl_start;
    logic [1:0]  ctrl_mode;
    logic [2:0]  ctrl_sec_lvl;

    assign ctrl_start   = reg_q[0][0];     // bit 0 of byte 0 = value bit 0
    assign ctrl_mode    = reg_q[0][2:1];   // bits 2:1 of byte 0 = value bits 2:1
    assign ctrl_sec_lvl = reg_q[0][5:3];   // bits 5:3 of byte 0 = value bits 5:3

    // DATA_IN at bytes [15:8]
    data_t data_in_reg;
    assign data_in_reg = {reg_q[15], reg_q[14], reg_q[13], reg_q[12],
                          reg_q[11], reg_q[10], reg_q[9],  reg_q[8]};

    // -----------------------------------------------------------------------
    // Register-based FIFO parameters
    // -----------------------------------------------------------------------
    // fix: increased from 128 to 1024 so the bridge input FIFO can hold
    // the entire Sign input (~515 words) without draining mid-stream. With
    // depth 128, the FIFO emptied during T0 decode (312 words consumed faster
    // than TB refilled), causing decoder valid_i=0 -> shift-without-load ->
    // corrupted t0 coefficients -> wrong h region in signature. Depth 1024
    // holds the full input and valid_i stays 1 throughout decode.
    localparam int unsigned FIFO_DEPTH  = 1024;
    localparam int unsigned FIFO_ADDR_W = $clog2(FIFO_DEPTH);

    // -----------------------------------------------------------------------
    // Input FIFO (DATA_IN writes → accelerator) — register-based
    // Combinational read: zero latency, no speculative read needed.
    // -----------------------------------------------------------------------
    logic [FIFO_ADDR_W-1:0]  in_head;
    logic [FIFO_ADDR_W:0]    in_count;
    logic [FIFO_ADDR_W-1:0]  in_tail;
    logic                    in_push;
    logic                    in_pop;

    // Register storage for input FIFO
    data_t in_fifo [0:FIFO_DEPTH-1];

    // Detect DATA_IN write (one cycle delayed from wr_active)
    logic data_in_wr_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            data_in_wr_q <= 1'b0;
        end else begin
            data_in_wr_q <= (|wr_active[15:8]);
        end
    end

    assign in_push = data_in_wr_q && !in_count[FIFO_ADDR_W];

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            in_head   <= '0;
            in_tail   <= '0;
            in_count  <= '0;
        end else begin
            if (in_push) begin
                in_fifo[in_tail] <= data_in_reg;
                in_tail <= in_tail + 1;
            end
            if (in_pop) begin
                in_head <= in_head + 1;
            end
            case ({in_push, in_pop})
                2'b10:   in_count <= in_count + 1'b1;
                2'b01:   in_count <= in_count - 1'b1;
                default: in_count <= in_count;
            endcase
        end
    end

    // -----------------------------------------------------------------------
    // Output FIFO (accelerator → DATA_OUT reads) — register-based
    // Combinational read: zero latency.
    // -----------------------------------------------------------------------
    logic [FIFO_ADDR_W-1:0]  out_head;
    logic [FIFO_ADDR_W:0]    out_count;
    logic [FIFO_ADDR_W-1:0]  out_tail;
    logic                    out_push;
    logic                    out_pop;

    // Register storage for output FIFO
    data_t out_fifo [0:FIFO_DEPTH-1];

    assign out_push = valid_o_i && !out_count[FIFO_ADDR_W];
    assign out_pop  = (|rd_active[23:16]) && (out_count != 0);

    // fix: debug instrumentation (PUSH/POP) removed after FIFO depth + T0 stall fix verified.

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            out_head     <= '0;
            out_tail     <= '0;
            out_count    <= '0;
        end else begin
            if (out_push) begin
                out_fifo[out_tail] <= data_o_i;
                out_tail     <= out_tail + 1;
            end
            if (out_pop) begin
                out_head    <= out_head + 1;
            end
            case ({out_push, out_pop})
                2'b10:   out_count <= out_count + 1'b1;
                2'b01:   out_count <= out_count - 1'b1;
                default: out_count <= out_count;
            endcase
        end
    end

    // -----------------------------------------------------------------------
    // Drive DATA_OUT register (bytes 16-23) from output FIFO
    // -----------------------------------------------------------------------
    data_t out_data;
    assign out_data = (out_count != 0) ? out_fifo[out_head] : '0;

    // Pack out_data into bytes 16-23 for axi_lite_regs reg_d_i
    always_comb begin
        reg_d   = reg_q; // default: hold current value
        reg_load = '0;

        // DATA_OUT (bytes 16-23): always reflect output FIFO head
        for (int unsigned i = 0; i < 8; i++) begin
            reg_d[16+i] = out_data[i*8 +: 8];
        end
        reg_load[23:16] = 8'hFF;

        // STATUS (bytes 24-25)
        reg_d[24] = {2'b0,
                     rst_active || delay_active || start_q || (in_count != 0) || (out_count != 0),  // [6] busy
                     valid_o_i,                      // [5] accel has output
                     ready_i_i,                      // [4] accel ready for input
                     out_count[FIFO_ADDR_W],         // [3] out_full
                     (out_count == 0),               // [2] out_empty
                     in_count[FIFO_ADDR_W],          // [1] in_full
                     (in_count == 0)                  // [0] in_empty
                    };
        // Sticky diagnostics in byte 25
        reg_d[25] = {3'b0,
                     sticky_valid_o,   // [12] accel valid_o ever went high
                     sticky_in_pop,    // [11] input data ever consumed
                     sticky_ready_i,   // [10] accel ready_i ever went high
                     start_q           // [8]  start pulse active (live)
                    };
        reg_load[25:24] = 2'h3;

        // DIAG (bytes 32-39): accelerator internal state from diag_i[62:0]
        for (int unsigned i = 0; i < 7; i++) begin
            reg_d[32+i] = diag_i[i*8 +: 8];
        end
        reg_d[39] = {1'b0, diag_i[62:56]};
        reg_load[39:32] = 8'hFF;
    end

    // -----------------------------------------------------------------------
    // Accelerator handshake signals
    // -----------------------------------------------------------------------
    // Two-phase start: rst holds the accelerator in reset, then a delay
    // period gives internal state time to settle before start fires.
    // valid_i is gated during the entire sequence to prevent data races.
    // -----------------------------------------------------------------------
    localparam int unsigned RST_CYCLES   = 64;
    localparam int unsigned START_DELAY  = 16;

    logic ctrl_start_d;
    logic ctrl_start_rise;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            ctrl_start_d <= 1'b0;
        end else begin
            ctrl_start_d <= ctrl_start;
        end
    end

    assign ctrl_start_rise = ctrl_start && !ctrl_start_d;

    logic [$clog2(RST_CYCLES+1)-1:0]  rst_cnt;
    logic [$clog2(START_DELAY+1)-1:0]  delay_cnt;
    logic rst_active;
    logic delay_active;
    logic start_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            rst_cnt      <= '0;
            delay_cnt    <= '0;
            rst_active   <= 1'b0;
            delay_active <= 1'b0;
            start_q      <= 1'b0;
        end else begin
            if (ctrl_start_rise && (in_count != 0)) begin
                rst_active   <= 1'b1;
                rst_cnt      <= RST_CYCLES;
                delay_active <= 1'b0;
                start_q      <= 1'b0;
            end else if (rst_active) begin
                if (rst_cnt > 0) begin
                    rst_cnt <= rst_cnt - 1;
                end else begin
                    rst_active   <= 1'b0;
                    delay_active <= 1'b1;
                    delay_cnt    <= START_DELAY;
                end
            end else if (delay_active) begin
                if (delay_cnt > 0) begin
                    delay_cnt <= delay_cnt - 1;
                end else begin
                    delay_active <= 1'b0;
                    start_q      <= 1'b1;
                end
            end else begin
                start_q <= 1'b0;
            end
        end
    end

    assign rst_o = rst_active;

    assign start_o   = start_q;
    assign mode_o    = ctrl_mode;
    assign sec_lvl_o = ctrl_sec_lvl;

    // Gate valid_i during reset and start delay to prevent data races
    assign valid_i_o = (in_count != 0) && !rst_active && !delay_active;
    assign data_i_o  = in_fifo[in_head];
    assign in_pop    = valid_i_o && ready_i_i;

    // Always ready to accept accelerator output unless output FIFO full
    assign ready_o_o = !out_count[FIFO_ADDR_W];

    // -----------------------------------------------------------------------
    // Sticky diagnostic latches (cleared on start rising edge)
    // -----------------------------------------------------------------------
    logic sticky_ready_i;
    logic sticky_in_pop;
    logic sticky_valid_o;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            sticky_ready_i <= 1'b0;
            sticky_in_pop  <= 1'b0;
            sticky_valid_o <= 1'b0;
        end else begin
            if (ctrl_start_rise) begin
                sticky_ready_i <= 1'b0;
                sticky_in_pop  <= 1'b0;
                sticky_valid_o <= 1'b0;
            end else begin
                if (ready_i_i)    sticky_ready_i <= 1'b1;
                if (in_pop)       sticky_in_pop  <= 1'b1;
                if (valid_o_i)    sticky_valid_o <= 1'b1;
            end
        end
    end

    // fix: debug instrumentation (BRG transition log) removed after FIFO depth + T0 stall fix verified.

endmodule
