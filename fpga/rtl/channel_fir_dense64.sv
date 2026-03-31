// =============================================================================
// channel_fir_dense64.sv — 64-tap Dense FIR filter (semi-parallel, 4 taps/cycle)
// =============================================================================
// Implements a 64-tap consecutive-delay complex FIR filter for channel modeling.
// Semi-parallel processing: 4 complex taps per clock cycle × 16 cycles = 64 taps.
// Uses BRAM-based delay line (64 × 32-bit).
//
// Complex multiply per tap:
//   out_re = x_re * c_re - x_im * c_im
//   out_im = x_re * c_im + x_im * c_re
//
// DSP usage: 16 DSP48E1 equivalent (4 real multiplies × 4 parallel taps).
// Accumulator: 40-bit signed for I and Q channels.
// Coefficients: Q1.14 fixed-point (1 sign, 1 integer, 14 fractional bits).
//
// AXI-Stream interfaces with backpressure support.
// =============================================================================

`timescale 1ns / 1ps

module channel_fir_dense64 #(
    parameter int NUM_TAPS = 64,
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
    input  logic [5:0]  coeff_addr,     // tap index 0..63
    input  logic signed [15:0] coeff_re, // Q1.14 real coefficient
    input  logic signed [15:0] coeff_im  // Q1.14 imaginary coefficient
);

    // -------------------------------------------------------------------------
    // Coefficient storage — 64 complex taps
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
    // BRAM delay line — 64 × 32-bit
    // Implemented as a simple memory array; synthesis tool infers BRAM.
    // We use a write pointer and read by computed index (circular buffer).
    // -------------------------------------------------------------------------
    logic [31:0] delay_mem [0:NUM_TAPS-1];
    logic [5:0]  write_ptr;

    // -------------------------------------------------------------------------
    // FSM states
    // -------------------------------------------------------------------------
    localparam [2:0] ST_IDLE    = 3'd0;
    localparam [2:0] ST_WRITE   = 3'd1;
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

    // 4 parallel tap lanes (a, b, c, d)
    // Tap index for lane j at cycle i: 4*i + j
    logic [5:0] tap_idx_a, tap_idx_b, tap_idx_c, tap_idx_d;
    logic [5:0] dl_idx_a,  dl_idx_b,  dl_idx_c,  dl_idx_d;

    // Delay-line samples
    logic signed [IQ_W-1:0] xa_re, xa_im, xb_re, xb_im;
    logic signed [IQ_W-1:0] xc_re, xc_im, xd_re, xd_im;

    // Coefficients
    logic signed [IQ_W-1:0] ca_re, ca_im, cb_re, cb_im;
    logic signed [IQ_W-1:0] cc_re, cc_im, cd_re, cd_im;

    // Multiply products — 4 lanes × 4 real multiplies each
    logic signed [31:0] mul_a_rr, mul_a_ii, mul_a_ri, mul_a_ir;
    logic signed [31:0] mul_b_rr, mul_b_ii, mul_b_ri, mul_b_ir;
    logic signed [31:0] mul_c_rr, mul_c_ii, mul_c_ri, mul_c_ir;
    logic signed [31:0] mul_d_rr, mul_d_ii, mul_d_ri, mul_d_ir;

    // Per-lane complex MAC results
    logic signed [39:0] mac_a_re, mac_a_im, mac_b_re, mac_b_im;
    logic signed [39:0] mac_c_re, mac_c_im, mac_d_re, mac_d_im;

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
            write_ptr <= 6'd0;
            cycle_cnt <= 4'd0;
            acc_re    <= 40'sd0;
            acc_im    <= 40'sd0;
            in_sample <= 32'd0;
            in_last   <= 1'b0;
            m_tdata   <= 32'd0;
            m_tvalid  <= 1'b0;
            m_tlast   <= 1'b0;
        end else begin
            m_tvalid <= 1'b0;
            m_tlast  <= 1'b0;

            case (state)
                // ---------------------------------------------------------
                ST_IDLE: begin
                    if (s_tvalid) begin
                        in_sample <= s_tdata;
                        in_last   <= s_tlast;
                        state     <= ST_WRITE;
                    end
                end

                // ---------------------------------------------------------
                // Write sample into BRAM delay line at write_ptr
                // ---------------------------------------------------------
                ST_WRITE: begin
                    delay_mem[write_ptr] <= in_sample;
                    cycle_cnt <= 4'd0;
                    acc_re    <= 40'sd0;
                    acc_im    <= 40'sd0;
                    state     <= ST_COMPUTE;
                end

                // ---------------------------------------------------------
                // COMPUTE: process 4 taps per cycle for 16 cycles
                // Tap n is convolved with delay_line[(write_ptr - n) mod 64].
                // ---------------------------------------------------------
                ST_COMPUTE: begin
                    // Tap indices for 4 parallel lanes
                    tap_idx_a = {cycle_cnt, 2'b00};  // 4*cycle_cnt + 0
                    tap_idx_b = {cycle_cnt, 2'b01};  // 4*cycle_cnt + 1
                    tap_idx_c = {cycle_cnt, 2'b10};  // 4*cycle_cnt + 2
                    tap_idx_d = {cycle_cnt, 2'b11};  // 4*cycle_cnt + 3

                    // Delay line read addresses (circular)
                    dl_idx_a = write_ptr - tap_idx_a;
                    dl_idx_b = write_ptr - tap_idx_b;
                    dl_idx_c = write_ptr - tap_idx_c;
                    dl_idx_d = write_ptr - tap_idx_d;

                    // Extract I/Q from delay line — lane A
                    xa_re = $signed(delay_mem[dl_idx_a][15:0]);
                    xa_im = $signed(delay_mem[dl_idx_a][31:16]);
                    ca_re = tap_coeff_re[tap_idx_a];
                    ca_im = tap_coeff_im[tap_idx_a];

                    // Lane B
                    xb_re = $signed(delay_mem[dl_idx_b][15:0]);
                    xb_im = $signed(delay_mem[dl_idx_b][31:16]);
                    cb_re = tap_coeff_re[tap_idx_b];
                    cb_im = tap_coeff_im[tap_idx_b];

                    // Lane C
                    xc_re = $signed(delay_mem[dl_idx_c][15:0]);
                    xc_im = $signed(delay_mem[dl_idx_c][31:16]);
                    cc_re = tap_coeff_re[tap_idx_c];
                    cc_im = tap_coeff_im[tap_idx_c];

                    // Lane D
                    xd_re = $signed(delay_mem[dl_idx_d][15:0]);
                    xd_im = $signed(delay_mem[dl_idx_d][31:16]);
                    cd_re = tap_coeff_re[tap_idx_d];
                    cd_im = tap_coeff_im[tap_idx_d];

                    // Complex multiply — lane A
                    mul_a_rr = xa_re * ca_re;
                    mul_a_ii = xa_im * ca_im;
                    mul_a_ri = xa_re * ca_im;
                    mul_a_ir = xa_im * ca_re;
                    mac_a_re = {{8{mul_a_rr[31]}}, mul_a_rr} - {{8{mul_a_ii[31]}}, mul_a_ii};
                    mac_a_im = {{8{mul_a_ri[31]}}, mul_a_ri} + {{8{mul_a_ir[31]}}, mul_a_ir};

                    // Complex multiply — lane B
                    mul_b_rr = xb_re * cb_re;
                    mul_b_ii = xb_im * cb_im;
                    mul_b_ri = xb_re * cb_im;
                    mul_b_ir = xb_im * cb_re;
                    mac_b_re = {{8{mul_b_rr[31]}}, mul_b_rr} - {{8{mul_b_ii[31]}}, mul_b_ii};
                    mac_b_im = {{8{mul_b_ri[31]}}, mul_b_ri} + {{8{mul_b_ir[31]}}, mul_b_ir};

                    // Complex multiply — lane C
                    mul_c_rr = xc_re * cc_re;
                    mul_c_ii = xc_im * cc_im;
                    mul_c_ri = xc_re * cc_im;
                    mul_c_ir = xc_im * cc_re;
                    mac_c_re = {{8{mul_c_rr[31]}}, mul_c_rr} - {{8{mul_c_ii[31]}}, mul_c_ii};
                    mac_c_im = {{8{mul_c_ri[31]}}, mul_c_ri} + {{8{mul_c_ir[31]}}, mul_c_ir};

                    // Complex multiply — lane D
                    mul_d_rr = xd_re * cd_re;
                    mul_d_ii = xd_im * cd_im;
                    mul_d_ri = xd_re * cd_im;
                    mul_d_ir = xd_im * cd_re;
                    mac_d_re = {{8{mul_d_rr[31]}}, mul_d_rr} - {{8{mul_d_ii[31]}}, mul_d_ii};
                    mac_d_im = {{8{mul_d_ri[31]}}, mul_d_ri} + {{8{mul_d_ir[31]}}, mul_d_ir};

                    // Accumulate all 4 lanes
                    acc_re <= acc_re + mac_a_re + mac_b_re + mac_c_re + mac_d_re;
                    acc_im <= acc_im + mac_a_im + mac_b_im + mac_c_im + mac_d_im;

                    if (cycle_cnt == 4'd15) begin
                        state <= ST_OUTPUT;
                    end else begin
                        cycle_cnt <= cycle_cnt + 4'd1;
                    end
                end

                // ---------------------------------------------------------
                // OUTPUT: truncate/saturate 40-bit accumulator to 16-bit
                // ---------------------------------------------------------
                ST_OUTPUT: begin
                    m_tdata  <= {saturate_16(acc_im >>> 14), saturate_16(acc_re >>> 14)};
                    m_tvalid <= 1'b1;
                    m_tlast  <= in_last;
                    write_ptr <= write_ptr + 6'd1;
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
