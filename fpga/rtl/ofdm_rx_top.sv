// =============================================================================
// ofdm_rx_top.sv — Full OFDM Receiver Top-Level
// =============================================================================
// Signal chain:
//   cp_removal → fft_64pt → subcarrier_demux →
//     (pilot path) channel_estimator
//     (data path)  data_align_buffer →
//   equalizer → soft_demapper → frame_controller → (ldpc_top)
//
// Parameters: FFT_N=64, CP_LEN=16, LLR_W=6
// Config inputs: cfg_modulation, noise_var, eq_mode, cfg_estimator
//
// AXI-Stream slave: RX IQ samples in
// AXI-Stream master: LLR frame out (to LDPC decoder)
// =============================================================================
`timescale 1ns / 1ps

module ofdm_rx_top #(
    parameter integer FFT_N  = 64,
    parameter integer CP_LEN = 16,
    parameter integer W_IQ   = 16,
    parameter integer TW     = 12,
    parameter integer LLR_W  = 6
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---- AXI-Stream slave: RX IQ samples ----
    input  wire [31:0] s_tdata,   // {Q[15:0], I[15:0]}
    input  wire        s_tvalid,
    output wire        s_tready,

    // ---- AXI-Stream master: LLR frame to LDPC decoder ----
    output wire [LLR_W-1:0] m_tdata,
    output wire              m_tvalid,
    output wire              m_tlast,
    input  wire              m_tready,

    // ---- Configuration ----
    input  wire [3:0]  cfg_modulation,   // 0=QPSK, 1=16QAM
    input  wire [15:0] noise_var,        // Q8.8 noise variance
    input  wire        eq_mode,          // 0=ZF, 1=MMSE
    input  wire [1:0]  cfg_estimator,    // 0=LS, 1=LS-Improved, 2=LMMSE

    // ---- Status ----
    output wire        frame_ready
);

    // =========================================================================
    // Wire declarations for inter-module connections
    // =========================================================================

    // CP removal → FFT
    wire [31:0] cp_to_fft_data;
    wire        cp_to_fft_valid;
    wire        cp_to_fft_ready;
    wire        cp_to_fft_last;

    // FFT output
    wire signed [W_IQ-1:0] fft_out_re, fft_out_im;
    wire        fft_out_valid;
    wire        fft_out_last;

    // FFT output packed as {Q, I}
    wire [31:0] fft_out_data = {fft_out_im, fft_out_re};

    // Subcarrier demux → pilot path
    wire [31:0] pilot_data;
    wire        pilot_valid;
    wire        pilot_last;

    // Subcarrier demux → data path
    wire [31:0] demux_data_out;
    wire        demux_data_valid;
    wire        demux_data_last;

    // Data alignment buffer output
    wire [31:0] aligned_data;
    wire        aligned_data_valid;
    wire        aligned_data_ready;
    wire        aligned_data_last;

    // Channel estimator output
    wire [31:0] h_est_data;
    wire        h_est_valid;
    wire        h_est_last;

    // Equalizer output
    wire [31:0] eq_data;
    wire        eq_valid;

    // Soft demapper output
    wire signed [5:0] llr_out;
    wire        llr_valid;
    wire [3:0]  llr_bit_idx;
    wire        llr_last_bit;

    // Frame controller output (directly to top-level master port)
    wire [LLR_W-1:0] fc_tdata;
    wire              fc_tvalid;
    wire              fc_tlast;
    wire              fc_frame_ready;

    // =========================================================================
    // 1. Cyclic Prefix Removal
    // =========================================================================
    cp_removal #(
        .FFT_N  (FFT_N),
        .CP_LEN (CP_LEN)
    ) u_cp_removal (
        .clk      (clk),
        .rst_n    (rst_n),
        .s_tdata  (s_tdata),
        .s_tvalid (s_tvalid),
        .s_tready (s_tready),
        .m_tdata  (cp_to_fft_data),
        .m_tvalid (cp_to_fft_valid),
        .m_tready (1'b1),   // FFT always accepts (streaming pipeline)
        .m_tlast  (cp_to_fft_last)
    );

    // =========================================================================
    // 2. 64-point FFT
    // =========================================================================
    fft_64pt #(
        .FFT_N (FFT_N),
        .W_IN  (W_IQ),
        .W_OUT (W_IQ),
        .TW    (TW)
    ) u_fft (
        .clk     (clk),
        .rst_n   (rst_n),
        .s_re    (cp_to_fft_data[15:0]),
        .s_im    (cp_to_fft_data[31:16]),
        .s_valid (cp_to_fft_valid),
        .m_re    (fft_out_re),
        .m_im    (fft_out_im),
        .m_valid (fft_out_valid),
        .m_last  (fft_out_last)
    );

    // =========================================================================
    // 3. Subcarrier Demux
    // =========================================================================
    subcarrier_demux #(
        .FFT_N (FFT_N)
    ) u_demux (
        .clk         (clk),
        .rst_n       (rst_n),
        .fft_data    (fft_out_data),
        .fft_valid   (fft_out_valid),
        .fft_last    (fft_out_last),
        .pilot_data  (pilot_data),
        .pilot_valid (pilot_valid),
        .pilot_last  (pilot_last),
        .data_out    (demux_data_out),
        .data_valid  (demux_data_valid),
        .data_last   (demux_data_last)
    );

    // =========================================================================
    // 4. Channel Estimator (pilot path)
    // =========================================================================
    channel_estimator u_ch_est (
        .clk           (clk),
        .rst_n         (rst_n),
        .pilot_data    (pilot_data),
        .pilot_valid   (pilot_valid),
        .pilot_last    (pilot_last),
        .h_est_data    (h_est_data),
        .h_est_valid   (h_est_valid),
        .h_est_last    (h_est_last),
        .cfg_estimator (cfg_estimator)
    );

    // =========================================================================
    // 5. Data Alignment Buffer (data path FIFO)
    // =========================================================================
    data_align_buffer #(
        .WIDTH (32),
        .DEPTH (64)
    ) u_data_buf (
        .clk      (clk),
        .rst_n    (rst_n),
        .s_tdata  (demux_data_out),
        .s_tvalid (demux_data_valid),
        .s_tready (),              // demux always produces at FFT rate, buffer won't overflow
        .s_tlast  (demux_data_last),
        .m_tdata  (aligned_data),
        .m_tvalid (aligned_data_valid),
        .m_tready (h_est_valid),   // pop data when channel estimate is ready
        .m_tlast  (aligned_data_last)
    );

    // =========================================================================
    // 6. Equalizer
    // =========================================================================
    equalizer u_eq (
        .clk        (clk),
        .rst_n      (rst_n),
        .data_in    (aligned_data),
        .data_valid (aligned_data_valid && h_est_valid),
        .h_est_in   (h_est_data),
        .h_est_valid(h_est_valid && aligned_data_valid),
        .noise_var  (noise_var),
        .eq_mode    (eq_mode),
        .eq_out     (eq_data),
        .eq_valid   (eq_valid)
    );

    // =========================================================================
    // 7. Soft Demapper
    // =========================================================================
    soft_demapper u_demapper (
        .clk            (clk),
        .rst_n          (rst_n),
        .eq_data        (eq_data),
        .eq_valid       (eq_valid),
        .cfg_modulation (cfg_modulation),
        .noise_var      (noise_var),
        .llr_out        (llr_out),
        .llr_valid      (llr_valid),
        .llr_bit_idx    (llr_bit_idx),
        .llr_last_bit   (llr_last_bit)
    );

    // =========================================================================
    // 8. Frame Controller (LLR accumulator)
    // =========================================================================
    frame_controller #(
        .CODEWORD_LEN (648),
        .LLR_W        (LLR_W)
    ) u_frame_ctrl (
        .clk         (clk),
        .rst_n       (rst_n),
        .llr_in      (llr_out),
        .llr_valid   (llr_valid),
        .m_tdata     (m_tdata),
        .m_tvalid    (m_tvalid),
        .m_tlast     (m_tlast),
        .m_tready    (m_tready),
        .frame_ready (frame_ready)
    );

endmodule
