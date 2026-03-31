// =============================================================================
// fft_butterfly.sv — Radix-2 Butterfly Unit
// =============================================================================
// Computes:
//   A_out = A_in + W_n * B_in
//   B_out = A_in - W_n * B_in
//
// Where complex twiddle multiply:
//   W_n * B = (B_re * W_re - B_im * W_im) + j(B_re * W_im + B_im * W_re)
//
// Pipeline: 2 clock cycles
//   Stage 1: Four multiplies (DSP)
//   Stage 2: Add/sub to form butterfly outputs
//
// Arithmetic: All signed fixed-point. Twiddle factors in Q1.(TW-2) format.
// Product is W+TW bits, truncated back to W bits with rounding.
// =============================================================================
`timescale 1ns / 1ps

module fft_butterfly #(
    parameter integer W  = 16,   // data width
    parameter integer TW = 12    // twiddle width
)(
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   valid_in,

    // Butterfly inputs (signed)
    input  wire signed [W-1:0]    a_re,
    input  wire signed [W-1:0]    a_im,
    input  wire signed [W-1:0]    b_re,
    input  wire signed [W-1:0]    b_im,

    // Twiddle factor (signed, Q1.(TW-2))
    input  wire signed [TW-1:0]   tw_re,
    input  wire signed [TW-1:0]   tw_im,

    // Butterfly outputs (signed)
    output reg  signed [W-1:0]    x_re,   // A + W*B
    output reg  signed [W-1:0]    x_im,
    output reg  signed [W-1:0]    y_re,   // A - W*B
    output reg  signed [W-1:0]    y_im,
    output reg                    valid_out
);

    // =========================================================================
    // Stage 1: Multiplies — 4 DSP multiplies
    // =========================================================================
    // W_n * B:
    //   prod_re = b_re * tw_re - b_im * tw_im
    //   prod_im = b_re * tw_im + b_im * tw_re
    //
    // Full product width = W + TW bits.
    // Twiddle is Q1.(TW-2), so we shift right by (TW-2) with rounding.

    localparam integer PROD_W   = W + TW;
    localparam integer SHIFT    = TW - 2;  // fractional bits in twiddle

    reg signed [PROD_W-1:0] mul_br_wr;  // b_re * tw_re
    reg signed [PROD_W-1:0] mul_bi_wi;  // b_im * tw_im
    reg signed [PROD_W-1:0] mul_br_wi;  // b_re * tw_im
    reg signed [PROD_W-1:0] mul_bi_wr;  // b_im * tw_re

    // Delayed A for alignment with multiply stage
    reg signed [W-1:0] a_re_d1, a_im_d1;
    reg                valid_d1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mul_br_wr <= {PROD_W{1'b0}};
            mul_bi_wi <= {PROD_W{1'b0}};
            mul_br_wi <= {PROD_W{1'b0}};
            mul_bi_wr <= {PROD_W{1'b0}};
            a_re_d1   <= {W{1'b0}};
            a_im_d1   <= {W{1'b0}};
            valid_d1  <= 1'b0;
        end else begin
            mul_br_wr <= b_re * tw_re;
            mul_bi_wi <= b_im * tw_im;
            mul_br_wi <= b_re * tw_im;
            mul_bi_wr <= b_im * tw_re;
            a_re_d1   <= a_re;
            a_im_d1   <= a_im;
            valid_d1  <= valid_in;
        end
    end

    // =========================================================================
    // Stage 2: Add/subtract to form butterfly outputs
    // =========================================================================
    // Complex product of W*B (before truncation)
    wire signed [PROD_W-1:0] wb_re_full = mul_br_wr - mul_bi_wi;
    wire signed [PROD_W-1:0] wb_im_full = mul_br_wi + mul_bi_wr;

    // Round: add 0.5 ULP before truncation, then shift right by SHIFT
    wire signed [PROD_W-1:0] wb_re_rnd = wb_re_full + (1 <<< (SHIFT - 1));
    wire signed [PROD_W-1:0] wb_im_rnd = wb_im_full + (1 <<< (SHIFT - 1));

    // Truncate to W+1 bits (to allow butterfly add without overflow)
    wire signed [W:0] wb_re = wb_re_rnd[SHIFT +: (W+1)];
    wire signed [W:0] wb_im = wb_im_rnd[SHIFT +: (W+1)];

    // Extend A to W+1 bits for butterfly
    wire signed [W:0] a_re_ext = {a_re_d1[W-1], a_re_d1};
    wire signed [W:0] a_im_ext = {a_im_d1[W-1], a_im_d1};

    // Butterfly: X = A + W*B, Y = A - W*B
    wire signed [W:0] sum_re = a_re_ext + wb_re;
    wire signed [W:0] sum_im = a_im_ext + wb_im;
    wire signed [W:0] dif_re = a_re_ext - wb_re;
    wire signed [W:0] dif_im = a_im_ext - wb_im;

    // Saturate back to W bits
    function [W-1:0] saturate;
        input signed [W:0] val;
        begin
            if (val > $signed({{1{1'b0}}, {(W-1){1'b1}}}))       // > max positive
                saturate = {1'b0, {(W-1){1'b1}}};
            else if (val < $signed({{1{1'b1}}, {(W-1){1'b0}}}))  // < max negative
                saturate = {1'b1, {(W-1){1'b0}}};
            else
                saturate = val[W-1:0];
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_re      <= {W{1'b0}};
            x_im      <= {W{1'b0}};
            y_re      <= {W{1'b0}};
            y_im      <= {W{1'b0}};
            valid_out <= 1'b0;
        end else begin
            x_re      <= saturate(sum_re);
            x_im      <= saturate(sum_im);
            y_re      <= saturate(dif_re);
            y_im      <= saturate(dif_im);
            valid_out <= valid_d1;
        end
    end

endmodule
