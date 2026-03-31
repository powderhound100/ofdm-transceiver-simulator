// =============================================================================
// ofdm_tx_top.sv — Full OFDM Transmitter Top-Level
// =============================================================================
// Signal chain:
//   ldpc_encoder -> qam_mapper -> subcarrier_mux -> ifft_64pt -> cp_insertion
//
// Parameters: FFT_N=64, CP_LEN=16
//
// AXI-Stream slave: information bits (1 bit/clock)
// AXI-Stream master: TX IQ samples (32-bit complex, {Q[15:0], I[15:0]})
//
// Config: cfg_modulation selects QPSK/16QAM/64QAM
//
// Data flow:
//   1. ldpc_encoder: 324 info bits -> 648 coded bits (rate 1/2)
//   2. qam_mapper: coded bits -> complex symbols (2/4/6 bits per symbol)
//   3. subcarrier_mux: 48 data symbols -> 64 freq bins (with pilots/guards)
//   4. ifft_64pt: 64 freq bins -> 64 time-domain samples
//   5. cp_insertion: 64 samples -> 80 samples (16-sample CP prepended)
// =============================================================================
`timescale 1ns / 1ps

module ofdm_tx_top #(
    parameter integer FFT_N  = 64,
    parameter integer CP_LEN = 16,
    parameter integer W_IQ   = 16,
    parameter integer TW     = 12
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---- AXI-Stream slave: information bits ----
    input  wire        s_tdata,     // 1 info bit per transfer
    input  wire        s_tvalid,
    output wire        s_tready,
    input  wire        s_tlast,

    // ---- AXI-Stream master: TX IQ samples ----
    output wire [31:0] m_tdata,     // {Q[15:0], I[15:0]}
    output wire        m_tvalid,
    input  wire        m_tready,
    output wire        m_tlast,

    // ---- Configuration ----
    input  wire [3:0]  cfg_modulation,  // 0=QPSK, 1=16QAM, 2=64QAM

    // ---- Status ----
    output wire        encoder_busy
);

    // =========================================================================
    // Wire declarations for inter-module connections
    // =========================================================================

    // LDPC encoder -> QAM mapper
    wire        enc_to_qam_data;
    wire        enc_to_qam_valid;
    wire        enc_to_qam_ready;
    wire        enc_to_qam_last;

    // QAM mapper -> subcarrier mux
    wire [31:0] qam_to_mux_data;
    wire        qam_to_mux_valid;

    // Subcarrier mux -> IFFT
    wire [31:0] mux_to_ifft_data;
    wire        mux_to_ifft_valid;
    wire        mux_to_ifft_last;
    wire        mux_to_ifft_first;

    // Subcarrier mux -> IFFT (unpacked Re/Im)
    wire signed [W_IQ-1:0] mux_re = mux_to_ifft_data[W_IQ-1:0];
    wire signed [W_IQ-1:0] mux_im = mux_to_ifft_data[2*W_IQ-1:W_IQ];

    // IFFT -> CP insertion
    wire signed [W_IQ-1:0] ifft_out_re, ifft_out_im;
    wire        ifft_out_valid;
    wire        ifft_out_last;

    // Pack IFFT output as {Q, I}
    wire [31:0] ifft_out_data = {ifft_out_im, ifft_out_re};

    // =========================================================================
    // 1. LDPC Encoder (rate 1/2, Z=27)
    //    324 info bits -> 648 coded bits
    // =========================================================================
    ldpc_encoder #(
        .Z  (27),
        .MB (12),
        .NB (24)
    ) u_ldpc_encoder (
        .clk      (clk),
        .rst_n    (rst_n),
        .s_tdata  (s_tdata),
        .s_tvalid (s_tvalid),
        .s_tready (s_tready),
        .s_tlast  (s_tlast),
        .m_tdata  (enc_to_qam_data),
        .m_tvalid (enc_to_qam_valid),
        .m_tready (1'b1),           // QAM mapper always accepts bits
        .m_tlast  (enc_to_qam_last),
        .busy     (encoder_busy)
    );

    // =========================================================================
    // 2. QAM Mapper
    //    Coded bits -> complex symbols in Q1.14 format
    // =========================================================================
    qam_mapper u_qam_mapper (
        .clk            (clk),
        .rst_n          (rst_n),
        .bit_in         (enc_to_qam_data),
        .bit_valid      (enc_to_qam_valid),
        .cfg_modulation (cfg_modulation),
        .sym_out        (qam_to_mux_data),
        .sym_valid      (qam_to_mux_valid)
    );

    // =========================================================================
    // 3. Subcarrier Multiplexer
    //    48 data symbols -> 64 frequency bins (pilots + guard bands)
    // =========================================================================
    subcarrier_mux #(
        .FFT_N (FFT_N)
    ) u_subcarrier_mux (
        .clk        (clk),
        .rst_n      (rst_n),
        .data_in    (qam_to_mux_data),
        .data_valid (qam_to_mux_valid),
        .bin_out    (mux_to_ifft_data),
        .bin_valid  (mux_to_ifft_valid),
        .bin_last   (mux_to_ifft_last),
        .bin_first  (mux_to_ifft_first)
    );

    // =========================================================================
    // 4. 64-Point Inverse FFT
    //    Frequency-domain bins -> time-domain samples
    // =========================================================================
    ifft_64pt #(
        .FFT_N (FFT_N),
        .W     (W_IQ),
        .TW    (TW)
    ) u_ifft (
        .clk     (clk),
        .rst_n   (rst_n),
        .s_re    (mux_re),
        .s_im    (mux_im),
        .s_valid (mux_to_ifft_valid),
        .m_re    (ifft_out_re),
        .m_im    (ifft_out_im),
        .m_valid (ifft_out_valid),
        .m_last  (ifft_out_last)
    );

    // =========================================================================
    // 5. Cyclic Prefix Insertion
    //    64 time-domain samples -> 80 samples (CP_LEN=16 prepended)
    // =========================================================================
    cp_insertion #(
        .FFT_N  (FFT_N),
        .CP_LEN (CP_LEN)
    ) u_cp_insertion (
        .clk      (clk),
        .rst_n    (rst_n),
        .s_tdata  (ifft_out_data),
        .s_tvalid (ifft_out_valid),
        .s_tready (),  // IFFT streams continuously, no backpressure
        .m_tdata  (m_tdata),
        .m_tvalid (m_tvalid),
        .m_tready (m_tready),
        .m_tlast  (m_tlast)
    );

endmodule
