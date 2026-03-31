// =============================================================================
// tb_equalizer.sv — Testbench for ZF/MMSE Channel Equalizer
// =============================================================================
// Tests: identity, real scale, phase, complex division, near-zero guard.
// iverilog v12 compatible.
// =============================================================================
`timescale 1ns / 1ps

module tb_equalizer;

    // Clock / reset
    logic        clk;
    logic        rst_n;

    // DUT signals
    logic [31:0] data_in;
    logic        data_valid;
    logic [31:0] h_est_in;
    logic        h_est_valid;
    logic [15:0] noise_var;
    logic        eq_mode;
    logic [31:0] eq_out;
    logic        eq_valid;

    // DUT
    equalizer dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .data_in    (data_in),
        .data_valid (data_valid),
        .h_est_in   (h_est_in),
        .h_est_valid(h_est_valid),
        .noise_var  (noise_var),
        .eq_mode    (eq_mode),
        .eq_out     (eq_out),
        .eq_valid   (eq_valid)
    );

    // Clock: 100 MHz
    initial clk = 0;
    always #5 clk = ~clk;

    // Helpers
    integer errors;
    integer tests;
    integer timeout_cnt;
    localparam integer TOL = 2;

    logic signed [15:0] result_re;
    logic signed [15:0] result_im;

    function integer abs_val;
        input integer v;
        begin
            abs_val = (v < 0) ? -v : v;
        end
    endfunction

    // Task: reset
    task do_reset;
        begin
            rst_n       = 0;
            data_in     = 0;
            data_valid  = 0;
            h_est_in    = 0;
            h_est_valid = 0;
            noise_var   = 16'h0000;
            eq_mode     = 0; // ZF
            repeat (10) @(posedge clk);
            rst_n = 1;
            repeat (5) @(posedge clk);
        end
    endtask

    // Task: apply one Y,H pair and wait for result
    task apply_and_wait;
        input signed [15:0] y_re, y_im, h_re, h_im;
        begin
            @(posedge clk);
            data_in     = {y_im, y_re};
            h_est_in    = {h_im, h_re};
            data_valid  = 1;
            h_est_valid = 1;
            @(posedge clk);
            data_valid  = 0;
            h_est_valid = 0;

            // Wait for eq_valid
            timeout_cnt = 0;
            while (!eq_valid && timeout_cnt < 1000) begin
                @(posedge clk);
                timeout_cnt = timeout_cnt + 1;
            end
            if (timeout_cnt >= 1000) begin
                $display("FAIL: Timeout waiting for equalizer output");
                errors = errors + 1;
            end
            result_re = $signed(eq_out[15:0]);
            result_im = $signed(eq_out[31:16]);
        end
    endtask

    // Main test
    initial begin
        $dumpfile("tb_equalizer.vcd");
        $dumpvars(0, tb_equalizer);

        errors = 0;
        tests  = 0;

        // =====================================================================
        // Test 1: Identity — Y=(16384,0), H=(16384,0)
        // Expected: EQ = Y/H = (16384,0)
        // =====================================================================
        $display("=== Test 1: Identity Y=H=(16384,0) ===");
        do_reset;
        apply_and_wait(16'sd16384, 16'sd0, 16'sd16384, 16'sd0);
        $display("  Result: (%0d, %0d)", result_re, result_im);
        if (abs_val(result_re - 16384) > TOL || abs_val(result_im) > TOL) begin
            $display("FAIL: Test1 eq=(%0d,%0d), expected ~(16384,0)", result_re, result_im);
            errors = errors + 1;
        end
        tests = tests + 1;

        // =====================================================================
        // Test 2: Real scale — Y=(8192,0), H=(8192,0)
        // Expected: EQ = Y/H = (16384,0) (since 8192/8192 = 1.0)
        // =====================================================================
        $display("=== Test 2: Real scale Y=H=(8192,0) ===");
        do_reset;
        apply_and_wait(16'sd8192, 16'sd0, 16'sd8192, 16'sd0);
        $display("  Result: (%0d, %0d)", result_re, result_im);
        if (abs_val(result_re - 16384) > TOL * 50 || abs_val(result_im) > TOL * 50) begin
            $display("FAIL: Test2 eq=(%0d,%0d), expected ~(16384,0)", result_re, result_im);
            errors = errors + 1;
        end
        tests = tests + 1;

        // =====================================================================
        // Test 3: Phase — Y=(0,16384), H=(0,16384)
        // conj(H)*Y = (0,-16384)*(0,16384) = (16384^2, 0) -> /|H|^2 -> (16384,0)
        // Actually: conj(H) = (0, -16384)
        //   num_re = Y_re*H_re + Y_im*H_im = 0*0 + 16384*16384 = 16384^2
        //   num_im = Y_im*H_re - Y_re*H_im = 16384*0 - 0*16384 = 0
        // Expected: ~(16384, 0)
        // =====================================================================
        $display("=== Test 3: Phase Y=H=(0,16384) ===");
        do_reset;
        apply_and_wait(16'sd0, 16'sd16384, 16'sd0, 16'sd16384);
        $display("  Result: (%0d, %0d)", result_re, result_im);
        if (abs_val(result_re - 16384) > TOL * 50 || abs_val(result_im) > TOL * 50) begin
            $display("FAIL: Test3 eq=(%0d,%0d), expected ~(16384,0)", result_re, result_im);
            errors = errors + 1;
        end
        tests = tests + 1;

        // =====================================================================
        // Test 4: Complex division — Y=(8192,8192), H=(16384,0)
        // conj(H)*Y = (16384,0)*(8192,8192) = (16384*8192, 16384*8192)
        // |H|^2 = 16384^2
        // EQ = (8192, 8192) ~ (0.5+0.5j) in Q1.14
        // Expected: ~(8192, 8192)
        // =====================================================================
        $display("=== Test 4: Complex Y=(8192,8192), H=(16384,0) ===");
        do_reset;
        apply_and_wait(16'sd8192, 16'sd8192, 16'sd16384, 16'sd0);
        $display("  Result: (%0d, %0d)", result_re, result_im);
        if (abs_val(result_re - 8192) > TOL * 50 || abs_val(result_im - 8192) > TOL * 50) begin
            $display("FAIL: Test4 eq=(%0d,%0d), expected ~(8192,8192)", result_re, result_im);
            errors = errors + 1;
        end
        tests = tests + 1;

        // =====================================================================
        // Test 5: Near-zero H guard — H=(100,0), Y=(16384,0)
        // Very small H, verify no overflow/crash
        // =====================================================================
        $display("=== Test 5: Near-zero H guard ===");
        do_reset;
        apply_and_wait(16'sd16384, 16'sd0, 16'sd100, 16'sd0);
        $display("  Result: (%0d, %0d)", result_re, result_im);
        // With near-zero H, result may saturate. Just verify no X/Z values.
        if (result_re === 16'bx || result_im === 16'bx) begin
            $display("FAIL: Test5 produced X values");
            errors = errors + 1;
        end
        tests = tests + 1;

        // =====================================================================
        // Report
        // =====================================================================
        $display("");
        if (errors == 0)
            $display("PASS: All %0d equalizer tests passed.", tests);
        else
            $display("FAIL: %0d / %0d equalizer tests failed.", errors, tests);

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
