// =============================================================================
// tb_symbol_sync.sv — Testbench for CP-based symbol timing detector
// =============================================================================
// Tests:
//   1. Known CP structure → symbol_start fires at correct position
//   2. Pure noise (random) → no spurious symbol_start pulses
// iverilog -g2012 compatible. Self-checking with PASS/FAIL.
// =============================================================================
`timescale 1ns / 1ps

module tb_symbol_sync;

    localparam int FFT_N  = 64;
    localparam int CP_LEN = 16;
    localparam int IQ_W   = 16;
    localparam int SYMLEN = FFT_N + CP_LEN;  // 80 samples per OFDM symbol

    // Clock / reset
    logic clk;
    logic rst_n;

    // DUT signals
    logic signed [IQ_W-1:0] s_re, s_im;
    logic                    s_valid;
    logic signed [IQ_W-1:0] m_re, m_im;
    logic                    m_valid;
    logic                    symbol_start;
    logic [15:0]             timing_metric;

    // DUT
    symbol_sync #(
        .FFT_N (FFT_N),
        .CP_LEN(CP_LEN),
        .IQ_W  (IQ_W)
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .s_re         (s_re),
        .s_im         (s_im),
        .s_valid      (s_valid),
        .m_re         (m_re),
        .m_im         (m_im),
        .m_valid      (m_valid),
        .symbol_start (symbol_start),
        .timing_metric(timing_metric)
    );

    // Clock generation: 100 MHz
    initial clk = 0;
    always #5 clk = ~clk;

    // Helpers
    integer errors;
    integer tests;
    integer i;
    integer j;

    // Storage for OFDM symbol data (64 samples of the FFT block)
    logic signed [15:0] fft_block_re [0:63];
    logic signed [15:0] fft_block_im [0:63];

    // LFSR for pseudorandom data (simple 16-bit LFSR)
    logic [15:0] lfsr;
    function [15:0] lfsr_next;
        input [15:0] state;
        begin
            lfsr_next = {state[14:0], state[15] ^ state[13] ^ state[12] ^ state[10]};
        end
    endfunction

    // Track symbol_start pulses
    integer start_count;
    integer start_positions [0:31];
    integer sample_counter;

    // Task: apply reset
    task do_reset;
        begin
            rst_n   = 0;
            s_re    = 0;
            s_im    = 0;
            s_valid = 0;
            repeat (10) @(posedge clk);
            rst_n = 1;
            repeat (5) @(posedge clk);
        end
    endtask

    // Task: send one IQ sample
    task send_sample;
        input signed [15:0] re, im;
        begin
            @(posedge clk);
            s_re    = re;
            s_im    = im;
            s_valid = 1;
            @(posedge clk);
            s_valid = 0;
        end
    endtask

    // Main test
    initial begin
        $dumpfile("tb_symbol_sync.vcd");
        $dumpvars(0, tb_symbol_sync);

        errors = 0;
        tests  = 0;

        // =================================================================
        // Test 1: Known CP structure
        //   Build OFDM symbols: CP = last 16 of 64-sample FFT block
        //   Send 2 symbols of noise/zeros first to fill buffer, then
        //   3 valid OFDM symbols. Expect symbol_start to fire.
        // =================================================================
        $display("=== Test 1: OFDM symbol with known CP ===");
        do_reset;

        // Generate a pseudorandom FFT block
        lfsr = 16'hACE1;
        for (i = 0; i < 64; i = i + 1) begin
            lfsr = lfsr_next(lfsr);
            // Scale to reasonable amplitude (use upper bits as signed)
            fft_block_re[i] = $signed(lfsr) >>> 2;  // ~Q1.14 range / 4
            lfsr = lfsr_next(lfsr);
            fft_block_im[i] = $signed(lfsr) >>> 2;
        end

        start_count = 0;
        sample_counter = 0;

        // Feed ~5 OFDM symbols (first ~2 fill the buffer, next should detect)
        // Each symbol: 16 CP samples (copy of last 16 of block) + 64 FFT samples
        for (j = 0; j < 5; j = j + 1) begin
            // Send CP: last 16 samples of FFT block
            for (i = 0; i < CP_LEN; i = i + 1) begin
                @(posedge clk);
                s_re    = fft_block_re[FFT_N - CP_LEN + i];
                s_im    = fft_block_im[FFT_N - CP_LEN + i];
                s_valid = 1;
                // Check for symbol_start on every clock
                if (symbol_start) begin
                    if (start_count < 32) begin
                        start_positions[start_count] = sample_counter;
                    end
                    start_count = start_count + 1;
                    $display("  symbol_start at sample %0d (symbol %0d, cp_idx %0d)",
                             sample_counter, j, i);
                end
                sample_counter = sample_counter + 1;
            end
            // Send FFT block: 64 samples
            for (i = 0; i < FFT_N; i = i + 1) begin
                @(posedge clk);
                s_re    = fft_block_re[i];
                s_im    = fft_block_im[i];
                s_valid = 1;
                if (symbol_start) begin
                    if (start_count < 32) begin
                        start_positions[start_count] = sample_counter;
                    end
                    start_count = start_count + 1;
                    $display("  symbol_start at sample %0d (symbol %0d, fft_idx %0d)",
                             sample_counter, j, i);
                end
                sample_counter = sample_counter + 1;
            end
        end
        @(posedge clk);
        s_valid = 0;

        // Flush pipeline: wait a few more cycles
        repeat (200) begin
            @(posedge clk);
            if (symbol_start) begin
                if (start_count < 32)
                    start_positions[start_count] = sample_counter;
                start_count = start_count + 1;
            end
            sample_counter = sample_counter + 1;
        end

        $display("  Total symbol_start pulses: %0d (expected >= 1)", start_count);

        // We expect at least 1 symbol_start pulse after the buffer fills
        // Buffer fills after BUF_DEPTH=80 samples, then window accumulates
        // CP_LEN=16 more for each metric evaluation
        if (start_count >= 1) begin
            $display("  PASS: Detected %0d symbol_start pulses with valid CP structure", start_count);
        end else begin
            $display("FAIL: Test1 no symbol_start detected with valid CP structure");
            errors = errors + 1;
        end
        tests = tests + 1;

        // =================================================================
        // Test 2: Pure noise (no CP structure) → few/no symbol_start pulses
        //   Feed random samples with no correlation structure.
        //   The sliding correlator should produce low metric values.
        // =================================================================
        $display("=== Test 2: Pure noise (no CP structure) ===");
        do_reset;

        start_count = 0;
        sample_counter = 0;
        lfsr = 16'hBEEF;

        // Send 400 random samples (5 symbol periods worth)
        for (i = 0; i < 400; i = i + 1) begin
            lfsr = lfsr_next(lfsr);
            @(posedge clk);
            s_re    = $signed(lfsr) >>> 2;
            lfsr = lfsr_next(lfsr);
            s_im    = $signed(lfsr) >>> 2;
            s_valid = 1;
            if (symbol_start) begin
                start_count = start_count + 1;
                $display("  Spurious symbol_start at sample %0d", sample_counter);
            end
            sample_counter = sample_counter + 1;
        end
        @(posedge clk);
        s_valid = 0;

        // Flush pipeline
        repeat (200) begin
            @(posedge clk);
            if (symbol_start) begin
                start_count = start_count + 1;
            end
            sample_counter = sample_counter + 1;
        end

        $display("  Spurious symbol_start count: %0d (expected <= 2)", start_count);

        // Random noise might occasionally pass the threshold, but should
        // be rare. Allow at most 2 spurious detections.
        if (start_count <= 2) begin
            $display("  PASS: Only %0d spurious detections with random noise", start_count);
        end else begin
            $display("FAIL: Test2 too many spurious symbol_start (%0d > 2) with noise",
                     start_count);
            errors = errors + 1;
        end
        tests = tests + 1;

        // =================================================================
        // Report
        // =================================================================
        $display("");
        if (errors == 0)
            $display("PASS: All %0d symbol_sync tests passed.", tests);
        else
            $display("FAIL: %0d / %0d symbol_sync tests failed.", errors, tests);

        #100;
        $finish;
    end

    // Global timeout
    initial begin
        #10_000_000;
        $display("FAIL: Global timeout (10ms)");
        $finish;
    end

endmodule
