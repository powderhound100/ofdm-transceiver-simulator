// =============================================================================
// data_align_buffer.sv — Synchronous FIFO for Data Path Alignment
// =============================================================================
// 64-deep FIFO to hold data subcarriers while the channel estimator computes
// channel estimates. AXI-Stream in/out with backpressure support.
//
// Standard synchronous FIFO using read/write pointers with full/empty flags.
// Stores both data and tlast sideband.
// =============================================================================
`timescale 1ns / 1ps

module data_align_buffer #(
    parameter integer WIDTH = 32,
    parameter integer DEPTH = 64
)(
    input  wire              clk,
    input  wire              rst_n,

    // AXI-Stream slave
    input  wire [WIDTH-1:0]  s_tdata,
    input  wire              s_tvalid,
    output wire              s_tready,
    input  wire              s_tlast,

    // AXI-Stream master
    output wire [WIDTH-1:0]  m_tdata,
    output wire              m_tvalid,
    input  wire              m_tready,
    output wire              m_tlast
);

    // =========================================================================
    // Pointer width: need one extra bit for full/empty disambiguation
    // =========================================================================
    localparam integer PTR_W = $clog2(DEPTH) + 1;  // 7 for DEPTH=64
    localparam integer ADDR_W = $clog2(DEPTH);      // 6 for DEPTH=64

    // =========================================================================
    // Memory: data + tlast sideband
    // =========================================================================
    reg [WIDTH:0] mem [0:DEPTH-1];  // WIDTH bits data + 1 bit tlast

    // =========================================================================
    // Read/write pointers
    // =========================================================================
    reg [PTR_W-1:0] wr_ptr;
    reg [PTR_W-1:0] rd_ptr;

    wire [ADDR_W-1:0] wr_addr = wr_ptr[ADDR_W-1:0];
    wire [ADDR_W-1:0] rd_addr = rd_ptr[ADDR_W-1:0];

    // =========================================================================
    // Full/empty logic
    // =========================================================================
    wire ptr_match = (wr_ptr[ADDR_W-1:0] == rd_ptr[ADDR_W-1:0]);
    wire msb_diff  = (wr_ptr[PTR_W-1] != rd_ptr[PTR_W-1]);

    wire full  = ptr_match && msb_diff;
    wire empty = ptr_match && !msb_diff;

    // =========================================================================
    // AXI-Stream handshake
    // =========================================================================
    wire wr_en = s_tvalid && !full;
    wire rd_en = m_tready && !empty;

    assign s_tready = !full;
    assign m_tvalid = !empty;

    // =========================================================================
    // Read data from head of FIFO
    // =========================================================================
    wire [WIDTH:0] rd_word = mem[rd_addr];
    assign m_tdata = rd_word[WIDTH-1:0];
    assign m_tlast = rd_word[WIDTH];

    // =========================================================================
    // Write/read logic
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= {PTR_W{1'b0}};
            rd_ptr <= {PTR_W{1'b0}};
        end else begin
            if (wr_en) begin
                mem[wr_addr] <= {s_tlast, s_tdata};
                wr_ptr <= wr_ptr + 1;
            end

            if (rd_en) begin
                rd_ptr <= rd_ptr + 1;
            end
        end
    end

endmodule
