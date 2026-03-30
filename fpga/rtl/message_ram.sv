// =============================================================================
// message_ram.sv — Dual-port BRAM for CNU state storage
// =============================================================================
// True dual-port RAM:
//   Port A: read-only (for CNU read-back during c2v output phase)
//   Port B: write-only (for CNU state update during accumulation)
//
// Data word packing (default 36 bits):
//   [35]     sign_product (1 bit)
//   [34:30]  argmin1      (5 bits)
//   [29:25]  min2_val     (5 bits)
//   [24:20]  min1_val     (5 bits)
//   [19:0]   signs        (20 bits, one per edge position)
//
// Inferred as block RAM by synthesis tools.
// =============================================================================

module message_ram #(
    parameter int DEPTH  = 324,   // number of entries (mb * Z for check node state)
    parameter int DATA_W = 36     // data width
)(
    input  logic                        clk,

    // Port A — read
    input  logic [$clog2(DEPTH)-1:0]    addr_a,
    output logic [DATA_W-1:0]           rdata_a,

    // Port B — write
    input  logic [$clog2(DEPTH)-1:0]    addr_b,
    input  logic [DATA_W-1:0]           wdata_b,
    input  logic                        wen_b
);

    // Memory array
    logic [DATA_W-1:0] mem [0:DEPTH-1];

    // Port A: synchronous read
    always_ff @(posedge clk) begin
        rdata_a <= mem[addr_a];
    end

    // Port B: synchronous write
    always_ff @(posedge clk) begin
        if (wen_b)
            mem[addr_b] <= wdata_b;
    end

endmodule
