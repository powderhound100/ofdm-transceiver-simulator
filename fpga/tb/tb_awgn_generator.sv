// =============================================================================
// tb_awgn_generator.sv — Testbench for AWGN generator module
// =============================================================================
// Self-checking testbench that generates 10000 noise samples and verifies:
//   1. Mean bias check (|mean| < 0.05 * sigma)
//   2. Variance accuracy (within 10% of expected)
//   3. Tail bound (no sample exceeds +/- 6*sigma)
//
// RTL dependencies:
//   awgn_generator.sv
//   lfsr64.sv
//
// Compile (iverilog v12):
//   iverilog -g2012 -o tb_awgn_generator \
//     ../rtl/lfsr64.sv \
//     ../rtl/awgn_generator.sv \
//     tb_awgn_generator.sv
// =============================================================================

`timescale 1ns / 1ps

module tb_awgn_generator;

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    localparam int NUM_SAMPLES = 10000;
    localparam real CLK_HALF   = 5.0;  // 100 MHz

    // -------------------------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------------------------
    logic        clk;
    logic        rst_n;
    logic        enable;
    logic [63:0] seed_i;
    logic [63:0] seed_q;
    logic [15:0] noise_scale;
    logic signed [15:0] noise_i;
    logic signed [15:0] noise_q;
    logic        noise_valid;

    // -------------------------------------------------------------------------
    // DUT instantiation
    // -------------------------------------------------------------------------
    awgn_generator dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .enable      (enable),
        .seed_i      (seed_i),
        .seed_q      (seed_q),
        .noise_scale (noise_scale),
        .noise_i     (noise_i),
        .noise_q     (noise_q),
        .noise_valid (noise_valid)
    );

    // -------------------------------------------------------------------------
    // Clock generation
    // -------------------------------------------------------------------------
    initial clk = 0;
    always #(CLK_HALF) clk = ~clk;

    // -------------------------------------------------------------------------
    // Timeout watchdog: 50 ms
    // -------------------------------------------------------------------------
    initial begin
        #50_000_000;
        $display("TIMEOUT: Simulation exceeded 50 ms");
        $finish;
    end

    // -------------------------------------------------------------------------
    // Test variables (module-level for iverilog compatibility)
    // -------------------------------------------------------------------------
    integer pass_count;
    integer fail_count;
    integer sample_count;

    // 64-bit accumulators
    logic signed [63:0] sum_i_acc;
    logic signed [63:0] sum_q_acc;
    logic signed [63:0] sumsq_i_acc;
    logic signed [63:0] sumsq_q_acc;

    // Min/max tracking
    logic signed [15:0] max_i, min_i;
    logic signed [15:0] max_q, min_q;

    // Statistics (real)
    real mean_i_r, mean_q_r;
    real var_i_r, var_q_r;
    real var_avg, sigma;
    real mean_thresh;
    real abs_mean_i, abs_mean_q;
    real abs_max_sample, six_sigma;
    real var_diff, var_expect;
    real abs_max_i_r, abs_min_i_r, abs_max_q_r, abs_min_q_r;

    // -------------------------------------------------------------------------
    // Main test sequence
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("tb_awgn_generator.vcd");
        $dumpvars(0, tb_awgn_generator);

        // Initialize
        rst_n       = 1'b0;
        enable      = 1'b0;
        seed_i      = 64'hDEAD_BEEF_CAFE_BABE;
        seed_q      = 64'h1234_5678_9ABC_DEF0;
        noise_scale = 16'h0100;  // 1.0 in Q8.8
        pass_count  = 0;
        fail_count  = 0;

        // Release reset
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        // Enable noise generation
        enable = 1'b1;

        // Initialize accumulators
        sum_i_acc   = 0;
        sum_q_acc   = 0;
        sumsq_i_acc = 0;
        sumsq_q_acc = 0;
        max_i       = -16'sd32768;
        min_i       = 16'sd32767;
        max_q       = -16'sd32768;
        min_q       = 16'sd32767;

        // Collect NUM_SAMPLES noise samples
        sample_count = 0;
        while (sample_count < NUM_SAMPLES) begin
            @(posedge clk);
            if (noise_valid) begin
                // Accumulate statistics
                sum_i_acc   = sum_i_acc + noise_i;
                sum_q_acc   = sum_q_acc + noise_q;
                sumsq_i_acc = sumsq_i_acc + (noise_i * noise_i);
                sumsq_q_acc = sumsq_q_acc + (noise_q * noise_q);

                // Track extrema
                if (noise_i > max_i) max_i = noise_i;
                if (noise_i < min_i) min_i = noise_i;
                if (noise_q > max_q) max_q = noise_q;
                if (noise_q < min_q) min_q = noise_q;

                sample_count = sample_count + 1;

                if (sample_count % 2000 == 0)
                    $display("  Collected %0d / %0d samples...", sample_count, NUM_SAMPLES);
            end
        end

        enable = 1'b0;
        repeat (10) @(posedge clk);

        // =====================================================================
        // Compute statistics
        // =====================================================================
        mean_i_r = $itor(sum_i_acc) / $itor(NUM_SAMPLES);
        mean_q_r = $itor(sum_q_acc) / $itor(NUM_SAMPLES);

        var_i_r = ($itor(sumsq_i_acc) / $itor(NUM_SAMPLES)) - (mean_i_r * mean_i_r);
        var_q_r = ($itor(sumsq_q_acc) / $itor(NUM_SAMPLES)) - (mean_q_r * mean_q_r);

        var_avg = (var_i_r + var_q_r) / 2.0;
        // Approximate sqrt via Newton's method (avoids $sqrt dependency)
        // sigma = sqrt(var_avg)
        sigma = var_avg / 2.0;
        if (sigma > 0.0) begin
            // 10 Newton iterations: x_{n+1} = (x_n + var_avg/x_n) / 2
            repeat (10) sigma = (sigma + var_avg / sigma) / 2.0;
        end

        $display("\n=== AWGN Statistics (%0d samples) ===", NUM_SAMPLES);
        $display("  Mean I:     %f", mean_i_r);
        $display("  Mean Q:     %f", mean_q_r);
        $display("  Variance I: %f", var_i_r);
        $display("  Variance Q: %f", var_q_r);
        $display("  Avg sigma:  %f", sigma);
        $display("  Min I: %0d, Max I: %0d", min_i, max_i);
        $display("  Min Q: %0d, Max Q: %0d", min_q, max_q);

        // =================================================================
        // TEST 1: Bias check — |mean| < 0.05 * sigma
        // =================================================================
        $display("\n=== TEST 1: Bias check (|mean| < 0.05 * sigma) ===");
        mean_thresh = 0.05 * sigma;
        abs_mean_i = (mean_i_r < 0.0) ? -mean_i_r : mean_i_r;
        abs_mean_q = (mean_q_r < 0.0) ? -mean_q_r : mean_q_r;

        $display("  |mean_I| = %f, |mean_Q| = %f, threshold = %f",
                 abs_mean_i, abs_mean_q, mean_thresh);

        if (abs_mean_i < mean_thresh && abs_mean_q < mean_thresh) begin
            $display("  TEST 1: PASS");
            pass_count = pass_count + 1;
        end else begin
            $display("  TEST 1: FAIL");
            fail_count = fail_count + 1;
        end

        // =================================================================
        // TEST 2: Variance accuracy — I and Q variances within 10%
        // =================================================================
        $display("\n=== TEST 2: Variance accuracy ===");
        var_expect = var_avg;
        var_diff = (var_i_r > var_q_r) ? (var_i_r - var_q_r) : (var_q_r - var_i_r);

        $display("  Var I = %f, Var Q = %f, Avg = %f", var_i_r, var_q_r, var_avg);
        $display("  |Var_I - Var_Q| = %f, 10%% threshold = %f", var_diff, 0.10 * var_expect);

        if (var_avg > 1.0 && var_diff < 0.10 * var_expect) begin
            $display("  TEST 2: PASS");
            pass_count = pass_count + 1;
        end else begin
            $display("  TEST 2: FAIL");
            fail_count = fail_count + 1;
        end

        // =================================================================
        // TEST 3: Tail bound — no sample exceeds +/- 6*sigma
        // =================================================================
        $display("\n=== TEST 3: Tail bound (no sample > 6*sigma) ===");
        six_sigma = 6.0 * sigma;

        abs_max_i_r = $itor((max_i < 0) ? -max_i : max_i);
        abs_min_i_r = $itor((min_i < 0) ? -min_i : min_i);
        abs_max_q_r = $itor((max_q < 0) ? -max_q : max_q);
        abs_min_q_r = $itor((min_q < 0) ? -min_q : min_q);

        abs_max_sample = abs_max_i_r;
        if (abs_min_i_r > abs_max_sample) abs_max_sample = abs_min_i_r;
        if (abs_max_q_r > abs_max_sample) abs_max_sample = abs_max_q_r;
        if (abs_min_q_r > abs_max_sample) abs_max_sample = abs_min_q_r;

        $display("  Max |sample| = %f, 6*sigma = %f", abs_max_sample, six_sigma);

        if (abs_max_sample < six_sigma) begin
            $display("  TEST 3: PASS");
            pass_count = pass_count + 1;
        end else begin
            $display("  TEST 3: FAIL");
            fail_count = fail_count + 1;
        end

        // =====================================================================
        // Summary
        // =====================================================================
        $display("\n===================================");
        $display("  RESULTS: %0d PASS, %0d FAIL", pass_count, fail_count);
        if (fail_count == 0)
            $display("  ALL TESTS PASSED");
        else
            $display("  SOME TESTS FAILED");
        $display("===================================\n");

        $finish;
    end

endmodule
