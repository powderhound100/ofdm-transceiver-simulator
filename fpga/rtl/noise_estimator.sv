`timescale 1ns / 1ps
// =============================================================================
// noise_estimator.sv — Pilot-based noise variance estimator
// =============================================================================
// Estimates sigma^2 from pilot subcarriers:
//   noise[k] = RX_pilot[k] - TX_PILOT * H_est[k]
//   sigma^2  = mean(|noise[k]|^2) over 4 pilots
//
// Since TX_PILOT = 1+j0, noise[k] = RX_pilot[k] - H_est[k]
//
// Output: Q8.8 noise variance estimate
// =============================================================================

module noise_estimator #(
    parameter int IQ_W = 16   // I/Q sample width
)(
    input  logic                    clk,
    input  logic                    rst_n,

    // Pilot inputs (from subcarrier_demux)
    input  logic signed [IQ_W-1:0] pilot_re,
    input  logic signed [IQ_W-1:0] pilot_im,
    input  logic                    pilot_valid,

    // Channel estimate at pilot positions (from channel_estimator)
    input  logic signed [IQ_W-1:0] h_est_re,
    input  logic signed [IQ_W-1:0] h_est_im,
    input  logic                    h_est_valid,

    // Output noise variance
    output logic [15:0]             noise_var,     // Q8.8
    output logic                    noise_var_valid
);

    // Internal signals
    logic signed [IQ_W-1:0] err_re, err_im;
    logic signed [2*IQ_W-1:0] err_re_sq, err_im_sq;
    logic signed [2*IQ_W:0]   err_power;   // |noise|^2
    logic [2*IQ_W+1:0]        accum;       // Accumulated power over 4 pilots
    logic [1:0]               pilot_cnt;   // Count 0-3

    // Pipeline stage 1: compute error = rx_pilot - h_est
    logic p1_valid;
    logic signed [IQ_W-1:0] p1_err_re, p1_err_im;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p1_valid  <= 0;
            p1_err_re <= 0;
            p1_err_im <= 0;
        end else begin
            // Both pilot and h_est should arrive simultaneously
            p1_valid  <= pilot_valid & h_est_valid;
            p1_err_re <= pilot_re - h_est_re;
            p1_err_im <= pilot_im - h_est_im;
        end
    end

    // Pipeline stage 2: compute |error|^2 = err_re^2 + err_im^2
    logic p2_valid;
    logic [2*IQ_W:0] p2_power;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p2_valid <= 0;
            p2_power <= 0;
        end else begin
            p2_valid <= p1_valid;
            err_re_sq = p1_err_re * p1_err_re;
            err_im_sq = p1_err_im * p1_err_im;
            p2_power <= err_re_sq[2*IQ_W-1:0] + err_im_sq[2*IQ_W-1:0];
        end
    end

    // Pipeline stage 3: accumulate over 4 pilots, divide by 4
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            accum          <= 0;
            pilot_cnt      <= 0;
            noise_var       <= 0;
            noise_var_valid <= 0;
        end else begin
            noise_var_valid <= 0;

            if (p2_valid) begin
                if (pilot_cnt == 2'd0) begin
                    accum <= p2_power;
                end else begin
                    accum <= accum + p2_power;
                end

                if (pilot_cnt == 2'd3) begin
                    // Average = accum / 4 (right shift by 2)
                    // Convert from Q2.28 (squared Q1.14) to Q8.8
                    // Q2.28 >> 2 = Q2.26, then >> 18 to get Q8.8
                    // Total shift: 2 (divide by 4) + 20 (Q2.28 to Q8.8) = 22
                    // But we need to be careful about the scale
                    // err is Q1.14, err^2 is Q2.28, sum of 4 is Q4.28
                    // divide by 4: Q2.28
                    // To Q8.8: shift right by 20
                    noise_var <= (accum + p2_power) >> 20;
                    noise_var_valid <= 1;
                    pilot_cnt <= 0;
                end else begin
                    pilot_cnt <= pilot_cnt + 1;
                end
            end
        end
    end

endmodule
