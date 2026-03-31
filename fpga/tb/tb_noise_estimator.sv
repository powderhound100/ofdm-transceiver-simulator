// =============================================================================
// tb_noise_estimator.sv — Testbench for pilot-based noise variance estimator
// =============================================================================
// Tests:
//   1. pilots = h_est (zero noise) → noise_var ≈ 0
//   2. pilots = h_est + small offset → noise_var ≈ |offset|^2
//   3. pilots = h_est + large offset → verify scaling correctness
// iverilog -g2012 compatible. Self-checking with PASS/FAIL.
// =============================================================================
`timescale 1ns / 1ps

module tb_noise_estimator;

    localparam int IQ_W = 16;

    // Clock / reset
    logic clk;
    logic rst_n;

    // DUT signals
    logic signed [IQ_W-1:0] pilot_re, pilot_im;
    logic                    pilot_valid;
    logic signed [IQ_W-1:0] h_est_re, h_est_im;
    logic                    h_est_valid;
    logic [15:0]             noise_var;
    logic                    noise_var_valid;

    // DUT
    noise_estimator #(.IQ_W(IQ_W)) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .pilot_re       (pilot_re),
        .pilot_im       (pilot_im),
        .pilot_valid    (pilot_valid),
        .h_est_re       (h_est_re),
        .h_est_im       (h_est_im),
        .h_est_valid    (h_est_valid),
        .noise_var      (noise_var),
        .noise_var_valid(noise_var_valid)
    );

    // Clock generation: 100 MHz
    initial clk = 0;
    always #5 clk = ~clk;

    // Helpers
    integer errors;
    integer tests;
    integer i;
    integer timeout_cnt;

    // Captured output
    logic [15:0] captured_noise_var;

    // Task: apply reset
    task do_reset;
        begin
            rst_n       = 0;
            pilot_re    = 0;
            pilot_im    = 0;
            pilot_valid = 0;
            h_est_re    = 0;
            h_est_im    = 0;
            h_est_valid = 0;
            repeat (10) @(posedge clk);
            rst_n = 1;
            repeat (5) @(posedge clk);
        end
    endtask

    // Task: feed one pilot + h_est pair simultaneously
    task send_pair;
        input signed [15:0] p_re, p_im, h_re, h_im;
        begin
            @(posedge clk);
            pilot_re    = p_re;
            pilot_im    = p_im;
            pilot_valid = 1;
            h_est_re    = h_re;
            h_est_im    = h_im;
            h_est_valid = 1;
            @(posedge clk);
            pilot_valid = 0;
            h_est_valid = 0;
        end
    endtask

    // Task: send 4 pilot/h_est pairs then wait for noise_var_valid
    task send_4_pairs_and_collect;
        input signed [15:0] p0r, p0i, h0r, h0i;
        input signed [15:0] p1r, p1i, h1r, h1i;
        input signed [15:0] p2r, p2i, h2r, h2i;
        input signed [15:0] p3r, p3i, h3r, h3i;
        begin
            send_pair(p0r, p0i, h0r, h0i);
            send_pair(p1r, p1i, h1r, h1i);
            send_pair(p2r, p2i, h2r, h2i);
            send_pair(p3r, p3i, h3r, h3i);

            // Wait for noise_var_valid
            timeout_cnt = 0;
            captured_noise_var = 0;
            while (timeout_cnt < 1000) begin
                @(posedge clk);
                timeout_cnt = timeout_cnt + 1;
                if (noise_var_valid) begin
                    captured_noise_var = noise_var;
                    timeout_cnt = 1000; // break
                end
            end
        end
    endtask

    function integer abs_val;
        input integer v;
        begin
            abs_val = (v < 0) ? -v : v;
        end
    endfunction

    // Main test
    initial begin
        $dumpfile("tb_noise_estimator.vcd");
        $dumpvars(0, tb_noise_estimator);

        errors = 0;
        tests  = 0;

        // =================================================================
        // Test 1: Zero noise — pilots equal h_est exactly
        //   err = pilot - h_est = 0 for all 4 pilots
        //   noise_var should be 0
        // =================================================================
        $display("=== Test 1: Zero noise (pilot = h_est) ===");
        do_reset;

        send_4_pairs_and_collect(
            16'sd8000,  16'sd4000,  16'sd8000,  16'sd4000,   // pair 0
            16'sd8000,  16'sd4000,  16'sd8000,  16'sd4000,   // pair 1
            16'sd8000,  16'sd4000,  16'sd8000,  16'sd4000,   // pair 2
            16'sd8000,  16'sd4000,  16'sd8000,  16'sd4000    // pair 3
        );

        $display("  noise_var = %0d (Q8.8), expected 0", captured_noise_var);
        if (captured_noise_var != 0) begin
            $display("FAIL: Test1 noise_var=%0d, expected 0", captured_noise_var);
            errors = errors + 1;
        end
        tests = tests + 1;

        // =================================================================
        // Test 2: Known small offset
        //   pilot = h_est + (256, 0) for all 4 pilots
        //   err_re = 256, err_im = 0
        //   |err|^2 = 256^2 = 65536  (in Q2.28 that's 65536 raw)
        //   mean of 4 = 65536
        //   Output: 65536 >> 20 = 0 (too small for Q8.8)
        //
        //   Use larger offset: pilot = h_est + (1024, 0)
        //   |err|^2 = 1024^2 = 1048576
        //   accum after 4 = 4*1048576 = 4194304
        //   (accum + p2_power) = 3*1048576 + 1048576 = 4194304
        //   output = 4194304 >> 20 = 4  (Q8.8 = 4/256 ≈ 0.016)
        //
        //   Use bigger: pilot = h_est + (4096, 0)
        //   |err|^2 = 4096^2 = 16777216
        //   accum+power = 4*16777216 = 67108864
        //   output = 67108864 >> 20 = 64  (Q8.8 = 64/256 = 0.25)
        // =================================================================
        $display("=== Test 2: Known offset (err = 4096+j0) ===");
        do_reset;

        send_4_pairs_and_collect(
            16'sd12096, 16'sd0,     16'sd8000,  16'sd0,      // err = 4096+j0
            16'sd12096, 16'sd0,     16'sd8000,  16'sd0,
            16'sd12096, 16'sd0,     16'sd8000,  16'sd0,
            16'sd12096, 16'sd0,     16'sd8000,  16'sd0
        );

        // Expected: |err|^2 = 4096^2 = 16777216
        // accum for pilots 0..2 = 3 * 16777216 = 50331648
        // On pilot 3 (cnt==3): (accum + p2_power) = 50331648 + 16777216 = 67108864
        // Output = 67108864 >> 20 = 64
        $display("  noise_var = %0d (Q8.8), expected ~64", captured_noise_var);
        if (abs_val(captured_noise_var - 64) > 2) begin
            $display("FAIL: Test2 noise_var=%0d, expected ~64", captured_noise_var);
            errors = errors + 1;
        end
        tests = tests + 1;

        // =================================================================
        // Test 3: Larger offset with both Re and Im components
        //   pilot = h_est + (4096, 4096)
        //   |err|^2 = 4096^2 + 4096^2 = 2*16777216 = 33554432
        //   accum+power = 4 * 33554432 = 134217728
        //   output = 134217728 >> 20 = 128  (Q8.8 = 128/256 = 0.5)
        // =================================================================
        $display("=== Test 3: Larger offset (err = 4096+j4096) ===");
        do_reset;

        send_4_pairs_and_collect(
            16'sd12096, 16'sd4096,  16'sd8000,  16'sd0,      // err = 4096+j4096
            16'sd12096, 16'sd4096,  16'sd8000,  16'sd0,
            16'sd12096, 16'sd4096,  16'sd8000,  16'sd0,
            16'sd12096, 16'sd4096,  16'sd8000,  16'sd0
        );

        $display("  noise_var = %0d (Q8.8), expected ~128", captured_noise_var);
        if (abs_val(captured_noise_var - 128) > 4) begin
            $display("FAIL: Test3 noise_var=%0d, expected ~128", captured_noise_var);
            errors = errors + 1;
        end
        tests = tests + 1;

        // =================================================================
        // Report
        // =================================================================
        $display("");
        if (errors == 0)
            $display("PASS: All %0d noise_estimator tests passed.", tests);
        else
            $display("FAIL: %0d / %0d noise_estimator tests failed.", errors, tests);

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
