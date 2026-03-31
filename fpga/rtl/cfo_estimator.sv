`timescale 1ns / 1ps
// =============================================================================
// cfo_estimator.sv — Carrier Frequency Offset Estimator
// =============================================================================
// Estimates fractional CFO from CP correlation:
//   CFO = angle(P) / (2*pi*N)
//
// Uses CORDIC-like atan2 approximation for angle extraction.
// Output: Q1.14 fractional frequency offset estimate.
// =============================================================================

module cfo_estimator #(
    parameter int FFT_N = 64,
    parameter int IQ_W  = 16
)(
    input  logic                    clk,
    input  logic                    rst_n,

    // Correlation value P (from symbol_sync or external)
    input  logic signed [31:0]      corr_re,    // Real part of CP correlation
    input  logic signed [31:0]      corr_im,    // Imag part of CP correlation
    input  logic                    corr_valid,

    // CFO estimate output
    output logic signed [15:0]      cfo_est,    // Q1.14 fractional CFO
    output logic                    cfo_valid
);

    // CORDIC atan2 approximation
    // atan2(y, x) ≈ phase
    // Simplified: use piecewise linear approximation
    //   if |x| >= |y|: angle ≈ y/x (small angle approx) or use table
    //   For OFDM CFO, the angle is typically small (< pi)

    // Pipeline stage 1: Absolute values and quadrant detection
    logic [31:0] abs_re, abs_im;
    logic sign_re, sign_im;
    logic swap;  // |im| > |re|
    logic p1_valid;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            abs_re   <= 0;
            abs_im   <= 0;
            sign_re  <= 0;
            sign_im  <= 0;
            swap     <= 0;
            p1_valid <= 0;
        end else begin
            p1_valid <= corr_valid;
            sign_re  <= corr_re[31];
            sign_im  <= corr_im[31];
            abs_re   <= corr_re[31] ? -corr_re : corr_re;
            abs_im   <= corr_im[31] ? -corr_im : corr_im;
            swap     <= (corr_im[31] ? -corr_im : corr_im) >
                        (corr_re[31] ? -corr_re : corr_re);
        end
    end

    // Pipeline stage 2: Compute atan2 via linear approximation
    // atan(y/x) ≈ (pi/4) * (y/x) for |y/x| <= 1
    // Use: angle = y * (pi/4) / x (multiply y by pi/4 * 2^14 / x)
    // Simplified: angle ≈ (y << 14) / x when |y| <= |x|
    logic signed [15:0] angle;
    logic p2_valid;

    logic [31:0] num, den;
    logic [31:0] ratio;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            angle    <= 0;
            p2_valid <= 0;
        end else begin
            p2_valid <= p1_valid;

            if (p1_valid) begin
                if (swap) begin
                    num = abs_re;
                    den = abs_im;
                end else begin
                    num = abs_im;
                    den = abs_re;
                end

                // Compute num/den * (pi/4) in Q1.14
                // pi/4 * 2^14 ≈ 12868
                if (den > 0) begin
                    ratio = (num * 12868) / den;
                end else begin
                    ratio = 0;
                end

                // Correct for quadrant and swap
                if (swap) begin
                    // angle = pi/2 - atan(x/y)
                    // pi/2 in Q1.14 = 25736
                    angle <= 16'sd25736 - ratio[15:0];
                end else begin
                    angle <= ratio[15:0];
                end
            end
        end
    end

    // Pipeline stage 3: Apply quadrant correction and scale by 1/(2*pi*N)
    // CFO = angle / (2*pi*N)
    // 1/(2*pi*64) * 2^14 ≈ 40.74 → use 41
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cfo_est   <= 0;
            cfo_valid <= 0;
        end else begin
            cfo_valid <= p2_valid;

            if (p2_valid) begin
                // Full angle with sign restoration
                logic signed [15:0] full_angle;
                if (sign_re && sign_im) begin
                    // Third quadrant: angle = -(pi - angle)
                    full_angle = -(16'sd25736 + angle);  // Approximate
                end else if (sign_re) begin
                    // Second quadrant: angle = pi - angle
                    full_angle = 16'sd25736 + angle;     // Approximate
                end else if (sign_im) begin
                    // Fourth quadrant: angle = -angle
                    full_angle = -angle;
                end else begin
                    full_angle = angle;
                end

                // Scale: CFO = full_angle / (2*pi*N)
                // Already in Q1.14 radians. Divide by 2*pi*N = 402.12
                // Multiply by 1/402 ≈ 41 / 2^14
                cfo_est <= (full_angle * 16'sd41) >>> 14;
            end
        end
    end

endmodule
