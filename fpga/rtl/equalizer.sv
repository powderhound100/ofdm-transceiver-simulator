// =============================================================================
// equalizer.sv — ZF/MMSE Channel Equalizer
// =============================================================================
// ZF mode:   EQ = Y * conj(H) / |H|^2
// MMSE mode: EQ = Y * conj(H) / (|H|^2 + sigma^2)
//
// Numerator (same for both):
//   EQ_re = Y_re*H_re + Y_im*H_im
//   EQ_im = Y_im*H_re - Y_re*H_im
//
// Denominator:
//   ZF:   D = H_re^2 + H_im^2
//   MMSE: D = H_re^2 + H_im^2 + sigma^2
//
// Division via reciprocal_lut: EQ = numerator * (1/D)
//
// Pipeline: 6 stages
//   Stage 1: Multiplies for numerator and |H|^2
//   Stage 2: Sum products
//   Stage 3: Add noise variance (MMSE), start reciprocal LUT
//   Stage 4: LUT output ready
//   Stage 5: Multiply numerator * reciprocal
//   Stage 6: Truncate and output
// =============================================================================
`timescale 1ns / 1ps

module equalizer (
    input  wire        clk,
    input  wire        rst_n,

    // Received data input {Q[15:0], I[15:0]}
    input  wire [31:0] data_in,
    input  wire        data_valid,

    // Channel estimate input {Q[15:0], I[15:0]}
    input  wire [31:0] h_est_in,
    input  wire        h_est_valid,

    // Configuration
    input  wire [15:0] noise_var,   // Q8.8 noise variance for MMSE
    input  wire        eq_mode,     // 0=ZF, 1=MMSE

    // Equalized output {Q[15:0], I[15:0]}
    output reg  [31:0] eq_out,
    output reg         eq_valid
);

    // =========================================================================
    // Input decomposition
    // =========================================================================
    wire signed [15:0] y_re = $signed(data_in[15:0]);
    wire signed [15:0] y_im = $signed(data_in[31:16]);
    wire signed [15:0] h_re = $signed(h_est_in[15:0]);
    wire signed [15:0] h_im = $signed(h_est_in[31:16]);

    // Both inputs must be valid simultaneously
    wire input_valid = data_valid && h_est_valid;

    // =========================================================================
    // Stage 1: Multiply (4 DSP multiplies for numerator + 2 for |H|^2)
    // =========================================================================
    // Numerator: conj(H)*Y
    //   num_re = Y_re*H_re + Y_im*H_im
    //   num_im = Y_im*H_re - Y_re*H_im
    // |H|^2 = H_re*H_re + H_im*H_im

    reg signed [31:0] mul_yr_hr;  // Y_re * H_re
    reg signed [31:0] mul_yi_hi;  // Y_im * H_im
    reg signed [31:0] mul_yi_hr;  // Y_im * H_re
    reg signed [31:0] mul_yr_hi;  // Y_re * H_im
    reg signed [31:0] mul_hr_hr;  // H_re * H_re
    reg signed [31:0] mul_hi_hi;  // H_im * H_im
    reg               s1_valid;
    reg               s1_mode;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mul_yr_hr <= 32'd0;
            mul_yi_hi <= 32'd0;
            mul_yi_hr <= 32'd0;
            mul_yr_hi <= 32'd0;
            mul_hr_hr <= 32'd0;
            mul_hi_hi <= 32'd0;
            s1_valid  <= 1'b0;
            s1_mode   <= 1'b0;
        end else begin
            s1_valid  <= input_valid;
            s1_mode   <= eq_mode;
            if (input_valid) begin
                mul_yr_hr <= y_re * h_re;
                mul_yi_hi <= y_im * h_im;
                mul_yi_hr <= y_im * h_re;
                mul_yr_hi <= y_re * h_im;
                mul_hr_hr <= h_re * h_re;
                mul_hi_hi <= h_im * h_im;
            end
        end
    end

    // =========================================================================
    // Stage 2: Sum products
    // =========================================================================
    // Numerator is in Q2.28 (16-bit * 16-bit, both Q1.14)
    // We scale by >> 14 to get back to Q1.14 range later
    reg signed [32:0] num_re_s2;   // extra bit for addition
    reg signed [32:0] num_im_s2;
    reg        [31:0] mag_sq_s2;   // |H|^2, unsigned (always positive)
    reg               s2_valid;
    reg               s2_mode;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            num_re_s2 <= 33'd0;
            num_im_s2 <= 33'd0;
            mag_sq_s2 <= 32'd0;
            s2_valid  <= 1'b0;
            s2_mode   <= 1'b0;
        end else begin
            s2_valid  <= s1_valid;
            s2_mode   <= s1_mode;
            if (s1_valid) begin
                num_re_s2 <= {mul_yr_hr[31], mul_yr_hr} + {mul_yi_hi[31], mul_yi_hi};
                num_im_s2 <= {mul_yi_hr[31], mul_yi_hr} - {mul_yr_hi[31], mul_yr_hi};
                mag_sq_s2 <= mul_hr_hr[31:0] + mul_hi_hi[31:0];  // always positive
            end
        end
    end

    // =========================================================================
    // Stage 3: Add noise variance for MMSE, normalize |H|^2 for LUT
    // =========================================================================
    // |H|^2 is in Q2.28 format (product of two Q1.14 values)
    // noise_var is in Q8.8 format
    // We need to align: shift noise_var left by 20 to get to Q2.28
    // Actually, let's scale |H|^2 down to 16-bit for LUT input
    // Shift |H|^2 >> 14 to get it back to roughly Q2.14 range (16-bit)

    reg signed [32:0] num_re_s3;
    reg signed [32:0] num_im_s3;
    reg        [15:0] denom_s3;    // 16-bit for reciprocal LUT
    reg               s3_valid;
    reg        [4:0]  num_shift_s3;  // track how much we shifted numerator

    // Scale denominator to 16 bits: find a suitable right-shift
    wire [31:0] denom_with_noise = s2_mode ?
        (mag_sq_s2 + ({16'd0, noise_var} << 14)) :  // shift noise_var to Q2.28
        mag_sq_s2;

    // Normalize denominator to 16 bits by finding MSB position
    reg [15:0] denom_norm;
    reg [4:0]  denom_shift;

    always @(*) begin
        if (denom_with_noise[31:16] != 16'd0) begin
            denom_norm  = denom_with_noise[31:16];
            denom_shift = 5'd16;
        end else begin
            denom_norm  = denom_with_noise[15:0];
            denom_shift = 5'd0;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            num_re_s3   <= 33'd0;
            num_im_s3   <= 33'd0;
            denom_s3    <= 16'd0;
            s3_valid    <= 1'b0;
            num_shift_s3 <= 5'd0;
        end else begin
            s3_valid     <= s2_valid;
            num_re_s3    <= num_re_s2;
            num_im_s3    <= num_im_s2;
            denom_s3     <= denom_norm;
            num_shift_s3 <= denom_shift;
        end
    end

    // =========================================================================
    // Stage 3→4: Reciprocal LUT (1-cycle latency)
    // =========================================================================
    wire [15:0] recip_val;
    wire        recip_valid;

    reciprocal_lut u_recip (
        .clk       (clk),
        .rst_n     (rst_n),
        .mag_sq_in (denom_s3),
        .in_valid  (s3_valid),
        .recip_out (recip_val),
        .out_valid (recip_valid)
    );

    // Pipeline numerator and shift to align with LUT output
    reg signed [32:0] num_re_s4;
    reg signed [32:0] num_im_s4;
    reg        [4:0]  num_shift_s4;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            num_re_s4    <= 33'd0;
            num_im_s4    <= 33'd0;
            num_shift_s4 <= 5'd0;
        end else begin
            num_re_s4    <= num_re_s3;
            num_im_s4    <= num_im_s3;
            num_shift_s4 <= num_shift_s3;
        end
    end

    // =========================================================================
    // Stage 5: Multiply numerator * reciprocal
    // =========================================================================
    // EQ = num * recip
    // num is in Q2.28 (33 bits), recip is Q0.15 (16 bits)
    // Product is Q2.43 (49 bits). We need Q1.14 output (16 bits).
    // Shift right by 43-14 = 29 bits, but also account for denom_shift.

    reg signed [48:0] prod_re_s5;
    reg signed [48:0] prod_im_s5;
    reg        [4:0]  shift_s5;
    reg               s5_valid;

    // Truncate numerator to 32 bits before multiply to save resources
    wire signed [31:0] num_re_trunc = num_re_s4[32:1];
    wire signed [31:0] num_im_trunc = num_im_s4[32:1];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prod_re_s5 <= 49'd0;
            prod_im_s5 <= 49'd0;
            shift_s5   <= 5'd0;
            s5_valid   <= 1'b0;
        end else begin
            s5_valid   <= recip_valid;
            shift_s5   <= num_shift_s4;
            if (recip_valid) begin
                prod_re_s5 <= num_re_trunc * $signed({1'b0, recip_val});
                prod_im_s5 <= num_im_trunc * $signed({1'b0, recip_val});
            end
        end
    end

    // =========================================================================
    // Stage 6: Truncate, round, and output
    // =========================================================================
    // Product = num(Q2.27, truncated from Q2.28) * recip(Q0.15) = Q2.42 (48 bits)
    // We want Q1.14 output.
    // Total fractional bits = 27 + 15 = 42. Target fractional = 14.
    // Base shift = 42 - 14 = 28.
    // But we also need to compensate for denom_shift:
    // If denom was shifted right by denom_shift to fit 16 bits, the recip
    // is (2^15 / (denom >> denom_shift)) = (2^15 * 2^denom_shift) / denom
    // So the product has an extra factor of 2^denom_shift, meaning we need
    // to shift right by an additional denom_shift.
    // Total shift = 28 + denom_shift

    wire [5:0] total_shift = 6'd28 + {1'd0, shift_s5};

    // Extract Q1.14 from product with variable shift
    wire signed [48:0] shifted_re = prod_re_s5 >>> total_shift;
    wire signed [48:0] shifted_im = prod_im_s5 >>> total_shift;

    // Saturate to 16-bit signed
    wire signed [15:0] eq_re_sat;
    wire signed [15:0] eq_im_sat;

    assign eq_re_sat = (shifted_re > 49'sd32767) ? 16'sd32767 :
                       (shifted_re < -49'sd32768) ? -16'sd32768 :
                       shifted_re[15:0];
    assign eq_im_sat = (shifted_im > 49'sd32767) ? 16'sd32767 :
                       (shifted_im < -49'sd32768) ? -16'sd32768 :
                       shifted_im[15:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            eq_out   <= 32'd0;
            eq_valid <= 1'b0;
        end else begin
            eq_valid <= s5_valid;
            if (s5_valid) begin
                eq_out <= {eq_im_sat, eq_re_sat};
            end
        end
    end

endmodule
