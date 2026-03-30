// =============================================================================
// llr_input_buffer.sv — Channel LLR storage buffer
// =============================================================================
// Simple BRAM to store incoming channel LLRs.
// Write port: for loading LLRs from external interface (one at a time).
// Read port: block read for VNU access (returns Z LLRs for a column block).
//
// Storage layout: N = NB * Z values of W bits each.
// Organized as NB blocks of Z values.
// =============================================================================

module llr_input_buffer #(
    parameter int N  = 648,   // total number of variable nodes
    parameter int Z  = 27,    // lifting size
    parameter int W  = 6,     // LLR bit width
    parameter int NB = 24     // number of column blocks (N/Z)
)(
    input  logic              clk,
    input  logic              rst_n,

    // Write port — load LLRs one at a time
    input  logic [W-1:0]     wr_data,
    input  logic [$clog2(N)-1:0] wr_addr,
    input  logic              wr_en,

    // Block read port — read Z LLRs for a column block
    input  logic [4:0]        rd_col_block,   // which column block (0..NB-1)
    output logic [W*Z-1:0]   rd_data,         // Z packed LLRs
    output logic              frame_ready      // a complete frame has been loaded
);

    // Memory: N entries of W bits
    logic [W-1:0] mem [0:N-1];

    // Frame ready tracking
    logic [$clog2(N):0] wr_count;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_count    <= '0;
            frame_ready <= 1'b0;
        end else begin
            if (wr_en) begin
                mem[wr_addr] <= wr_data;
                if (wr_addr == N - 1)
                    frame_ready <= 1'b1;
            end
            // Decoder can clear frame_ready by starting to process
        end
    end

    // Block read: pack Z elements starting at rd_col_block * Z
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_data <= '0;
        end else begin
            for (int i = 0; i < Z; i++) begin
                rd_data[i*W +: W] <= mem[rd_col_block * Z + i];
            end
        end
    end

endmodule
