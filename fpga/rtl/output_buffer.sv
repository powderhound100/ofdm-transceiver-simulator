// =============================================================================
// output_buffer.sv — Decoded bits output buffer
// =============================================================================
// Stores hard-decision bits after decoding completes.
// Write port: decoder writes Z bits per column block.
// Read port: external reader can read bits sequentially or by block.
// =============================================================================

module output_buffer #(
    parameter int N  = 648,   // total number of variable nodes
    parameter int Z  = 27,    // lifting size
    parameter int NB = 24     // number of column blocks
)(
    input  logic              clk,
    input  logic              rst_n,

    // Write port from decoder
    input  logic [Z-1:0]     decoded_block,   // Z decoded bits for one column block
    input  logic [4:0]        col_addr,        // which column block
    input  logic              write_en,
    input  logic              frame_done,      // all columns written

    // Read port (simple sequential read)
    input  logic [$clog2(N)-1:0] rd_addr,
    output logic              rd_data,
    output logic              output_valid      // frame is available for reading
);

    // Storage: N bits
    logic [N-1:0] bits;

    // Write: unpack Z bits into correct positions
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bits         <= '0;
            output_valid <= 1'b0;
        end else begin
            if (write_en) begin
                for (int i = 0; i < Z; i++) begin
                    if ((col_addr * Z + i) < N)
                        bits[col_addr * Z + i] <= decoded_block[i];
                end
            end
            if (frame_done)
                output_valid <= 1'b1;
            // Reset output_valid when new frame starts
        end
    end

    // Read
    assign rd_data = bits[rd_addr];

endmodule
