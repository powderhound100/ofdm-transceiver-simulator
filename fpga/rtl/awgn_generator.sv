// =============================================================================
// awgn_generator.sv — AWGN noise generator using Central Limit Theorem
// =============================================================================
// Generates approximate Gaussian noise by summing 12 uniform random samples
// from a 64-bit Galois LFSR, subtracting the mean, and scaling by noise_scale.
//
// Two independent channels (I, Q) use separate LFSR instances.
//
// Pipeline (per channel):
//   1. Collect 12 consecutive 16-bit unsigned LFSR outputs → 20-bit sum
//   2. Subtract mean: approx_gaussian = sum - 12*32768 = sum - 393216
//      Result is signed ~20-bit centered around zero (range: -393216 to +393204)
//   3. Scale: noise_sample = (approx_gaussian * noise_scale) >> 8
//      noise_scale is Q8.8 (precomputed sqrt(Pn/2))
//
// Generates one noise sample pair every 12 clock cycles.
//
// Interface:
//   clk, rst_n    — clock and active-low synchronous reset
//   enable        — enable noise generation (hold high for continuous output)
//   seed_i, seed_q — 64-bit seeds for I and Q LFSR instances
//   noise_scale   — Q8.8 scaling factor: precomputed sqrt(Pn/2)
//   noise_i, noise_q — 16-bit signed output noise samples
//   noise_valid   — pulse when noise_i/noise_q are valid
// =============================================================================

`timescale 1ns / 1ps

module awgn_generator (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        enable,
    input  logic [63:0] seed_i,
    input  logic [63:0] seed_q,
    input  logic [15:0] noise_scale,    // Q8.8 format
    output logic signed [15:0] noise_i,
    output logic signed [15:0] noise_q,
    output logic        noise_valid
);

    // -------------------------------------------------------------------------
    // LFSR instances for I and Q channels
    // -------------------------------------------------------------------------
    logic        lfsr_seed_load;
    logic [15:0] lfsr_out_i, lfsr_out_q;
    logic        lfsr_valid_i, lfsr_valid_q;

    lfsr64 u_lfsr_i (
        .clk       (clk),
        .rst_n     (rst_n),
        .seed_load (lfsr_seed_load),
        .seed_val  (seed_i),
        .rand_out  (lfsr_out_i),
        .rand_valid(lfsr_valid_i)
    );

    lfsr64 u_lfsr_q (
        .clk       (clk),
        .rst_n     (rst_n),
        .seed_load (lfsr_seed_load),
        .seed_val  (seed_q),
        .rand_out  (lfsr_out_q),
        .rand_valid(lfsr_valid_q)
    );

    // -------------------------------------------------------------------------
    // Seed loading — one-shot on first enable after reset
    // -------------------------------------------------------------------------
    logic seed_loaded;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            lfsr_seed_load <= 1'b0;
            seed_loaded    <= 1'b0;
        end else begin
            lfsr_seed_load <= 1'b0;
            if (enable && !seed_loaded) begin
                lfsr_seed_load <= 1'b1;
                seed_loaded    <= 1'b1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Accumulation counter: count 12 LFSR samples per noise output
    // -------------------------------------------------------------------------
    localparam [3:0] SUM_COUNT = 4'd12;

    logic [3:0]  sample_cnt;
    logic [19:0] sum_i, sum_q;          // 20-bit sum of 12 x 16-bit unsigned values
                                         // Max: 12 * 65535 = 786420 < 2^20 = 1048576

    // -------------------------------------------------------------------------
    // Gaussian approximation and scaling pipeline
    // -------------------------------------------------------------------------
    // Stage 1: subtract mean → signed centered value
    //   Mean of 12 uniform [0,65535]: 12 * 32768 = 393216 (19 bits)
    //   Range after subtraction: [-393216, +393204] → fits in signed 21 bits
    //
    // Stage 2: multiply by noise_scale (Q8.8) → 37-bit product
    //   Then shift right by 8 to get final 16-bit noise sample
    // -------------------------------------------------------------------------
    localparam signed [20:0] CLT_MEAN = 21'sd393216;  // 12 * 32768

    logic signed [20:0] centered_i, centered_q;
    logic signed [36:0] scaled_i, scaled_q;

    // Pipeline stage flags
    logic        sum_done;      // all 12 samples accumulated
    logic        center_done;   // mean-subtracted
    logic        scale_done;    // scaling complete

    // -------------------------------------------------------------------------
    // Main pipeline
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            sample_cnt  <= 4'd0;
            sum_i       <= 20'd0;
            sum_q       <= 20'd0;
            centered_i  <= 21'sd0;
            centered_q  <= 21'sd0;
            scaled_i    <= 37'sd0;
            scaled_q    <= 37'sd0;
            noise_i     <= 16'sd0;
            noise_q     <= 16'sd0;
            noise_valid <= 1'b0;
            sum_done    <= 1'b0;
            center_done <= 1'b0;
            scale_done  <= 1'b0;
        end else begin
            // Default: clear pulse signals
            noise_valid <= 1'b0;
            sum_done    <= 1'b0;
            center_done <= 1'b0;
            scale_done  <= 1'b0;

            // -----------------------------------------------------------------
            // Stage 0: Accumulate 12 LFSR samples
            // -----------------------------------------------------------------
            if (enable && lfsr_valid_i && lfsr_valid_q) begin
                if (sample_cnt == 4'd0) begin
                    // First sample of a new group
                    sum_i      <= {4'd0, lfsr_out_i};
                    sum_q      <= {4'd0, lfsr_out_q};
                    sample_cnt <= 4'd1;
                end else if (sample_cnt < SUM_COUNT - 4'd1) begin
                    // Accumulate
                    sum_i      <= sum_i + {4'd0, lfsr_out_i};
                    sum_q      <= sum_q + {4'd0, lfsr_out_q};
                    sample_cnt <= sample_cnt + 4'd1;
                end else begin
                    // Last (12th) sample — trigger next pipeline stage
                    sum_i      <= sum_i + {4'd0, lfsr_out_i};
                    sum_q      <= sum_q + {4'd0, lfsr_out_q};
                    sample_cnt <= 4'd0;
                    sum_done   <= 1'b1;
                end
            end

            // -----------------------------------------------------------------
            // Stage 1: Subtract mean (centered Gaussian approximation)
            // -----------------------------------------------------------------
            if (sum_done) begin
                centered_i  <= $signed({1'b0, sum_i}) - CLT_MEAN;
                centered_q  <= $signed({1'b0, sum_q}) - CLT_MEAN;
                center_done <= 1'b1;
            end

            // -----------------------------------------------------------------
            // Stage 2: Scale by noise_scale (Q8.8)
            // -----------------------------------------------------------------
            if (center_done) begin
                scaled_i   <= centered_i * $signed({1'b0, noise_scale});
                scaled_q   <= centered_q * $signed({1'b0, noise_scale});
                scale_done <= 1'b1;
            end

            // -----------------------------------------------------------------
            // Stage 3: Extract 16-bit output with saturation
            // Shift right by 8 (Q8.8 scaling) then saturate to 16-bit signed
            // -----------------------------------------------------------------
            if (scale_done) begin
                noise_i     <= saturate_16(scaled_i >>> 8);
                noise_q     <= saturate_16(scaled_q >>> 8);
                noise_valid <= 1'b1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // 37-bit to 16-bit signed saturation
    // -------------------------------------------------------------------------
    function logic signed [15:0] saturate_16;
        input logic signed [36:0] val;
        begin
            if (val > 37'sd32767)
                saturate_16 = 16'sd32767;
            else if (val < -37'sd32768)
                saturate_16 = -16'sd32768;
            else
                saturate_16 = val[15:0];
        end
    endfunction

endmodule
