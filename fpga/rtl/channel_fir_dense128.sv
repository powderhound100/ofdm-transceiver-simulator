// =============================================================================
// channel_fir_dense128.sv — 128-tap Dense FIR filter (semi-parallel, 8 taps/cycle)
// =============================================================================
// Implements a 128-tap consecutive-delay complex FIR filter for channel modeling.
// Semi-parallel processing: 8 complex taps per clock cycle × 16 cycles = 128 taps.
// Uses BRAM-based delay line (128 × 32-bit).
//
// Complex multiply per tap:
//   out_re = x_re * c_re - x_im * c_im
//   out_im = x_re * c_im + x_im * c_re
//
// DSP usage: 32 DSP48E1 equivalent (4 real multiplies × 8 parallel taps).
// Accumulator: 40-bit signed for I and Q channels.
// Coefficients: Q1.14 fixed-point (1 sign, 1 integer, 14 fractional bits).
//
// AXI-Stream interfaces with backpressure support.
// =============================================================================

`timescale 1ns / 1ps

module channel_fir_dense128 #(
    parameter int NUM_TAPS   = 128,
    parameter int PAR_TAPS   = 8,       // parallel taps per cycle
    parameter int NUM_CYCLES = 16,      // NUM_TAPS / PAR_TAPS
    parameter int IQ_W       = 16
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
    input  logic [6:0]  coeff_addr,     // tap index 0..127
    input  logic signed [15:0] coeff_re, // Q1.14 real coefficient
    input  logic signed [15:0] coeff_im  // Q1.14 imaginary coefficient
);

    // -------------------------------------------------------------------------
    // Coefficient storage — 128 complex taps
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
    // BRAM delay line — 128 × 32-bit circular buffer
    // -------------------------------------------------------------------------
    logic [31:0] delay_mem [0:NUM_TAPS-1];
    logic [6:0]  write_ptr;

    // -------------------------------------------------------------------------
    // FSM states
    // -------------------------------------------------------------------------
    localparam [2:0] ST_IDLE    = 3'd0;
    localparam [2:0] ST_WRITE   = 3'd1;
    localparam [2:0] ST_COMPUTE = 3'd2;
    localparam [2:0] ST_OUTPUT  = 3'd3;

    logic [2:0]  state;
    logic [3:0]  cycle_cnt;     // 0..15

    // Input sample registers
    logic [31:0] in_sample;
    logic        in_last;

    // 40-bit accumulators for I and Q
    logic signed [39:0] acc_re;
    logic signed [39:0] acc_im;

    // -------------------------------------------------------------------------
    // Parallel MAC lane signals — 8 lanes (indices 0..7)
    // -------------------------------------------------------------------------
    logic [6:0] tap_idx  [0:PAR_TAPS-1];
    logic [6:0] dl_idx   [0:PAR_TAPS-1];

    logic signed [IQ_W-1:0] x_re [0:PAR_TAPS-1];
    logic signed [IQ_W-1:0] x_im [0:PAR_TAPS-1];
    logic signed [IQ_W-1:0] c_re [0:PAR_TAPS-1];
    logic signed [IQ_W-1:0] c_im [0:PAR_TAPS-1];

    logic signed [31:0] mul_rr [0:PAR_TAPS-1];
    logic signed [31:0] mul_ii [0:PAR_TAPS-1];
    logic signed [31:0] mul_ri [0:PAR_TAPS-1];
    logic signed [31:0] mul_ir [0:PAR_TAPS-1];

    logic signed [39:0] mac_re [0:PAR_TAPS-1];
    logic signed [39:0] mac_im [0:PAR_TAPS-1];

    // Sum tree for 8 lanes
    logic signed [39:0] sum_re, sum_im;

    // -------------------------------------------------------------------------
    // s_tready: accept new samples only in IDLE
    // -------------------------------------------------------------------------
    assign s_tready = (state == ST_IDLE);

    // -------------------------------------------------------------------------
    // Combinational: compute parallel MACs and sum tree
    // -------------------------------------------------------------------------
    integer j;
    always_comb begin
        sum_re = 40'sd0;
        sum_im = 40'sd0;
        for (j = 0; j < PAR_TAPS; j = j + 1) begin
            // Tap index: 8 * cycle_cnt + j
            tap_idx[j] = {cycle_cnt[3:0], j[2:0]};
            // Delay line index (circular): write_ptr - tap_index
            dl_idx[j]  = write_ptr - tap_idx[j];

            // Extract I/Q from delay line
            x_re[j] = $signed(delay_mem[dl_idx[j]][15:0]);
            x_im[j] = $signed(delay_mem[dl_idx[j]][31:16]);

            // Fetch coefficients
            c_re[j] = tap_coeff_re[tap_idx[j]];
            c_im[j] = tap_coeff_im[tap_idx[j]];

            // Complex multiply: 4 real multiplies
            mul_rr[j] = x_re[j] * c_re[j];
            mul_ii[j] = x_im[j] * c_im[j];
            mul_ri[j] = x_re[j] * c_im[j];
            mul_ir[j] = x_im[j] * c_re[j];

            // Complex MAC result
            mac_re[j] = {{8{mul_rr[j][31]}}, mul_rr[j]} - {{8{mul_ii[j][31]}}, mul_ii[j]};
            mac_im[j] = {{8{mul_ri[j][31]}}, mul_ri[j]} + {{8{mul_ir[j][31]}}, mul_ir[j]};

            // Accumulate into sum tree
            sum_re = sum_re + mac_re[j];
            sum_im = sum_im + mac_im[j];
        end
    end

    // -------------------------------------------------------------------------
    // Main FSM
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state     <= ST_IDLE;
            write_ptr <= 7'd0;
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
                // COMPUTE: 8 taps per cycle × 16 cycles = 128 taps
                // Combinational sum_re/sum_im are added to accumulator.
                // ---------------------------------------------------------
                ST_COMPUTE: begin
                    acc_re <= acc_re + sum_re;
                    acc_im <= acc_im + sum_im;

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
                    write_ptr <= write_ptr + 7'd1;
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
