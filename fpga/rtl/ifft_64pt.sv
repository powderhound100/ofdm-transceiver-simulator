// =============================================================================
// ifft_64pt.sv — 64-Point Inverse FFT
// =============================================================================
// Implements IFFT using the identity:
//   IFFT(X) = conj(FFT(conj(X))) / N
//
// Procedure:
//   1. Swap Re/Im at input  (conjugate input)
//   2. Run forward FFT via fft_64pt (SDF architecture)
//   3. Swap Re/Im at output (conjugate output)
//   4. Scale by 1/N = 1/64  (right-shift by 6 with rounding)
//
// Reuses the existing fft_64pt module (SDF pipeline architecture).
//
// Interface:
//   Input:  16-bit signed Re + Im, streamed (64 frequency-domain samples)
//   Output: 16-bit signed Re + Im, streamed (64 time-domain samples)
//
// Latency: same as fft_64pt (~N + pipeline delays)
// =============================================================================
`timescale 1ns / 1ps

module ifft_64pt #(
    parameter integer FFT_N = 64,
    parameter integer W     = 16,    // data width
    parameter integer TW    = 12     // twiddle width
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // Input stream (frequency-domain)
    input  wire signed [W-1:0]  s_re,
    input  wire signed [W-1:0]  s_im,
    input  wire                  s_valid,

    // Output stream (time-domain)
    output wire signed [W-1:0]  m_re,
    output wire signed [W-1:0]  m_im,
    output wire                  m_valid,
    output wire                  m_last
);

    // =========================================================================
    // Step 1: Conjugate input — swap Re and Im
    //   To compute IFFT via FFT: feed Im as Re, Re as Im
    //   IFFT(X) = conj(FFT(conj(X))) / N
    //   conj(a+jb) = a-jb, which is equivalent to swapping Re<->Im:
    //     swap(a+jb) = b+ja, FFT(b+ja) = ..., swap back, divide by N
    // =========================================================================
    wire signed [W-1:0] fft_in_re = s_im;   // swap: feed Im as Re
    wire signed [W-1:0] fft_in_im = s_re;   // swap: feed Re as Im

    // =========================================================================
    // Step 2: Forward FFT (SDF architecture)
    // =========================================================================
    wire signed [W-1:0] fft_out_re;
    wire signed [W-1:0] fft_out_im;
    wire                 fft_out_valid;
    wire                 fft_out_last;

    fft_64pt #(
        .FFT_N (FFT_N),
        .W_IN  (W),
        .W_OUT (W),
        .TW    (TW)
    ) u_fft (
        .clk     (clk),
        .rst_n   (rst_n),
        .s_re    (fft_in_re),
        .s_im    (fft_in_im),
        .s_valid (s_valid),
        .m_re    (fft_out_re),
        .m_im    (fft_out_im),
        .m_valid (fft_out_valid),
        .m_last  (fft_out_last)
    );

    // =========================================================================
    // Step 3: Conjugate output — swap Re and Im back
    // Step 4: Scale by 1/N = 1/64 — arithmetic right shift by 6
    // =========================================================================
    // After swap: new_re = fft_out_im, new_im = fft_out_re
    // After /64:  new_re = fft_out_im >>> 6, new_im = fft_out_re >>> 6
    //
    // Rounding: add 32 (= 2^5, half of 2^6) before shift for proper rounding
    // =========================================================================

    // Arithmetic right shift by 6 with rounding
    // Extend to W+7 bits to avoid overflow during add, then shift
    wire signed [W+6:0] ext_re = {{7{fft_out_im[W-1]}}, fft_out_im};
    wire signed [W+6:0] ext_im = {{7{fft_out_re[W-1]}}, fft_out_re};

    // Add rounding bias (32 = 2^5 = half of 2^6)
    wire signed [W+6:0] rnd_re = ext_re + 32;
    wire signed [W+6:0] rnd_im = ext_im + 32;

    // Arithmetic right shift by 6, then saturate to W bits
    wire signed [W:0] shifted_re = rnd_re[W+6:6];
    wire signed [W:0] shifted_im = rnd_im[W+6:6];

    // Saturate from W+1 bits to W bits
    wire signed [W-1:0] scaled_re;
    wire signed [W-1:0] scaled_im;

    assign scaled_re = (shifted_re > $signed({{2{1'b0}}, {(W-1){1'b1}}})) ? {1'b0, {(W-1){1'b1}}} :
                       (shifted_re < $signed({{2{1'b1}}, {(W-1){1'b0}}})) ? {1'b1, {(W-1){1'b0}}} :
                       shifted_re[W-1:0];
    assign scaled_im = (shifted_im > $signed({{2{1'b0}}, {(W-1){1'b1}}})) ? {1'b0, {(W-1){1'b1}}} :
                       (shifted_im < $signed({{2{1'b1}}, {(W-1){1'b0}}})) ? {1'b1, {(W-1){1'b0}}} :
                       shifted_im[W-1:0];

    // Output assignments
    assign m_re    = fft_out_valid ? scaled_re : {W{1'b0}};
    assign m_im    = fft_out_valid ? scaled_im : {W{1'b0}};
    assign m_valid = fft_out_valid;
    assign m_last  = fft_out_last;

endmodule
