// =============================================================================
// channel_fir_sparse.sv — Sparse FIR filter with up to 8 taps at arbitrary delays
// =============================================================================
// Implements a multipath channel FIR filter using a circular BRAM delay line
// and a single time-multiplexed complex MAC unit. Processes one input sample
// every 8+2 cycles (8 taps + pipeline overhead).
//
// Delay line: 256-entry circular buffer storing packed {Q[15:0], I[15:0]}.
// Each tap specifies an arbitrary delay index (0-255) and complex coefficient.
//
// Complex multiply per tap:
//   out_re = x_re * c_re - x_im * c_im
//   out_im = x_re * c_im + x_im * c_re
//
// Accumulator is 40 bits wide (16x16 multiply = 32 bits + 8 bits headroom).
// Final output is truncated from 40-bit accumulator to 16-bit with saturation.
//
// Coefficients are Q1.14 fixed-point: 1 sign bit, 1 integer bit, 14 fractional.
// After multiply, result is 32-bit Q2.28; we right-shift by 14 for Q2.14,
// then accumulate in 40 bits. Final output shifts right by 14 to get Q1.0.
//
// AXI-Stream interfaces with backpressure support.
// =============================================================================

`timescale 1ns / 1ps

module channel_fir_sparse #(
    parameter int NUM_TAPS  = 8,
    parameter int MAX_DELAY = 255,
    parameter int IQ_W      = 16
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

    // Coefficient configuration interface
    input  logic        coeff_wen,          // write enable
    input  logic [2:0]  coeff_addr,         // tap index (0-7)
    input  logic [7:0]  coeff_delay,        // delay for this tap
    input  logic signed [15:0] coeff_re,    // Q1.14 real coefficient
    input  logic signed [15:0] coeff_im,    // Q1.14 imaginary coefficient
    input  logic [2:0]  num_active_taps     // number of taps to process (1-8)
);

    // -------------------------------------------------------------------------
    // Tap coefficient storage
    // -------------------------------------------------------------------------
    logic [7:0]         tap_delay   [0:NUM_TAPS-1];
    logic signed [15:0] tap_coeff_re[0:NUM_TAPS-1];
    logic signed [15:0] tap_coeff_im[0:NUM_TAPS-1];

    integer k;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (k = 0; k < NUM_TAPS; k = k + 1) begin
                tap_delay[k]    <= 8'd0;
                tap_coeff_re[k] <= 16'sd0;
                tap_coeff_im[k] <= 16'sd0;
            end
        end else if (coeff_wen) begin
            tap_delay[coeff_addr]    <= coeff_delay;
            tap_coeff_re[coeff_addr] <= coeff_re;
            tap_coeff_im[coeff_addr] <= coeff_im;
        end
    end

    // -------------------------------------------------------------------------
    // BRAM delay line — 256 x 32-bit circular buffer
    // -------------------------------------------------------------------------
    logic [31:0] delay_mem [0:255];
    logic [7:0]  write_ptr;         // current write position (head of delay line)

    // Read address computed from write_ptr - tap_delay
    logic [7:0]  read_addr;
    logic [31:0] read_data;

    // Registered BRAM read (1-cycle latency)
    always_ff @(posedge clk) begin
        read_data <= delay_mem[read_addr];
    end

    // -------------------------------------------------------------------------
    // FSM states
    // -------------------------------------------------------------------------
    localparam [2:0] ST_IDLE    = 3'd0;   // waiting for input sample
    localparam [2:0] ST_WRITE   = 3'd1;   // write sample to delay line
    localparam [2:0] ST_ADDR    = 3'd2;   // issue BRAM read address for current tap
    localparam [2:0] ST_READ    = 3'd3;   // wait for BRAM read data
    localparam [2:0] ST_MAC     = 3'd4;   // perform complex MAC (4 real multiplies)
    localparam [2:0] ST_OUTPUT  = 3'd5;   // output result

    logic [2:0] state;
    logic [2:0] tap_cnt;           // current tap being processed (0 to num_active-1)
    logic [2:0] num_active_reg;    // registered copy of num_active_taps

    // Input sample registers
    logic [31:0] in_sample;
    logic        in_last;

    // Accumulator: 40-bit signed for I and Q
    logic signed [39:0] acc_re;
    logic signed [39:0] acc_im;

    // Delayed sample from BRAM
    logic signed [IQ_W-1:0] x_re, x_im;

    // Current tap coefficients
    logic signed [IQ_W-1:0] c_re, c_im;

    // Multiply results (32-bit products)
    logic signed [31:0] mul_rr, mul_ri, mul_ir, mul_ii;

    // -------------------------------------------------------------------------
    // s_tready: only accept new samples when idle
    // -------------------------------------------------------------------------
    assign s_tready = (state == ST_IDLE);

    // -------------------------------------------------------------------------
    // Main FSM
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state      <= ST_IDLE;
            write_ptr  <= 8'd0;
            tap_cnt    <= 3'd0;
            acc_re     <= 40'sd0;
            acc_im     <= 40'sd0;
            in_sample  <= 32'd0;
            in_last    <= 1'b0;
            m_tdata    <= 32'd0;
            m_tvalid   <= 1'b0;
            m_tlast    <= 1'b0;
            x_re       <= {IQ_W{1'b0}};
            x_im       <= {IQ_W{1'b0}};
            c_re       <= {IQ_W{1'b0}};
            c_im       <= {IQ_W{1'b0}};
            read_addr  <= 8'd0;
            num_active_reg <= 3'd1;
        end else begin
            // Default: clear output valid after one cycle
            m_tvalid <= 1'b0;
            m_tlast  <= 1'b0;

            case (state)
                // ---------------------------------------------------------
                ST_IDLE: begin
                    if (s_tvalid) begin
                        in_sample      <= s_tdata;
                        in_last        <= s_tlast;
                        num_active_reg <= (num_active_taps == 3'd0) ? 3'd1 : num_active_taps;
                        state          <= ST_WRITE;
                    end
                end

                // ---------------------------------------------------------
                // Write incoming sample into the delay line at write_ptr
                // ---------------------------------------------------------
                ST_WRITE: begin
                    delay_mem[write_ptr] <= in_sample;
                    tap_cnt              <= 3'd0;
                    acc_re               <= 40'sd0;
                    acc_im               <= 40'sd0;
                    state                <= ST_ADDR;
                end

                // ---------------------------------------------------------
                // Issue BRAM read address for the current tap
                // ---------------------------------------------------------
                ST_ADDR: begin
                    read_addr <= write_ptr - tap_delay[tap_cnt];
                    c_re      <= tap_coeff_re[tap_cnt];
                    c_im      <= tap_coeff_im[tap_cnt];
                    state     <= ST_READ;
                end

                // ---------------------------------------------------------
                // Wait one cycle for BRAM read data
                // ---------------------------------------------------------
                ST_READ: begin
                    state <= ST_MAC;
                end

                // ---------------------------------------------------------
                // Complex MAC: accumulate products
                // x_re, x_im extracted from BRAM read data
                // Complex multiply: 4 real multiplies
                // ---------------------------------------------------------
                ST_MAC: begin
                    // Extract I/Q from delay line sample
                    x_re = $signed(read_data[15:0]);    // I channel
                    x_im = $signed(read_data[31:16]);   // Q channel

                    // Four real multiplies for complex multiply
                    mul_rr = x_re * c_re;   // re*re
                    mul_ii = x_im * c_im;   // im*im
                    mul_ri = x_re * c_im;   // re*im
                    mul_ir = x_im * c_re;   // im*re

                    // Accumulate: shift right by 14 to account for Q1.14 format
                    // out_re = x_re*c_re - x_im*c_im
                    // out_im = x_re*c_im + x_im*c_re
                    acc_re <= acc_re + ({{8{mul_rr[31]}}, mul_rr} - {{8{mul_ii[31]}}, mul_ii});
                    acc_im <= acc_im + ({{8{mul_ri[31]}}, mul_ri} + {{8{mul_ir[31]}}, mul_ir});

                    if (tap_cnt == num_active_reg - 3'd1) begin
                        state <= ST_OUTPUT;
                    end else begin
                        tap_cnt <= tap_cnt + 3'd1;
                        state   <= ST_ADDR;
                    end
                end

                // ---------------------------------------------------------
                // Output: truncate 40-bit accumulator to 16-bit with saturation
                // Accumulated value is in Q2.28 format (Q1.14 x Q1.0 -> Q2.14, accumulated).
                // Shift right by 14 to get integer part, then saturate to 16 bits.
                // ---------------------------------------------------------
                ST_OUTPUT: begin
                    m_tdata  <= {saturate_16(acc_im >>> 14), saturate_16(acc_re >>> 14)};
                    m_tvalid <= 1'b1;
                    m_tlast  <= in_last;
                    // Advance write pointer for next sample
                    write_ptr <= write_ptr + 8'd1;
                    state     <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Saturation function: 40-bit signed -> 16-bit signed with clamp
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
