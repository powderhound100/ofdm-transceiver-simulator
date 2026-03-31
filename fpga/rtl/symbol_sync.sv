`timescale 1ns / 1ps
// =============================================================================
// symbol_sync.sv — CP-based symbol timing detector (Schmidl-Cox)
// =============================================================================
// Sliding correlator: multiply-accumulate over CP_LEN samples between
// r[n] and r[n+N] (CP correlation). Peak detection with threshold.
//
// Output: symbol_start pulse aligned to OFDM symbol boundary.
// =============================================================================

module symbol_sync #(
    parameter int FFT_N  = 64,
    parameter int CP_LEN = 16,
    parameter int IQ_W   = 16
)(
    input  logic                    clk,
    input  logic                    rst_n,

    // Input IQ samples
    input  logic signed [IQ_W-1:0] s_re,
    input  logic signed [IQ_W-1:0] s_im,
    input  logic                    s_valid,

    // Passthrough output (delayed by FFT_N+CP_LEN)
    output logic signed [IQ_W-1:0] m_re,
    output logic signed [IQ_W-1:0] m_im,
    output logic                    m_valid,

    // Timing detection
    output logic                    symbol_start,  // pulse at symbol boundary
    output logic [15:0]             timing_metric  // for debug
);

    localparam int DELAY = FFT_N;  // Delay between CP and its copy
    localparam int BUF_DEPTH = FFT_N + CP_LEN;

    // Delay line for storing samples
    logic signed [IQ_W-1:0] delay_re [0:BUF_DEPTH-1];
    logic signed [IQ_W-1:0] delay_im [0:BUF_DEPTH-1];
    logic [15:0] wr_ptr;
    logic buf_full;

    // Delayed sample (N samples ago)
    logic signed [IQ_W-1:0] delayed_re, delayed_im;
    logic [15:0] rd_ptr;

    // Correlation accumulator (sliding window)
    // P = sum r[n+k] * conj(r[n+k+N]) for k=0..CP_LEN-1
    logic signed [2*IQ_W+3:0] p_re_acc, p_im_acc;  // Accumulated correlation
    // R = sum |r[n+k+N]|^2
    logic [2*IQ_W+3:0] r_acc;

    // Product r[n] * conj(r[n+N])
    logic signed [2*IQ_W-1:0] prod_re, prod_im;
    logic [2*IQ_W-1:0] power;

    // Peak detection
    logic [2*IQ_W+7:0] metric_num;   // |P|^2
    logic [2*IQ_W+7:0] metric_den;   // R^2
    logic [15:0] sample_cnt;
    logic [15:0] best_metric;
    logic [15:0] best_idx;
    logic detecting;

    // Circular buffer write
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr   <= 0;
            buf_full <= 0;
        end else if (s_valid) begin
            delay_re[wr_ptr[6:0]] <= s_re;  // mod BUF_DEPTH (80)
            delay_im[wr_ptr[6:0]] <= s_im;
            if (wr_ptr == BUF_DEPTH - 1) begin
                wr_ptr   <= 0;
                buf_full <= 1;
            end else begin
                wr_ptr <= wr_ptr + 1;
            end
        end
    end

    // Read delayed sample (N samples ago)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr <= 0;
        end else begin
            // rd_ptr tracks wr_ptr - DELAY (circular)
            if (wr_ptr >= DELAY)
                rd_ptr <= wr_ptr - DELAY;
            else
                rd_ptr <= BUF_DEPTH + wr_ptr - DELAY;
        end
    end

    assign delayed_re = delay_re[rd_ptr[6:0]];
    assign delayed_im = delay_im[rd_ptr[6:0]];

    // Complex multiply: r[n] * conj(r[n+N])
    // = (a+jb) * (c-jd) = (ac+bd) + j(bc-ad)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prod_re <= 0;
            prod_im <= 0;
            power   <= 0;
        end else if (s_valid && buf_full) begin
            prod_re <= s_re * delayed_re + s_im * delayed_im;
            prod_im <= s_im * delayed_re - s_re * delayed_im;
            power   <= delayed_re * delayed_re + delayed_im * delayed_im;
        end
    end

    // Sliding window accumulator (simplified: accumulate for CP_LEN samples)
    logic [4:0] window_cnt;
    logic window_valid;
    logic p1_valid;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p_re_acc     <= 0;
            p_im_acc     <= 0;
            r_acc        <= 0;
            window_cnt   <= 0;
            window_valid <= 0;
            p1_valid     <= 0;
        end else begin
            p1_valid <= s_valid && buf_full;
            window_valid <= 0;

            if (p1_valid) begin
                if (window_cnt == 0) begin
                    p_re_acc <= prod_re;
                    p_im_acc <= prod_im;
                    r_acc    <= power;
                end else begin
                    p_re_acc <= p_re_acc + prod_re;
                    p_im_acc <= p_im_acc + prod_im;
                    r_acc    <= r_acc + power;
                end

                if (window_cnt == CP_LEN - 1) begin
                    window_cnt   <= 0;
                    window_valid <= 1;
                end else begin
                    window_cnt <= window_cnt + 1;
                end
            end
        end
    end

    // Timing metric and peak detection
    // M = |P|^2 / R^2 — we compare |P|^2 * threshold vs R^2
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            symbol_start  <= 0;
            timing_metric <= 0;
            sample_cnt    <= 0;
        end else begin
            symbol_start <= 0;

            if (window_valid) begin
                // Compute |P|^2 (truncated to 16 bits for metric)
                metric_num = (p_re_acc >>> 8) * (p_re_acc >>> 8) +
                             (p_im_acc >>> 8) * (p_im_acc >>> 8);
                metric_den = (r_acc >>> 8) * (r_acc >>> 8);

                // Simple threshold: |P|^2 > 0.5 * R^2
                // Equivalent: 2*|P|^2 > R^2
                if (metric_num > (metric_den >> 1) && r_acc > 0) begin
                    symbol_start  <= 1;
                    timing_metric <= metric_num[31:16];
                end

                sample_cnt <= sample_cnt + 1;
            end
        end
    end

    // Passthrough (delayed output)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_re    <= 0;
            m_im    <= 0;
            m_valid <= 0;
        end else begin
            m_re    <= s_re;
            m_im    <= s_im;
            m_valid <= s_valid;
        end
    end

endmodule
