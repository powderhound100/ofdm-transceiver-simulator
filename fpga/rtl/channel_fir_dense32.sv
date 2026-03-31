// =============================================================================
// channel_fir_dense32.sv — 32-tap Dense FIR filter (semi-parallel, 2 taps/cycle)
// =============================================================================
// Implements a 32-tap consecutive-delay complex FIR filter for channel modeling.
// Transposed architecture with semi-parallel processing: 2 complex taps per
// clock cycle × 16 cycles = 32 taps. Uses register-based delay line.
//
// Complex multiply per tap:
//   out_re = x_re * c_re - x_im * c_im
//   out_im = x_re * c_im + x_im * c_re
//
// DSP usage: 8 DSP48E1 equivalent (4 real multiplies × 2 parallel taps).
// Accumulator: 40-bit signed for I and Q channels.
// Coefficients: Q1.14 fixed-point (1 sign, 1 integer, 14 fractional bits).
//
// AXI-Stream interfaces with backpressure support.
// =============================================================================

`timescale 1ns / 1ps

module channel_fir_dense32 #(
    parameter int NUM_TAPS = 32,
    parameter int IQ_W     = 16
)(
    input  logic        clk,
    input  logic        rst_n,

    // AXI-Stream slave — input IQ samples
    input  logic [31:0] s_tdata,    // {Q[15:0], I[15:0]}
    input  logic        s_tvalid,
    output logic        s_tready,
    input  logic        s_tlast,

    // AXI-Stream master — filtered output IQ samples
    output logic [31:0] m_tdata,    // {Q[15:0], I[15:0]}
    output logic        m_tvalid,
    output logic        m_tlast,

    // Tap count (unused for dense — always uses full NUM_TAPS)
    input  logic [2:0]  num_taps,

    // Coefficient loading interface
    input  logic        coeff_wen,
    input  logic [4:0]  coeff_addr,     // tap index 0..31
    input  logic signed [15:0] coeff_re, // Q1.14 real coefficient
    input  logic signed [15:0] coeff_im  // Q1.14 imaginary coefficient
);

    // -------------------------------------------------------------------------
    // Coefficient storage — 32 complex taps
    // -------------------------------------------------------------------------
    logic signed [15:0] tap_coeff_re [0:NUM_TAPS-1];
    logic signed [15:0] tap_coeff_im [0:NUM_TAPS-1];

    integer k;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (k = 0; k < NUM_TAPS; k = k + 1) begin
                tap_coeff_re[k] <= 16'sd0;
                tap_coeff_im[k] <= 16'sd0;
            end
        end else if (coeff_wen) begin
            tap_coeff_re[coeff_addr] <= coeff_re;
            tap_coeff_im[coeff_addr] <= coeff_im;
        end
    end

    // -------------------------------------------------------------------------
    // Register-based delay line — 32 × 32-bit
    // -------------------------------------------------------------------------
    logic [31:0] delay_line [0:NUM_TAPS-1];

    // -------------------------------------------------------------------------
    // FSM states
    // -------------------------------------------------------------------------
    localparam [2:0] ST_IDLE    = 3'd0;
    localparam [2:0] ST_SHIFT   = 3'd1;
    localparam [2:0] ST_COMPUTE = 3'd2;
    localparam [2:0] ST_OUTPUT  = 3'd3;

    logic [2:0]  state;
    logic [3:0]  cycle_cnt;     // 0..15 — iteration counter (16 cycles)

    // Input sample registers
    logic [31:0] in_sample;
    logic        in_last;

    // 40-bit accumulators for I and Q
    logic signed [39:0] acc_re;
    logic signed [39:0] acc_im;

    // Parallel tap indices: 2 taps per cycle
    // cycle_cnt i → tap indices 2*i and 2*i+1
    logic [4:0] tap_idx_a, tap_idx_b;

    // Delay-line samples for parallel taps
    logic signed [IQ_W-1:0] xa_re, xa_im;
    logic signed [IQ_W-1:0] xb_re, xb_im;

    // Coefficients for parallel taps
    logic signed [IQ_W-1:0] ca_re, ca_im;
    logic signed [IQ_W-1:0] cb_re, cb_im;

    // Multiply products — tap A (4 real multiplies)
    logic signed [31:0] mul_a_rr, mul_a_ii, mul_a_ri, mul_a_ir;
    // Multiply products — tap B (4 real multiplies)
    logic signed [31:0] mul_b_rr, mul_b_ii, mul_b_ri, mul_b_ir;

    // Complex MAC partial results
    logic signed [39:0] mac_a_re, mac_a_im;
    logic signed [39:0] mac_b_re, mac_b_im;

    // -------------------------------------------------------------------------
    // s_tready: accept new samples only in IDLE
    // -------------------------------------------------------------------------
    assign s_tready = (state == ST_IDLE);

    // -------------------------------------------------------------------------
    // Main FSM
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state     <= ST_IDLE;
            cycle_cnt <= 4'd0;
            acc_re    <= 40'sd0;
            acc_im    <= 40'sd0;
            in_sample <= 32'd0;
            in_last   <= 1'b0;
            m_tdata   <= 32'd0;
            m_tvalid  <= 1'b0;
            m_tlast   <= 1'b0;
            for (k = 0; k < NUM_TAPS; k = k + 1) begin
                delay_line[k] <= 32'd0;
            end
        end else begin
            // Default: clear output valid after one cycle
            m_tvalid <= 1'b0;
            m_tlast  <= 1'b0;

            case (state)
                // ---------------------------------------------------------
                ST_IDLE: begin
                    if (s_tvalid) begin
                        in_sample <= s_tdata;
                        in_last   <= s_tlast;
                        state     <= ST_SHIFT;
                    end
                end

                // ---------------------------------------------------------
                // Shift delay line: new sample enters position 0,
                // all others shift up by 1
                // ---------------------------------------------------------
                ST_SHIFT: begin
                    delay_line[0] <= in_sample;
                    for (k = 1; k < NUM_TAPS; k = k + 1) begin
                        delay_line[k] <= delay_line[k-1];
                    end
                    cycle_cnt <= 4'd0;
                    acc_re    <= 40'sd0;
                    acc_im    <= 40'sd0;
                    state     <= ST_COMPUTE;
                end

                // ---------------------------------------------------------
                // COMPUTE: process 2 taps per cycle for 16 cycles
                // ---------------------------------------------------------
                ST_COMPUTE: begin
                    // Tap indices for this cycle
                    tap_idx_a = {cycle_cnt, 1'b0};       // 2 * cycle_cnt
                    tap_idx_b = {cycle_cnt, 1'b1};       // 2 * cycle_cnt + 1

                    // Extract I/Q from delay line
                    xa_re = $signed(delay_line[tap_idx_a][15:0]);
                    xa_im = $signed(delay_line[tap_idx_a][31:16]);
                    xb_re = $signed(delay_line[tap_idx_b][15:0]);
                    xb_im = $signed(delay_line[tap_idx_b][31:16]);

                    // Fetch coefficients
                    ca_re = tap_coeff_re[tap_idx_a];
                    ca_im = tap_coeff_im[tap_idx_a];
                    cb_re = tap_coeff_re[tap_idx_b];
                    cb_im = tap_coeff_im[tap_idx_b];

                    // Complex multiply — tap A
                    mul_a_rr = xa_re * ca_re;
                    mul_a_ii = xa_im * ca_im;
                    mul_a_ri = xa_re * ca_im;
                    mul_a_ir = xa_im * ca_re;
                    mac_a_re = {{8{mul_a_rr[31]}}, mul_a_rr} - {{8{mul_a_ii[31]}}, mul_a_ii};
                    mac_a_im = {{8{mul_a_ri[31]}}, mul_a_ri} + {{8{mul_a_ir[31]}}, mul_a_ir};

                    // Complex multiply — tap B
                    mul_b_rr = xb_re * cb_re;
                    mul_b_ii = xb_im * cb_im;
                    mul_b_ri = xb_re * cb_im;
                    mul_b_ir = xb_im * cb_re;
                    mac_b_re = {{8{mul_b_rr[31]}}, mul_b_rr} - {{8{mul_b_ii[31]}}, mul_b_ii};
                    mac_b_im = {{8{mul_b_ri[31]}}, mul_b_ri} + {{8{mul_b_ir[31]}}, mul_b_ir};

                    // Accumulate both taps
                    acc_re <= acc_re + mac_a_re + mac_b_re;
                    acc_im <= acc_im + mac_a_im + mac_b_im;

                    if (cycle_cnt == 4'd15) begin
                        state <= ST_OUTPUT;
                    end else begin
                        cycle_cnt <= cycle_cnt + 4'd1;
                    end
                end

                // ---------------------------------------------------------
                // OUTPUT: truncate 40-bit accumulator to 16-bit with saturation
                // Accumulated value is Q2.28; shift right by 14 → Q2.14 range,
                // then saturate to 16-bit Q1.0.
                // ---------------------------------------------------------
                ST_OUTPUT: begin
                    m_tdata  <= {saturate_16(acc_im >>> 14), saturate_16(acc_re >>> 14)};
                    m_tvalid <= 1'b1;
                    m_tlast  <= in_last;
                    state    <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Saturation: 40-bit signed → 16-bit signed with clamp
    // -------------------------------------------------------------------------
    function logic signed [15:0] saturate_16;
        input logic signed [39:0] val;
        begin
            if (val > 40'sd32767)
                saturate_16 = 16'sd32767;
            else if (val < -40'sd32768)
                saturate_16 = -16'sd32768;
            else
                saturate_16 = val[15:0];
        end
    endfunction

endmodule
