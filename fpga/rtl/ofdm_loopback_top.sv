// =============================================================================
// ofdm_loopback_top.sv — Full OFDM TX -> Channel -> RX -> LDPC Loopback
// =============================================================================
// Connects the complete OFDM transmit/receive chain for BER testing:
//
//   info_bits -> ofdm_tx_top -> channel_model_top -> ofdm_rx_top -> ldpc_top
//                                                                    |
//                                                              BER comparator
//
// BER counter compares decoded bits vs original info bits.
//
// Config registers:
//   - cfg_modulation: QPSK/16QAM/64QAM
//   - profile_sel: channel profile (FIR tap set)
//   - noise_scale: AWGN noise level (Q8.8)
//   - noise_enable: enable/disable AWGN
//   - eq_mode: equalizer mode (0=ZF, 1=MMSE)
//   - cfg_estimator: channel estimator type (0=LS, 1=LS-Improved, 2=LMMSE)
//
// Interface:
//   start -> begins test, latches info bits and streams through chain
//   ber_count -> number of bit errors detected
//   frame_count -> number of frames processed
//   test_done -> asserted when one frame comparison is complete
// =============================================================================
`timescale 1ns / 1ps

module ofdm_loopback_top #(
    parameter integer FFT_N    = 64,
    parameter integer CP_LEN   = 16,
    parameter integer W_IQ     = 16,
    parameter integer TW       = 12,
    parameter integer LLR_W    = 6,
    parameter integer Z        = 27,
    parameter integer MB       = 12,
    parameter integer NB       = 24,
    parameter integer K        = 324,   // info bits per frame (MB * Z)
    parameter integer N_CW     = 648    // codeword bits (NB * Z)
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---- Test control ----
    input  wire        start,           // pulse to begin one frame test

    // ---- Info bits input (serial, 1 bit/clock) ----
    input  wire        info_bit_in,
    input  wire        info_bit_valid,

    // ---- Configuration ----
    input  wire [3:0]  cfg_modulation,  // 0=QPSK, 1=16QAM, 2=64QAM
    input  wire [3:0]  profile_sel,     // channel profile index
    input  wire        load_profile,    // pulse to load new channel profile
    input  wire [15:0] noise_scale,     // Q8.8 AWGN noise level
    input  wire        noise_enable,    // enable AWGN
    input  wire        channel_bypass,  // bypass FIR channel
    input  wire        eq_mode,         // 0=ZF, 1=MMSE
    input  wire [1:0]  cfg_estimator,   // 0=LS, 1=LS-Improved, 2=LMMSE
    input  wire [15:0] noise_var,       // Q8.8 noise variance for equalizer

    // ---- LFSR seeds for AWGN ----
    input  wire [63:0] awgn_seed_i,
    input  wire [63:0] awgn_seed_q,

    // ---- BER results ----
    output reg  [31:0] ber_count,       // number of bit errors
    output reg  [31:0] frame_count,     // number of frames processed
    output reg         test_done        // asserted when comparison complete
);

    // =========================================================================
    // FSM for test control
    // =========================================================================
    localparam [2:0] LB_IDLE     = 3'd0;
    localparam [2:0] LB_LOAD     = 3'd1;  // load info bits
    localparam [2:0] LB_TX       = 3'd2;  // TX processing
    localparam [2:0] LB_WAIT_RX  = 3'd3;  // wait for RX + decoder
    localparam [2:0] LB_COMPARE  = 3'd4;  // compare decoded vs original

    reg [2:0] lb_state;

    // =========================================================================
    // Info bits reference storage (for BER comparison)
    // =========================================================================
    reg [K-1:0] info_ref;          // stored copy of transmitted info bits
    reg [9:0]   info_load_cnt;     // counter for loading info bits

    // =========================================================================
    // TX input wiring
    // =========================================================================
    reg         tx_info_bit;
    reg         tx_info_valid;
    reg         tx_info_last;
    wire        tx_ready;

    // =========================================================================
    // Inter-module wires
    // =========================================================================

    // TX -> Channel
    wire [31:0] tx_to_ch_data;
    wire        tx_to_ch_valid;
    wire        tx_to_ch_ready;
    wire        tx_to_ch_last;
    wire        tx_encoder_busy;

    // Channel -> RX
    wire [31:0] ch_to_rx_data;
    wire        ch_to_rx_valid;
    wire        ch_to_rx_last;

    // RX -> LDPC decoder
    wire [LLR_W-1:0] rx_to_dec_data;
    wire              rx_to_dec_valid;
    wire              rx_to_dec_last;
    wire              rx_to_dec_ready;
    wire              rx_frame_ready;

    // LDPC decoder -> BER comparator
    wire        dec_bit_out;
    wire        dec_bit_valid;
    wire        dec_bit_ready;
    wire        dec_bit_last;
    wire        dec_busy;
    wire        dec_done;
    wire        dec_converged;
    wire [5:0]  dec_iterations;

    // =========================================================================
    // 1. OFDM Transmitter
    // =========================================================================
    ofdm_tx_top #(
        .FFT_N  (FFT_N),
        .CP_LEN (CP_LEN),
        .W_IQ   (W_IQ),
        .TW     (TW)
    ) u_ofdm_tx (
        .clk            (clk),
        .rst_n          (rst_n),
        .s_tdata        (tx_info_bit),
        .s_tvalid       (tx_info_valid),
        .s_tready       (tx_ready),
        .s_tlast        (tx_info_last),
        .m_tdata        (tx_to_ch_data),
        .m_tvalid       (tx_to_ch_valid),
        .m_tready       (tx_to_ch_ready),
        .m_tlast        (tx_to_ch_last),
        .cfg_modulation (cfg_modulation),
        .encoder_busy   (tx_encoder_busy)
    );

    // =========================================================================
    // 2. Channel Model (FIR + AWGN)
    // =========================================================================
    channel_model_top u_channel (
        .clk            (clk),
        .rst_n          (rst_n),
        .s_tdata        (tx_to_ch_data),
        .s_tvalid       (tx_to_ch_valid),
        .s_tready       (tx_to_ch_ready),
        .s_tlast        (tx_to_ch_last),
        .m_tdata        (ch_to_rx_data),
        .m_tvalid       (ch_to_rx_valid),
        .m_tlast        (ch_to_rx_last),
        .profile_sel    (profile_sel),
        .load_profile   (load_profile),
        .noise_scale    (noise_scale),
        .noise_enable   (noise_enable),
        .awgn_seed_i    (awgn_seed_i),
        .awgn_seed_q    (awgn_seed_q),
        .channel_bypass (channel_bypass),
        .coeff_wen      (1'b0),
        .coeff_addr     (3'd0),
        .coeff_delay    (8'd0),
        .coeff_re       (16'sd0),
        .coeff_im       (16'sd0)
    );

    // =========================================================================
    // 3. OFDM Receiver
    // =========================================================================
    ofdm_rx_top #(
        .FFT_N  (FFT_N),
        .CP_LEN (CP_LEN),
        .W_IQ   (W_IQ),
        .TW     (TW),
        .LLR_W  (LLR_W)
    ) u_ofdm_rx (
        .clk            (clk),
        .rst_n          (rst_n),
        .s_tdata        (ch_to_rx_data),
        .s_tvalid       (ch_to_rx_valid),
        .s_tready       (),  // Channel model has no backpressure
        .m_tdata        (rx_to_dec_data),
        .m_tvalid       (rx_to_dec_valid),
        .m_tlast        (rx_to_dec_last),
        .m_tready       (rx_to_dec_ready),
        .cfg_modulation (cfg_modulation),
        .noise_var      (noise_var),
        .eq_mode        (eq_mode),
        .cfg_estimator  (cfg_estimator),
        .frame_ready    (rx_frame_ready)
    );

    // =========================================================================
    // 4. LDPC Decoder
    // =========================================================================
    ldpc_top #(
        .Z        (Z),
        .W        (LLR_W),
        .MB       (MB),
        .NB       (NB),
        .MAX_ITER (20),
        .MAX_DEG  (20)
    ) u_ldpc_dec (
        .clk              (clk),
        .rst_n            (rst_n),
        .s_tdata          (rx_to_dec_data),
        .s_tvalid         (rx_to_dec_valid),
        .s_tready         (rx_to_dec_ready),
        .s_tlast          (rx_to_dec_last),
        .m_tdata          (dec_bit_out),
        .m_tvalid         (dec_bit_valid),
        .m_tready         (dec_bit_ready),
        .m_tlast          (dec_bit_last),
        .busy             (dec_busy),
        .decode_done      (dec_done),
        .decode_converged (dec_converged),
        .decode_iterations(dec_iterations)
    );

    // Always accept decoded bits (we compare them as they arrive)
    assign dec_bit_ready = 1'b1;

    // =========================================================================
    // 5. BER Comparator
    // =========================================================================
    // Compare first K=324 decoded bits against stored reference info bits
    // (The decoder outputs N_CW=648 bits; we only compare the first K=324)
    reg [9:0] compare_cnt;

    // =========================================================================
    // Main FSM
    // =========================================================================
    reg [9:0] tx_bit_cnt;   // counter for streaming info bits to TX

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lb_state       <= LB_IDLE;
            info_load_cnt  <= 10'd0;
            tx_bit_cnt     <= 10'd0;
            compare_cnt    <= 10'd0;
            ber_count      <= 32'd0;
            frame_count    <= 32'd0;
            test_done      <= 1'b0;
            tx_info_bit    <= 1'b0;
            tx_info_valid  <= 1'b0;
            tx_info_last   <= 1'b0;
            info_ref       <= {K{1'b0}};
        end else begin
            // Defaults
            test_done     <= 1'b0;
            tx_info_valid <= 1'b0;
            tx_info_last  <= 1'b0;

            case (lb_state)
                // =============================================================
                // IDLE: wait for start pulse
                // =============================================================
                LB_IDLE: begin
                    if (start) begin
                        lb_state      <= LB_LOAD;
                        info_load_cnt <= 10'd0;
                        ber_count     <= 32'd0;
                    end
                end

                // =============================================================
                // LOAD: capture info bits into reference storage
                // =============================================================
                LB_LOAD: begin
                    if (info_bit_valid) begin
                        info_ref[info_load_cnt] <= info_bit_in;

                        if (info_load_cnt == K - 1) begin
                            lb_state   <= LB_TX;
                            tx_bit_cnt <= 10'd0;
                        end else begin
                            info_load_cnt <= info_load_cnt + 10'd1;
                        end
                    end
                end

                // =============================================================
                // TX: stream info bits to OFDM TX
                // =============================================================
                LB_TX: begin
                    if (tx_ready) begin
                        tx_info_bit   <= info_ref[tx_bit_cnt];
                        tx_info_valid <= 1'b1;

                        if (tx_bit_cnt == K - 1) begin
                            tx_info_last <= 1'b1;
                            lb_state     <= LB_WAIT_RX;
                            compare_cnt  <= 10'd0;
                        end else begin
                            tx_bit_cnt <= tx_bit_cnt + 10'd1;
                        end
                    end
                end

                // =============================================================
                // WAIT_RX: wait for decoder output and compare bits
                // =============================================================
                LB_WAIT_RX: begin
                    if (dec_bit_valid) begin
                        // Only compare the first K information bits
                        if (compare_cnt < K) begin
                            if (dec_bit_out != info_ref[compare_cnt])
                                ber_count <= ber_count + 32'd1;
                        end

                        compare_cnt <= compare_cnt + 10'd1;

                        // Check if all decoded bits have been output
                        if (dec_bit_last || compare_cnt == N_CW - 1) begin
                            lb_state    <= LB_COMPARE;
                        end
                    end
                end

                // =============================================================
                // COMPARE: frame complete, update counters
                // =============================================================
                LB_COMPARE: begin
                    frame_count <= frame_count + 32'd1;
                    test_done   <= 1'b1;
                    lb_state    <= LB_IDLE;
                end

                default: lb_state <= LB_IDLE;
            endcase
        end
    end

endmodule
