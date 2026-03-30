// =============================================================================
// barrel_shifter.sv — Cyclic barrel shifter for LDPC decoder
// =============================================================================
// Cyclically shifts Z elements of W bits each by shift_val positions.
//   data_out[i] = data_in[(i - shift_val) mod Z]
//
// Two strategies selected at elaboration via generate:
//   Z=27  : simple two-stage pipelined mux-based cyclic shifter
//   Z=360 : decomposed 8x45 — coarse shift by (shift_val/45)*45, fine by shift_val%45
//
// Latency: 2 clock cycles (registered output)
// =============================================================================

module barrel_shifter #(
    parameter int Z = 27,   // number of elements (lifting size)
    parameter int W = 6     // element width in bits
)(
    input  logic              clk,
    input  logic              rst_n,
    input  logic [W*Z-1:0]   data_in,
    input  logic [8:0]        shift_val,  // 0..Z-1 cyclic shift amount
    output logic [W*Z-1:0]   data_out
);

    // =========================================================================
    // Strategy selection at elaboration time
    // =========================================================================
    generate
        if (Z == 360) begin : gen_decomposed
            // -----------------------------------------------------------------
            // Z=360 decomposed: 360 = 8 * 45
            //   coarse_shift = (shift_val / 45) => selects which group of 45
            //   fine_shift   = (shift_val % 45) => shift within group
            // -----------------------------------------------------------------
            localparam int COARSE = 8;
            localparam int FINE   = 45;

            // Combinational: compute coarse-shifted data
            logic [W*Z-1:0] coarse_shifted;
            logic [5:0]     fine_amt_comb;
            logic [3:0]     coarse_amt;

            always_comb begin
                coarse_amt    = shift_val / 9'd45;
                fine_amt_comb = shift_val - (coarse_amt * 9'd45);

                for (int i = 0; i < Z; i++) begin
                    coarse_shifted[i*W +: W] = data_in[((i + Z - coarse_amt * FINE) % Z)*W +: W];
                end
            end

            // Stage 1 registers
            logic [W*Z-1:0] stage1_r;
            logic [5:0]     fine_shift_r;

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    stage1_r     <= '0;
                    fine_shift_r <= '0;
                end else begin
                    stage1_r     <= coarse_shifted;
                    fine_shift_r <= fine_amt_comb;
                end
            end

            // Combinational: compute fine-shifted data
            logic [W*Z-1:0] fine_shifted;

            always_comb begin
                for (int i = 0; i < Z; i++) begin
                    fine_shifted[i*W +: W] = stage1_r[((i + Z - fine_shift_r) % Z)*W +: W];
                end
            end

            // Stage 2: register the output
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n)
                    data_out <= '0;
                else
                    data_out <= fine_shifted;
            end

        end else begin : gen_simple
            // -----------------------------------------------------------------
            // Generic strategy for small Z (e.g., Z=27):
            //   Two-stage pipelined mux-based cyclic shifter
            //   Stage 1: perform full cyclic shift combinationally, register result
            //   Stage 2: register again for 2-cycle latency
            // -----------------------------------------------------------------

            // Combinational: compute shifted data
            logic [W*Z-1:0] shifted_comb;

            always_comb begin
                for (int i = 0; i < Z; i++) begin
                    shifted_comb[i*W +: W] = data_in[((i + Z - shift_val) % Z)*W +: W];
                end
            end

            // Stage 1 register
            logic [W*Z-1:0] stage1_r;

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n)
                    stage1_r <= '0;
                else
                    stage1_r <= shifted_comb;
            end

            // Stage 2: register the output (adds second pipeline stage)
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n)
                    data_out <= '0;
                else
                    data_out <= stage1_r;
            end

        end
    endgenerate

endmodule
