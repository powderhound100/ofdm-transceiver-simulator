// =============================================================================
// channel_model_top.sv — Top-level channel model wrapper
// =============================================================================
// Cascades a sparse FIR multipath filter with an AWGN noise generator to
// simulate a wireless channel. Includes profile ROM for predefined channel
// models and bypass muxes for FIR and AWGN stages.
//
// Signal flow:
//   Input IQ → [channel_bypass mux] → FIR filter → [noise_enable mux] → add AWGN → Output IQ
//
// Profile loading FSM:
//   1. Assert load_profile for one cycle
//   2. FSM reads channel_profile_rom taps sequentially
//   3. Each tap is written to channel_fir_sparse via coeff_wen
//   4. num_active_taps is set after all taps are loaded
//   5. FSM returns to idle
//
// Manual coefficient loading is also supported via the coeff_* ports when
// the profile load FSM is idle.
//
// AXI-Stream in/out: 32-bit packed {Q[15:0], I[15:0]}
// =============================================================================

`timescale 1ns / 1ps

module channel_model_top #(
    parameter FIR_VARIANT = "sparse"    // only "sparse" supported for now
)(
    input  logic        clk,
    input  logic        rst_n,

    // AXI-Stream slave — input IQ samples
    input  logic [31:0] s_tdata,        // {Q[15:0], I[15:0]}
    input  logic        s_tvalid,
    output logic        s_tready,
    input  logic        s_tlast,

    // AXI-Stream master — channel-impaired output IQ samples
    output logic [31:0] m_tdata,        // {Q[15:0], I[15:0]}
    output logic        m_tvalid,
    output logic        m_tlast,

    // Profile selection and loading
    input  logic [3:0]  profile_sel,    // 0-9 profile index
    input  logic        load_profile,   // pulse to trigger profile load

    // AWGN configuration
    input  logic [15:0] noise_scale,    // Q8.8 scaling factor
    input  logic        noise_enable,   // enable AWGN addition
    input  logic [63:0] awgn_seed_i,    // LFSR seed for I channel
    input  logic [63:0] awgn_seed_q,    // LFSR seed for Q channel

    // Channel bypass
    input  logic        channel_bypass, // bypass FIR filter entirely

    // Manual coefficient configuration (active when profile load FSM is idle)
    input  logic        coeff_wen,
    input  logic [2:0]  coeff_addr,
    input  logic [7:0]  coeff_delay,
    input  logic signed [15:0] coeff_re,
    input  logic signed [15:0] coeff_im
);

    // =========================================================================
    // Internal wires
    // =========================================================================

    // FIR input/output (after bypass mux)
    logic [31:0] fir_in_tdata;
    logic        fir_in_tvalid;
    logic        fir_in_tready;
    logic        fir_in_tlast;

    logic [31:0] fir_out_tdata;
    logic        fir_out_tvalid;
    logic        fir_out_tlast;

    // Post-FIR data (after channel_bypass mux)
    logic [31:0] post_fir_tdata;
    logic        post_fir_tvalid;
    logic        post_fir_tlast;

    // AWGN noise
    logic signed [15:0] noise_i, noise_q;
    logic        noise_valid;

    // Coefficient write signals (muxed between FSM and manual)
    logic        fir_coeff_wen;
    logic [2:0]  fir_coeff_addr;
    logic [7:0]  fir_coeff_delay;
    logic signed [15:0] fir_coeff_re;
    logic signed [15:0] fir_coeff_im;
    logic [2:0]  fir_num_active_taps;

    // Profile ROM outputs
    logic [2:0]  rom_num_taps;
    logic [7:0]  rom_tap_delay;
    logic signed [15:0] rom_tap_re;
    logic signed [15:0] rom_tap_im;
    logic [2:0]  rom_tap_idx;
    logic        rom_tap_valid;
    logic        rom_load_done;

    // Profile load FSM control
    logic        rom_load_en;

    // =========================================================================
    // Channel Profile ROM
    // =========================================================================
    channel_profile_rom u_profile_rom (
        .clk         (clk),
        .profile_sel (profile_sel),
        .load_en     (rom_load_en),
        .num_taps    (rom_num_taps),
        .tap_delay   (rom_tap_delay),
        .tap_re      (rom_tap_re),
        .tap_im      (rom_tap_im),
        .tap_idx     (rom_tap_idx),
        .tap_valid   (rom_tap_valid),
        .load_done   (rom_load_done)
    );

    // =========================================================================
    // Profile Load FSM
    // =========================================================================
    // States:
    //   PL_IDLE    — waiting for load_profile pulse
    //   PL_START   — issue load_en to ROM
    //   PL_LOADING — ROM outputs taps, we write them to FIR
    //   PL_SET_NUM — write num_active_taps to FIR
    //   PL_DONE    — load complete
    // =========================================================================
    localparam [2:0] PL_IDLE    = 3'd0;
    localparam [2:0] PL_START   = 3'd1;
    localparam [2:0] PL_LOADING = 3'd2;
    localparam [2:0] PL_SET_NUM = 3'd3;
    localparam [2:0] PL_DONE    = 3'd4;

    logic [2:0] pl_state;
    logic        pl_active;         // FSM is actively loading (not idle)
    logic [2:0] pl_num_taps_reg;    // latched num_taps from ROM

    assign pl_active = (pl_state != PL_IDLE);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pl_state        <= PL_IDLE;
            rom_load_en     <= 1'b0;
            pl_num_taps_reg <= 3'd1;
        end else begin
            // Defaults
            rom_load_en <= 1'b0;

            case (pl_state)
                PL_IDLE: begin
                    if (load_profile) begin
                        pl_state <= PL_START;
                    end
                end

                PL_START: begin
                    rom_load_en <= 1'b1;
                    pl_state    <= PL_LOADING;
                end

                PL_LOADING: begin
                    // ROM outputs taps with tap_valid; we forward them to FIR
                    if (rom_tap_valid) begin
                        pl_num_taps_reg <= rom_num_taps;
                    end
                    if (rom_load_done) begin
                        pl_state <= PL_SET_NUM;
                    end
                end

                PL_SET_NUM: begin
                    // One extra cycle to ensure num_active_taps is registered
                    pl_state <= PL_DONE;
                end

                PL_DONE: begin
                    pl_state <= PL_IDLE;
                end

                default: pl_state <= PL_IDLE;
            endcase
        end
    end

    // =========================================================================
    // Coefficient write mux: FSM vs manual
    // =========================================================================
    always_comb begin
        if (pl_active && rom_tap_valid) begin
            // Profile load FSM is writing coefficients from ROM
            fir_coeff_wen   = 1'b1;
            fir_coeff_addr  = rom_tap_idx;
            fir_coeff_delay = rom_tap_delay;
            fir_coeff_re    = rom_tap_re;
            fir_coeff_im    = rom_tap_im;
        end else if (!pl_active) begin
            // Manual coefficient write
            fir_coeff_wen   = coeff_wen;
            fir_coeff_addr  = coeff_addr;
            fir_coeff_delay = coeff_delay;
            fir_coeff_re    = coeff_re;
            fir_coeff_im    = coeff_im;
        end else begin
            fir_coeff_wen   = 1'b0;
            fir_coeff_addr  = 3'd0;
            fir_coeff_delay = 8'd0;
            fir_coeff_re    = 16'sd0;
            fir_coeff_im    = 16'sd0;
        end
    end

    // num_active_taps: updated after profile load completes, or manual override
    logic [2:0] num_active_taps_reg;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            num_active_taps_reg <= 3'd1;
        end else if (pl_state == PL_SET_NUM) begin
            num_active_taps_reg <= pl_num_taps_reg;
        end
    end

    assign fir_num_active_taps = num_active_taps_reg;

    // =========================================================================
    // Channel Bypass Mux (input side)
    // =========================================================================
    // When channel_bypass is active, FIR is not used; input passes through.
    assign fir_in_tdata  = s_tdata;
    assign fir_in_tvalid = channel_bypass ? 1'b0 : s_tvalid;
    assign fir_in_tlast  = s_tlast;
    assign s_tready      = channel_bypass ? 1'b1 : fir_in_tready;

    // Post-FIR mux: bypass or FIR output
    assign post_fir_tdata  = channel_bypass ? s_tdata   : fir_out_tdata;
    assign post_fir_tvalid = channel_bypass ? s_tvalid  : fir_out_tvalid;
    assign post_fir_tlast  = channel_bypass ? s_tlast   : fir_out_tlast;

    // =========================================================================
    // Sparse FIR Filter
    // =========================================================================
    channel_fir_sparse #(
        .NUM_TAPS  (8),
        .MAX_DELAY (255),
        .IQ_W      (16)
    ) u_fir (
        .clk             (clk),
        .rst_n           (rst_n),
        .s_tdata         (fir_in_tdata),
        .s_tvalid        (fir_in_tvalid),
        .s_tready        (fir_in_tready),
        .s_tlast         (fir_in_tlast),
        .m_tdata         (fir_out_tdata),
        .m_tvalid        (fir_out_tvalid),
        .m_tlast         (fir_out_tlast),
        .coeff_wen       (fir_coeff_wen),
        .coeff_addr      (fir_coeff_addr),
        .coeff_delay     (fir_coeff_delay),
        .coeff_re        (fir_coeff_re),
        .coeff_im        (fir_coeff_im),
        .num_active_taps (fir_num_active_taps)
    );

    // =========================================================================
    // AWGN Generator
    // =========================================================================
    awgn_generator u_awgn (
        .clk         (clk),
        .rst_n       (rst_n),
        .enable      (noise_enable),
        .seed_i      (awgn_seed_i),
        .seed_q      (awgn_seed_q),
        .noise_scale (noise_scale),
        .noise_i     (noise_i),
        .noise_q     (noise_q),
        .noise_valid (noise_valid)
    );

    // =========================================================================
    // Noise Addition Stage
    // =========================================================================
    // Add AWGN noise to post-FIR signal when noise_enable is active.
    // Uses registered addition with saturation to prevent overflow.
    //
    // Pipeline: post_fir_tdata is held in a register until a noise sample
    // is available. If noise is disabled, data passes through with 1-cycle
    // latency.
    // =========================================================================
    logic [31:0] held_data;
    logic        held_valid;
    logic        held_last;
    logic        waiting_for_noise;

    // Signed extraction helpers
    logic signed [15:0] sig_i, sig_q;
    logic signed [16:0] sum_i, sum_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            m_tdata          <= 32'd0;
            m_tvalid         <= 1'b0;
            m_tlast          <= 1'b0;
            held_data        <= 32'd0;
            held_valid       <= 1'b0;
            held_last        <= 1'b0;
            waiting_for_noise <= 1'b0;
        end else begin
            // Default: deassert output valid
            m_tvalid <= 1'b0;
            m_tlast  <= 1'b0;

            if (post_fir_tvalid) begin
                if (noise_enable) begin
                    // Hold the sample and wait for noise
                    held_data         <= post_fir_tdata;
                    held_valid        <= 1'b1;
                    held_last         <= post_fir_tlast;
                    waiting_for_noise <= 1'b1;
                end else begin
                    // No noise — pass through with 1-cycle latency
                    m_tdata  <= post_fir_tdata;
                    m_tvalid <= 1'b1;
                    m_tlast  <= post_fir_tlast;
                end
            end

            // When noise sample arrives and we have data waiting
            if (waiting_for_noise && noise_valid && held_valid) begin
                sig_i = $signed(held_data[15:0]);
                sig_q = $signed(held_data[31:16]);

                // 17-bit addition for overflow detection
                sum_i = {sig_i[15], sig_i} + {noise_i[15], noise_i};
                sum_q = {sig_q[15], sig_q} + {noise_q[15], noise_q};

                // Saturate to 16 bits
                m_tdata  <= {sat16(sum_q), sat16(sum_i)};
                m_tvalid <= 1'b1;
                m_tlast  <= held_last;

                held_valid        <= 1'b0;
                waiting_for_noise <= 1'b0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // 17-bit to 16-bit signed saturation
    // -------------------------------------------------------------------------
    function logic [15:0] sat16;
        input logic signed [16:0] val;
        begin
            if (val > 17'sd32767)
                sat16 = 16'h7FFF;
            else if (val < -17'sd32768)
                sat16 = 16'h8000;
            else
                sat16 = val[15:0];
        end
    endfunction

endmodule
