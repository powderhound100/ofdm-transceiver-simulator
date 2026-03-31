// =============================================================================
// tb_fir_compare.sv — Comparison testbench for all 5 FIR filter variants
// =============================================================================
// Instantiates all 5 FIR variants (sparse, dense32/64/128/256), configures
// them with the SAME 3-tap filter, feeds identical pseudo-random input via
// LFSR, and produces a comparison table of latency / max error / status.
//
// Filter: 3 taps at delay indices 0, 3, 7
//   h[0] = 0.8 + j0  =>  Q1.14: round(0.8 * 16384) = 13107
//   h[3] = 0.5 + j0  =>  Q1.14: round(0.5 * 16384) =  8192
//   h[7] = 0.3 + j0  =>  Q1.14: round(0.3 * 16384) =  4915
//
// RTL dependencies:
//   channel_fir_sparse.sv
//   channel_fir_dense32.sv
//   channel_fir_dense64.sv
//   channel_fir_dense128.sv
//   channel_fir_dense256.sv
//
// Compile (iverilog v12):
//   iverilog -g2012 -o tb_fir_compare \
//     ../rtl/channel_fir_sparse.sv \
//     ../rtl/channel_fir_dense32.sv \
//     ../rtl/channel_fir_dense64.sv \
//     ../rtl/channel_fir_dense128.sv \
//     ../rtl/channel_fir_dense256.sv \
//     tb_fir_compare.sv
// =============================================================================

`timescale 1ns / 1ps

module tb_fir_compare;

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    localparam int IQ_W       = 16;
    localparam int NUM_SAMPLES = 100;

    // Clock: 100 MHz -> 5 ns half period
    localparam real CLK_HALF = 5.0;

    // Timeout: generous to accommodate dense256 (64 cycles/sample * 100 + overhead)
    localparam int TIMEOUT_CYCLES = 200000;

    // Q1.14 coefficients: 0.8, 0.5, 0.3 (all real-only)
    localparam signed [15:0] COEFF_0_RE = 16'sd13107;  // round(0.8 * 16384)
    localparam signed [15:0] COEFF_3_RE = 16'sd8192;   // round(0.5 * 16384)
    localparam signed [15:0] COEFF_7_RE = 16'sd4915;   // round(0.3 * 16384)

    // Tolerance for comparison (in raw Q1.0 output units)
    localparam int TOLERANCE = 10;

    // Number of variants
    localparam int NUM_VARIANTS = 5;

    // -------------------------------------------------------------------------
    // Clock and reset
    // -------------------------------------------------------------------------
    reg clk;
    reg rst_n;

    initial clk = 1'b0;
    always #(CLK_HALF) clk = ~clk;

    // -------------------------------------------------------------------------
    // Shared input signals (active-high valid, active-low reset)
    // -------------------------------------------------------------------------
    reg [31:0] s_tdata;
    reg        s_tvalid;
    reg        s_tlast;

    // -------------------------------------------------------------------------
    // Sparse FIR signals
    // -------------------------------------------------------------------------
    wire        sp_s_tready;
    wire [31:0] sp_m_tdata;
    wire        sp_m_tvalid;
    wire        sp_m_tlast;
    reg         sp_coeff_wen;
    reg  [2:0]  sp_coeff_addr;
    reg  [7:0]  sp_coeff_delay;
    reg  signed [15:0] sp_coeff_re;
    reg  signed [15:0] sp_coeff_im;
    reg  [2:0]  sp_num_active_taps;

    // -------------------------------------------------------------------------
    // Dense32 signals
    // -------------------------------------------------------------------------
    wire        d32_s_tready;
    wire [31:0] d32_m_tdata;
    wire        d32_m_tvalid;
    wire        d32_m_tlast;
    reg         d32_coeff_wen;
    reg  [4:0]  d32_coeff_addr;
    reg  signed [15:0] d32_coeff_re;
    reg  signed [15:0] d32_coeff_im;
    reg  [2:0]  d32_num_taps;

    // -------------------------------------------------------------------------
    // Dense64 signals
    // -------------------------------------------------------------------------
    wire        d64_s_tready;
    wire [31:0] d64_m_tdata;
    wire        d64_m_tvalid;
    wire        d64_m_tlast;
    reg         d64_coeff_wen;
    reg  [5:0]  d64_coeff_addr;
    reg  signed [15:0] d64_coeff_re;
    reg  signed [15:0] d64_coeff_im;
    reg  [2:0]  d64_num_taps;

    // -------------------------------------------------------------------------
    // Dense128 signals
    // -------------------------------------------------------------------------
    wire        d128_s_tready;
    wire [31:0] d128_m_tdata;
    wire        d128_m_tvalid;
    wire        d128_m_tlast;
    reg         d128_coeff_wen;
    reg  [6:0]  d128_coeff_addr;
    reg  signed [15:0] d128_coeff_re;
    reg  signed [15:0] d128_coeff_im;
    reg  [2:0]  d128_num_taps;

    // -------------------------------------------------------------------------
    // Dense256 signals
    // -------------------------------------------------------------------------
    wire        d256_s_tready;
    wire [31:0] d256_m_tdata;
    wire        d256_m_tvalid;
    wire        d256_m_tlast;
    reg         d256_coeff_wen;
    reg  [7:0]  d256_coeff_addr;
    reg  signed [15:0] d256_coeff_re;
    reg  signed [15:0] d256_coeff_im;
    reg  [2:0]  d256_num_taps;

    // -------------------------------------------------------------------------
    // DUT Instantiations
    // -------------------------------------------------------------------------

    channel_fir_sparse #(
        .NUM_TAPS  (8),
        .MAX_DELAY (255),
        .IQ_W      (IQ_W)
    ) u_sparse (
        .clk             (clk),
        .rst_n           (rst_n),
        .s_tdata         (s_tdata),
        .s_tvalid        (s_tvalid & sp_s_tready),
        .s_tready        (sp_s_tready),
        .s_tlast         (s_tlast),
        .m_tdata         (sp_m_tdata),
        .m_tvalid        (sp_m_tvalid),
        .m_tlast         (sp_m_tlast),
        .coeff_wen       (sp_coeff_wen),
        .coeff_addr      (sp_coeff_addr),
        .coeff_delay     (sp_coeff_delay),
        .coeff_re        (sp_coeff_re),
        .coeff_im        (sp_coeff_im),
        .num_active_taps (sp_num_active_taps)
    );

    channel_fir_dense32 #(
        .NUM_TAPS (32),
        .IQ_W     (IQ_W)
    ) u_dense32 (
        .clk        (clk),
        .rst_n      (rst_n),
        .s_tdata    (s_tdata),
        .s_tvalid   (s_tvalid & d32_s_tready),
        .s_tready   (d32_s_tready),
        .s_tlast    (s_tlast),
        .m_tdata    (d32_m_tdata),
        .m_tvalid   (d32_m_tvalid),
        .m_tlast    (d32_m_tlast),
        .num_taps   (d32_num_taps),
        .coeff_wen  (d32_coeff_wen),
        .coeff_addr (d32_coeff_addr),
        .coeff_re   (d32_coeff_re),
        .coeff_im   (d32_coeff_im)
    );

    channel_fir_dense64 #(
        .NUM_TAPS (64),
        .IQ_W     (IQ_W)
    ) u_dense64 (
        .clk        (clk),
        .rst_n      (rst_n),
        .s_tdata    (s_tdata),
        .s_tvalid   (s_tvalid & d64_s_tready),
        .s_tready   (d64_s_tready),
        .s_tlast    (s_tlast),
        .m_tdata    (d64_m_tdata),
        .m_tvalid   (d64_m_tvalid),
        .m_tlast    (d64_m_tlast),
        .num_taps   (d64_num_taps),
        .coeff_wen  (d64_coeff_wen),
        .coeff_addr (d64_coeff_addr),
        .coeff_re   (d64_coeff_re),
        .coeff_im   (d64_coeff_im)
    );

    channel_fir_dense128 #(
        .NUM_TAPS   (128),
        .PAR_TAPS   (8),
        .NUM_CYCLES (16),
        .IQ_W       (IQ_W)
    ) u_dense128 (
        .clk        (clk),
        .rst_n      (rst_n),
        .s_tdata    (s_tdata),
        .s_tvalid   (s_tvalid & d128_s_tready),
        .s_tready   (d128_s_tready),
        .s_tlast    (s_tlast),
        .m_tdata    (d128_m_tdata),
        .m_tvalid   (d128_m_tvalid),
        .m_tlast    (d128_m_tlast),
        .num_taps   (d128_num_taps),
        .coeff_wen  (d128_coeff_wen),
        .coeff_addr (d128_coeff_addr),
        .coeff_re   (d128_coeff_re),
        .coeff_im   (d128_coeff_im)
    );

    channel_fir_dense256 #(
        .NUM_TAPS   (256),
        .PAR_TAPS   (4),
        .NUM_CYCLES (64),
        .IQ_W       (IQ_W)
    ) u_dense256 (
        .clk        (clk),
        .rst_n      (rst_n),
        .s_tdata    (s_tdata),
        .s_tvalid   (s_tvalid & d256_s_tready),
        .s_tready   (d256_s_tready),
        .s_tlast    (s_tlast),
        .m_tdata    (d256_m_tdata),
        .m_tvalid   (d256_m_tvalid),
        .m_tlast    (d256_m_tlast),
        .num_taps   (d256_num_taps),
        .coeff_wen  (d256_coeff_wen),
        .coeff_addr (d256_coeff_addr),
        .coeff_re   (d256_coeff_re),
        .coeff_im   (d256_coeff_im)
    );

    // -------------------------------------------------------------------------
    // LFSR for reproducible pseudo-random data (16-bit Galois LFSR)
    // Polynomial: x^16 + x^14 + x^13 + x^11 + 1 (taps at 16,14,13,11)
    // -------------------------------------------------------------------------
    reg [15:0] lfsr_re;
    reg [15:0] lfsr_im;

    task lfsr_step;
        reg feedback_re, feedback_im;
        begin
            feedback_re = lfsr_re[0];
            lfsr_re = lfsr_re >> 1;
            if (feedback_re) lfsr_re = lfsr_re ^ 16'hB400;

            feedback_im = lfsr_im[0];
            lfsr_im = lfsr_im >> 1;
            if (feedback_im) lfsr_im = lfsr_im ^ 16'hB400;
        end
    endtask

    // -------------------------------------------------------------------------
    // Output capture arrays
    // -------------------------------------------------------------------------
    reg signed [15:0] out_sp_re  [0:NUM_SAMPLES-1];
    reg signed [15:0] out_sp_im  [0:NUM_SAMPLES-1];
    reg signed [15:0] out_d32_re [0:NUM_SAMPLES-1];
    reg signed [15:0] out_d32_im [0:NUM_SAMPLES-1];
    reg signed [15:0] out_d64_re [0:NUM_SAMPLES-1];
    reg signed [15:0] out_d64_im [0:NUM_SAMPLES-1];
    reg signed [15:0] out_d128_re[0:NUM_SAMPLES-1];
    reg signed [15:0] out_d128_im[0:NUM_SAMPLES-1];
    reg signed [15:0] out_d256_re[0:NUM_SAMPLES-1];
    reg signed [15:0] out_d256_im[0:NUM_SAMPLES-1];

    // Output counters
    integer sp_out_cnt;
    integer d32_out_cnt;
    integer d64_out_cnt;
    integer d128_out_cnt;
    integer d256_out_cnt;

    // Latency measurement: cycle when first input is sent vs first output received
    integer input_start_cycle;
    integer sp_first_out_cycle;
    integer d32_first_out_cycle;
    integer d64_first_out_cycle;
    integer d128_first_out_cycle;
    integer d256_first_out_cycle;
    integer cycle_counter;

    // -------------------------------------------------------------------------
    // Cycle counter
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n)
            cycle_counter <= 0;
        else
            cycle_counter <= cycle_counter + 1;
    end

    // -------------------------------------------------------------------------
    // Output capture — sparse
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            sp_out_cnt <= 0;
            sp_first_out_cycle <= 0;
        end else if (sp_m_tvalid && sp_out_cnt < NUM_SAMPLES) begin
            if (sp_out_cnt == 0) sp_first_out_cycle <= cycle_counter;
            out_sp_re[sp_out_cnt] <= $signed(sp_m_tdata[15:0]);
            out_sp_im[sp_out_cnt] <= $signed(sp_m_tdata[31:16]);
            sp_out_cnt <= sp_out_cnt + 1;
        end
    end

    // -------------------------------------------------------------------------
    // Output capture — dense32
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            d32_out_cnt <= 0;
            d32_first_out_cycle <= 0;
        end else if (d32_m_tvalid && d32_out_cnt < NUM_SAMPLES) begin
            if (d32_out_cnt == 0) d32_first_out_cycle <= cycle_counter;
            out_d32_re[d32_out_cnt] <= $signed(d32_m_tdata[15:0]);
            out_d32_im[d32_out_cnt] <= $signed(d32_m_tdata[31:16]);
            d32_out_cnt <= d32_out_cnt + 1;
        end
    end

    // -------------------------------------------------------------------------
    // Output capture — dense64
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            d64_out_cnt <= 0;
            d64_first_out_cycle <= 0;
        end else if (d64_m_tvalid && d64_out_cnt < NUM_SAMPLES) begin
            if (d64_out_cnt == 0) d64_first_out_cycle <= cycle_counter;
            out_d64_re[d64_out_cnt] <= $signed(d64_m_tdata[15:0]);
            out_d64_im[d64_out_cnt] <= $signed(d64_m_tdata[31:16]);
            d64_out_cnt <= d64_out_cnt + 1;
        end
    end

    // -------------------------------------------------------------------------
    // Output capture — dense128
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            d128_out_cnt <= 0;
            d128_first_out_cycle <= 0;
        end else if (d128_m_tvalid && d128_out_cnt < NUM_SAMPLES) begin
            if (d128_out_cnt == 0) d128_first_out_cycle <= cycle_counter;
            out_d128_re[d128_out_cnt] <= $signed(d128_m_tdata[15:0]);
            out_d128_im[d128_out_cnt] <= $signed(d128_m_tdata[31:16]);
            d128_out_cnt <= d128_out_cnt + 1;
        end
    end

    // -------------------------------------------------------------------------
    // Output capture — dense256
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            d256_out_cnt <= 0;
            d256_first_out_cycle <= 0;
        end else if (d256_m_tvalid && d256_out_cnt < NUM_SAMPLES) begin
            if (d256_out_cnt == 0) d256_first_out_cycle <= cycle_counter;
            out_d256_re[d256_out_cnt] <= $signed(d256_m_tdata[15:0]);
            out_d256_im[d256_out_cnt] <= $signed(d256_m_tdata[31:16]);
            d256_out_cnt <= d256_out_cnt + 1;
        end
    end

    // -------------------------------------------------------------------------
    // VCD dump
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("tb_fir_compare.vcd");
        $dumpvars(0, tb_fir_compare);
    end

    // -------------------------------------------------------------------------
    // Timeout watchdog
    // -------------------------------------------------------------------------
    initial begin
        #(TIMEOUT_CYCLES * CLK_HALF * 2);
        $display("ERROR: Testbench timeout after %0d cycles", TIMEOUT_CYCLES);
        $display("  Outputs received: sparse=%0d, d32=%0d, d64=%0d, d128=%0d, d256=%0d",
                 sp_out_cnt, d32_out_cnt, d64_out_cnt, d128_out_cnt, d256_out_cnt);
        $finish;
    end

    // -------------------------------------------------------------------------
    // Task: load coefficients for sparse FIR
    // Sparse uses coeff_delay to place taps at arbitrary delay indices.
    // -------------------------------------------------------------------------
    task load_sparse_coeffs;
        integer i;
        begin
            // Tap 0: delay=0, coeff=0.8+j0
            @(posedge clk);
            sp_coeff_wen   <= 1'b1;
            sp_coeff_addr  <= 3'd0;
            sp_coeff_delay <= 8'd0;
            sp_coeff_re    <= COEFF_0_RE;
            sp_coeff_im    <= 16'sd0;
            @(posedge clk);

            // Tap 1: delay=3, coeff=0.5+j0
            sp_coeff_addr  <= 3'd1;
            sp_coeff_delay <= 8'd3;
            sp_coeff_re    <= COEFF_3_RE;
            sp_coeff_im    <= 16'sd0;
            @(posedge clk);

            // Tap 2: delay=7, coeff=0.3+j0
            sp_coeff_addr  <= 3'd2;
            sp_coeff_delay <= 8'd7;
            sp_coeff_re    <= COEFF_7_RE;
            sp_coeff_im    <= 16'sd0;
            @(posedge clk);

            sp_coeff_wen <= 1'b0;
            sp_num_active_taps <= 3'd3;
        end
    endtask

    // -------------------------------------------------------------------------
    // Task: load coefficients for a dense FIR variant
    // Dense uses consecutive taps: write zeros to all, then set taps 0, 3, 7.
    // Generic task takes addr width as implicit parameter via signals.
    // -------------------------------------------------------------------------
    task load_dense32_coeffs;
        integer i;
        begin
            // Write zeros to all 32 taps
            for (i = 0; i < 32; i = i + 1) begin
                @(posedge clk);
                d32_coeff_wen  <= 1'b1;
                d32_coeff_addr <= i[4:0];
                d32_coeff_re   <= 16'sd0;
                d32_coeff_im   <= 16'sd0;
            end
            @(posedge clk);
            // Set tap 0
            d32_coeff_addr <= 5'd0;
            d32_coeff_re   <= COEFF_0_RE;
            d32_coeff_im   <= 16'sd0;
            @(posedge clk);
            // Set tap 3
            d32_coeff_addr <= 5'd3;
            d32_coeff_re   <= COEFF_3_RE;
            d32_coeff_im   <= 16'sd0;
            @(posedge clk);
            // Set tap 7
            d32_coeff_addr <= 5'd7;
            d32_coeff_re   <= COEFF_7_RE;
            d32_coeff_im   <= 16'sd0;
            @(posedge clk);
            d32_coeff_wen <= 1'b0;
        end
    endtask

    task load_dense64_coeffs;
        integer i;
        begin
            for (i = 0; i < 64; i = i + 1) begin
                @(posedge clk);
                d64_coeff_wen  <= 1'b1;
                d64_coeff_addr <= i[5:0];
                d64_coeff_re   <= 16'sd0;
                d64_coeff_im   <= 16'sd0;
            end
            @(posedge clk);
            d64_coeff_addr <= 6'd0;
            d64_coeff_re   <= COEFF_0_RE;
            d64_coeff_im   <= 16'sd0;
            @(posedge clk);
            d64_coeff_addr <= 6'd3;
            d64_coeff_re   <= COEFF_3_RE;
            d64_coeff_im   <= 16'sd0;
            @(posedge clk);
            d64_coeff_addr <= 6'd7;
            d64_coeff_re   <= COEFF_7_RE;
            d64_coeff_im   <= 16'sd0;
            @(posedge clk);
            d64_coeff_wen <= 1'b0;
        end
    endtask

    task load_dense128_coeffs;
        integer i;
        begin
            for (i = 0; i < 128; i = i + 1) begin
                @(posedge clk);
                d128_coeff_wen  <= 1'b1;
                d128_coeff_addr <= i[6:0];
                d128_coeff_re   <= 16'sd0;
                d128_coeff_im   <= 16'sd0;
            end
            @(posedge clk);
            d128_coeff_addr <= 7'd0;
            d128_coeff_re   <= COEFF_0_RE;
            d128_coeff_im   <= 16'sd0;
            @(posedge clk);
            d128_coeff_addr <= 7'd3;
            d128_coeff_re   <= COEFF_3_RE;
            d128_coeff_im   <= 16'sd0;
            @(posedge clk);
            d128_coeff_addr <= 7'd7;
            d128_coeff_re   <= COEFF_7_RE;
            d128_coeff_im   <= 16'sd0;
            @(posedge clk);
            d128_coeff_wen <= 1'b0;
        end
    endtask

    task load_dense256_coeffs;
        integer i;
        begin
            for (i = 0; i < 256; i = i + 1) begin
                @(posedge clk);
                d256_coeff_wen  <= 1'b1;
                d256_coeff_addr <= i[7:0];
                d256_coeff_re   <= 16'sd0;
                d256_coeff_im   <= 16'sd0;
            end
            @(posedge clk);
            d256_coeff_addr <= 8'd0;
            d256_coeff_re   <= COEFF_0_RE;
            d256_coeff_im   <= 16'sd0;
            @(posedge clk);
            d256_coeff_addr <= 8'd3;
            d256_coeff_re   <= COEFF_3_RE;
            d256_coeff_im   <= 16'sd0;
            @(posedge clk);
            d256_coeff_addr <= 8'd7;
            d256_coeff_re   <= COEFF_7_RE;
            d256_coeff_im   <= 16'sd0;
            @(posedge clk);
            d256_coeff_wen <= 1'b0;
        end
    endtask

    // -------------------------------------------------------------------------
    // Task: wait for all variants ready (IDLE state)
    // -------------------------------------------------------------------------
    task wait_all_ready;
        begin
            while (!(sp_s_tready && d32_s_tready && d64_s_tready &&
                     d128_s_tready && d256_s_tready)) begin
                @(posedge clk);
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Task: send one sample to all FIRs simultaneously
    // Waits until all variants are ready before asserting tvalid.
    // -------------------------------------------------------------------------
    task send_sample;
        input [31:0] data;
        input        last;
        begin
            wait_all_ready;
            @(posedge clk);
            s_tdata  <= data;
            s_tvalid <= 1'b1;
            s_tlast  <= last;
            @(posedge clk);
            s_tvalid <= 1'b0;
            s_tlast  <= 1'b0;
        end
    endtask

    // -------------------------------------------------------------------------
    // Main stimulus
    // -------------------------------------------------------------------------
    integer i;
    integer j;
    reg signed [15:0] sample_re;
    reg signed [15:0] sample_im;
    reg [31:0] sample_word;

    // Comparison variables
    integer max_err_d32_re,  max_err_d32_im;
    integer max_err_d64_re,  max_err_d64_im;
    integer max_err_d128_re, max_err_d128_im;
    integer max_err_d256_re, max_err_d256_im;
    integer max_err_d32, max_err_d64, max_err_d128, max_err_d256;
    integer diff_re, diff_im;
    integer sp_latency, d32_latency, d64_latency, d128_latency, d256_latency;
    integer overall_max_err;
    reg all_pass;

    initial begin
        // -----------------------------------------------------------------
        // Initialize all signals
        // -----------------------------------------------------------------
        rst_n     = 1'b0;
        s_tdata   = 32'd0;
        s_tvalid  = 1'b0;
        s_tlast   = 1'b0;

        sp_coeff_wen       = 1'b0;
        sp_coeff_addr      = 3'd0;
        sp_coeff_delay     = 8'd0;
        sp_coeff_re        = 16'sd0;
        sp_coeff_im        = 16'sd0;
        sp_num_active_taps = 3'd3;

        d32_coeff_wen  = 1'b0;
        d32_coeff_addr = 5'd0;
        d32_coeff_re   = 16'sd0;
        d32_coeff_im   = 16'sd0;
        d32_num_taps   = 3'd0;

        d64_coeff_wen  = 1'b0;
        d64_coeff_addr = 6'd0;
        d64_coeff_re   = 16'sd0;
        d64_coeff_im   = 16'sd0;
        d64_num_taps   = 3'd0;

        d128_coeff_wen  = 1'b0;
        d128_coeff_addr = 7'd0;
        d128_coeff_re   = 16'sd0;
        d128_coeff_im   = 16'sd0;
        d128_num_taps   = 3'd0;

        d256_coeff_wen  = 1'b0;
        d256_coeff_addr = 8'd0;
        d256_coeff_re   = 16'sd0;
        d256_coeff_im   = 16'sd0;
        d256_num_taps   = 3'd0;

        // LFSR seeds (different for I/Q to get uncorrelated sequences)
        lfsr_re = 16'hACE1;
        lfsr_im = 16'h1234;

        input_start_cycle = 0;

        // -----------------------------------------------------------------
        // Reset
        // -----------------------------------------------------------------
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        // -----------------------------------------------------------------
        // Load coefficients into all variants
        // -----------------------------------------------------------------
        $display("Loading coefficients...");
        $display("  h[0] = 0.8+j0  (Q1.14: %0d)", COEFF_0_RE);
        $display("  h[3] = 0.5+j0  (Q1.14: %0d)", COEFF_3_RE);
        $display("  h[7] = 0.3+j0  (Q1.14: %0d)", COEFF_7_RE);

        // Load all coefficient sets (sequential since they share the clock)
        load_sparse_coeffs;
        load_dense32_coeffs;
        load_dense64_coeffs;
        load_dense128_coeffs;
        load_dense256_coeffs;

        repeat (5) @(posedge clk);

        // -----------------------------------------------------------------
        // Feed test data — 100 pseudo-random IQ samples via LFSR
        // -----------------------------------------------------------------
        $display("Sending %0d pseudo-random samples (LFSR seeds: RE=0xACE1, IM=0x1234)...", NUM_SAMPLES);

        // Record when first input is sent
        input_start_cycle = cycle_counter;

        for (i = 0; i < NUM_SAMPLES; i = i + 1) begin
            // Generate sample from LFSR (treat as signed 16-bit)
            // Scale down to avoid overflow: use upper 12 bits, shift to stay in range
            sample_re = $signed(lfsr_re);
            sample_im = $signed(lfsr_im);

            // Pack {Q[15:0], I[15:0]}
            sample_word = {sample_im[15:0], sample_re[15:0]};

            send_sample(sample_word, (i == NUM_SAMPLES - 1) ? 1'b1 : 1'b0);

            // Advance LFSR
            lfsr_step;
        end

        // -----------------------------------------------------------------
        // Wait for all outputs to arrive
        // -----------------------------------------------------------------
        $display("Waiting for all outputs...");
        while (sp_out_cnt < NUM_SAMPLES || d32_out_cnt < NUM_SAMPLES ||
               d64_out_cnt < NUM_SAMPLES || d128_out_cnt < NUM_SAMPLES ||
               d256_out_cnt < NUM_SAMPLES) begin
            @(posedge clk);
        end

        repeat (10) @(posedge clk);

        // -----------------------------------------------------------------
        // Compute latencies
        // -----------------------------------------------------------------
        sp_latency   = sp_first_out_cycle   - input_start_cycle;
        d32_latency  = d32_first_out_cycle  - input_start_cycle;
        d64_latency  = d64_first_out_cycle  - input_start_cycle;
        d128_latency = d128_first_out_cycle - input_start_cycle;
        d256_latency = d256_first_out_cycle - input_start_cycle;

        // -----------------------------------------------------------------
        // Compare all variants against sparse (reference)
        // -----------------------------------------------------------------
        max_err_d32  = 0;
        max_err_d64  = 0;
        max_err_d128 = 0;
        max_err_d256 = 0;

        for (j = 0; j < NUM_SAMPLES; j = j + 1) begin
            // Dense32 vs Sparse
            diff_re = out_d32_re[j] - out_sp_re[j];
            diff_im = out_d32_im[j] - out_sp_im[j];
            if (diff_re < 0) diff_re = -diff_re;
            if (diff_im < 0) diff_im = -diff_im;
            if (diff_re > max_err_d32) max_err_d32 = diff_re;
            if (diff_im > max_err_d32) max_err_d32 = diff_im;

            // Dense64 vs Sparse
            diff_re = out_d64_re[j] - out_sp_re[j];
            diff_im = out_d64_im[j] - out_sp_im[j];
            if (diff_re < 0) diff_re = -diff_re;
            if (diff_im < 0) diff_im = -diff_im;
            if (diff_re > max_err_d64) max_err_d64 = diff_re;
            if (diff_im > max_err_d64) max_err_d64 = diff_im;

            // Dense128 vs Sparse
            diff_re = out_d128_re[j] - out_sp_re[j];
            diff_im = out_d128_im[j] - out_sp_im[j];
            if (diff_re < 0) diff_re = -diff_re;
            if (diff_im < 0) diff_im = -diff_im;
            if (diff_re > max_err_d128) max_err_d128 = diff_re;
            if (diff_im > max_err_d128) max_err_d128 = diff_im;

            // Dense256 vs Sparse
            diff_re = out_d256_re[j] - out_sp_re[j];
            diff_im = out_d256_im[j] - out_sp_im[j];
            if (diff_re < 0) diff_re = -diff_re;
            if (diff_im < 0) diff_im = -diff_im;
            if (diff_re > max_err_d256) max_err_d256 = diff_re;
            if (diff_im > max_err_d256) max_err_d256 = diff_im;
        end

        // -----------------------------------------------------------------
        // Determine overall max error and pass/fail
        // -----------------------------------------------------------------
        overall_max_err = max_err_d32;
        if (max_err_d64  > overall_max_err) overall_max_err = max_err_d64;
        if (max_err_d128 > overall_max_err) overall_max_err = max_err_d128;
        if (max_err_d256 > overall_max_err) overall_max_err = max_err_d256;

        all_pass = (overall_max_err < TOLERANCE);

        // -----------------------------------------------------------------
        // Print comparison table
        // -----------------------------------------------------------------
        $display("");
        $display("=== FIR Comparison Results ===");
        $display("Samples: %0d | LFSR seeds: RE=0xACE1, IM=0x1234 | Tolerance: %0d", NUM_SAMPLES, TOLERANCE);
        $display("Variant       | Latency | Max Err vs Sparse | Status");
        $display("--------------+---------+-------------------+--------");

        $display("sparse        | %5d   |         0         |  REF", sp_latency);

        if (max_err_d32 < TOLERANCE)
            $display("dense32       | %5d   |     %5d         |  OK", d32_latency, max_err_d32);
        else
            $display("dense32       | %5d   |     %5d         |  MISMATCH", d32_latency, max_err_d32);

        if (max_err_d64 < TOLERANCE)
            $display("dense64       | %5d   |     %5d         |  OK", d64_latency, max_err_d64);
        else
            $display("dense64       | %5d   |     %5d         |  MISMATCH", d64_latency, max_err_d64);

        if (max_err_d128 < TOLERANCE)
            $display("dense128      | %5d   |     %5d         |  OK", d128_latency, max_err_d128);
        else
            $display("dense128      | %5d   |     %5d         |  MISMATCH", d128_latency, max_err_d128);

        if (max_err_d256 < TOLERANCE)
            $display("dense256      | %5d   |     %5d         |  OK", d256_latency, max_err_d256);
        else
            $display("dense256      | %5d   |     %5d         |  MISMATCH", d256_latency, max_err_d256);

        $display("");

        // -----------------------------------------------------------------
        // Print first 5 output samples for manual inspection
        // -----------------------------------------------------------------
        $display("--- First 5 output samples (I channel) ---");
        $display("Sample | Sparse  | Dense32 | Dense64 | Dense128 | Dense256");
        $display("-------+---------+---------+---------+----------+---------");
        for (j = 0; j < 5; j = j + 1) begin
            $display("  %3d  | %6d  | %6d  | %6d  |  %6d  |  %6d",
                     j, out_sp_re[j], out_d32_re[j], out_d64_re[j],
                     out_d128_re[j], out_d256_re[j]);
        end
        $display("");

        // -----------------------------------------------------------------
        // Final verdict
        // -----------------------------------------------------------------
        if (all_pass) begin
            $display("[PASS] All variants agree within tolerance (%0d). Max error across all: %0d",
                     TOLERANCE, overall_max_err);
        end else begin
            $display("[FAIL] Variants disagree beyond tolerance (%0d). Max error across all: %0d",
                     TOLERANCE, overall_max_err);
        end

        $display("");
        $finish;
    end

endmodule
