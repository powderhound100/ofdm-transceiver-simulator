// =============================================================================
// tb_channel_estimator.sv — Testbench for LS-Improved Channel Estimator
// =============================================================================
// Tests: flat H=1, attenuation H=0.5, phase rotation, frequency selective.
// iverilog v12 compatible.
// =============================================================================
`timescale 1ns / 1ps

module tb_channel_estimator;

    // Clock / reset
    logic        clk;
    logic        rst_n;

    // DUT signals
    logic [31:0] pilot_data;
    logic        pilot_valid;
    logic        pilot_last;
    logic [31:0] h_est_data;
    logic        h_est_valid;
    logic        h_est_last;
    logic [1:0]  cfg_estimator;

    // DUT
    channel_estimator dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .pilot_data   (pilot_data),
        .pilot_valid  (pilot_valid),
        .pilot_last   (pilot_last),
        .h_est_data   (h_est_data),
        .h_est_valid  (h_est_valid),
        .h_est_last   (h_est_last),
        .cfg_estimator(cfg_estimator)
    );

    // Clock generation: 100 MHz
    initial clk = 0;
    always #5 clk = ~clk;

    // Output capture
    logic signed [15:0] est_re [0:47];
    logic signed [15:0] est_im [0:47];
    integer est_cnt;

    // Helpers
    integer errors;
    integer tests;
    integer i;
    integer timeout_cnt;
    localparam integer TOL = 1;

    // Task: apply reset
    task do_reset;
        begin
            rst_n = 0;
            pilot_data  = 0;
            pilot_valid = 0;
            pilot_last  = 0;
            cfg_estimator = 2'd1; // LS-Improved
            repeat (10) @(posedge clk);
            rst_n = 1;
            repeat (5) @(posedge clk);
        end
    endtask

    // Task: send 4 pilots with given Re/Im values
    // p0_re, p0_im, p1_re, p1_im, p2_re, p2_im, p3_re, p3_im
    task send_pilots;
        input signed [15:0] p0r, p0i, p1r, p1i, p2r, p2i, p3r, p3i;
        begin
            @(posedge clk);
            pilot_data  = {p0i, p0r};
            pilot_valid = 1;
            pilot_last  = 0;
            @(posedge clk);
            pilot_data  = {p1i, p1r};
            pilot_valid = 1;
            pilot_last  = 0;
            @(posedge clk);
            pilot_data  = {p2i, p2r};
            pilot_valid = 1;
            pilot_last  = 0;
            @(posedge clk);
            pilot_data  = {p3i, p3r};
            pilot_valid = 1;
            pilot_last  = 1;
            @(posedge clk);
            pilot_valid = 0;
            pilot_last  = 0;
        end
    endtask

    // Task: collect 48 channel estimates
    task collect_estimates;
        begin
            est_cnt = 0;
            timeout_cnt = 0;
            while (est_cnt < 48 && timeout_cnt < 100000) begin
                @(posedge clk);
                timeout_cnt = timeout_cnt + 1;
                if (h_est_valid) begin
                    est_re[est_cnt] = $signed(h_est_data[15:0]);
                    est_im[est_cnt] = $signed(h_est_data[31:16]);
                    est_cnt = est_cnt + 1;
                end
            end
            if (timeout_cnt >= 100000) begin
                $display("FAIL: Timeout waiting for channel estimates (got %0d/48)", est_cnt);
                errors = errors + 1;
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
        $dumpfile("tb_channel_estimator.vcd");
        $dumpvars(0, tb_channel_estimator);

        errors = 0;
        tests  = 0;

        // =====================================================================
        // Test 1: Flat channel H=1 — all pilots = (16384, 0)
        // Expected: all 48 estimates ~ (16384, 0)
        // =====================================================================
        $display("=== Test 1: Flat channel H=1 ===");
        do_reset;
        send_pilots(
            16'sd16384, 16'sd0,
            16'sd16384, 16'sd0,
            16'sd16384, 16'sd0,
            16'sd16384, 16'sd0
        );
        collect_estimates;

        for (i = 0; i < 48; i = i + 1) begin
            if (abs_val(est_re[i] - 16384) > TOL || abs_val(est_im[i]) > TOL) begin
                $display("FAIL: Test1 est[%0d] = (%0d, %0d), expected ~(16384, 0)",
                         i, est_re[i], est_im[i]);
                errors = errors + 1;
            end
            tests = tests + 1;
        end

        // =====================================================================
        // Test 2: Attenuation H=0.5 — all pilots = (8192, 0)
        // Expected: all 48 estimates ~ (8192, 0)
        // =====================================================================
        $display("=== Test 2: Attenuation H=0.5 ===");
        do_reset;
        send_pilots(
            16'sd8192, 16'sd0,
            16'sd8192, 16'sd0,
            16'sd8192, 16'sd0,
            16'sd8192, 16'sd0
        );
        collect_estimates;

        for (i = 0; i < 48; i = i + 1) begin
            if (abs_val(est_re[i] - 8192) > TOL || abs_val(est_im[i]) > TOL) begin
                $display("FAIL: Test2 est[%0d] = (%0d, %0d), expected ~(8192, 0)",
                         i, est_re[i], est_im[i]);
                errors = errors + 1;
            end
            tests = tests + 1;
        end

        // =====================================================================
        // Test 3: Phase rotation — pilots = exp(j*pi/4) = (11585, 11585)
        // Expected: smooth interpolation, all estimates ~ (11585, 11585)
        // =====================================================================
        $display("=== Test 3: Phase rotation ===");
        do_reset;
        send_pilots(
            16'sd11585, 16'sd11585,
            16'sd11585, 16'sd11585,
            16'sd11585, 16'sd11585,
            16'sd11585, 16'sd11585
        );
        collect_estimates;

        for (i = 0; i < 48; i = i + 1) begin
            if (abs_val(est_re[i] - 11585) > TOL || abs_val(est_im[i] - 11585) > TOL) begin
                $display("FAIL: Test3 est[%0d] = (%0d, %0d), expected ~(11585, 11585)",
                         i, est_re[i], est_im[i]);
                errors = errors + 1;
            end
            tests = tests + 1;
        end

        // =====================================================================
        // Test 4: Frequency selective — different pilot values
        // Pilot 0=(16384,0), 1=(8192,0), 2=(12288,0), 3=(4096,0)
        // Verify linear interpolation: values between pilots transition linearly
        // =====================================================================
        $display("=== Test 4: Frequency selective ===");
        do_reset;
        send_pilots(
            16'sd16384, 16'sd0,
            16'sd8192,  16'sd0,
            16'sd12288, 16'sd0,
            16'sd4096,  16'sd0
        );
        collect_estimates;

        // Just verify that estimates are in a plausible interpolated range
        // and Im parts are near zero
        for (i = 0; i < 48; i = i + 1) begin
            if (abs_val(est_im[i]) > TOL) begin
                $display("FAIL: Test4 est[%0d] Im=%0d, expected ~0", i, est_im[i]);
                errors = errors + 1;
            end
            tests = tests + 1;
        end

        // Check that estimates span a range between min and max pilot values
        begin
            integer min_est, max_est;
            min_est = 99999;
            max_est = -99999;
            for (i = 0; i < 48; i = i + 1) begin
                if (est_re[i] < min_est) min_est = est_re[i];
                if (est_re[i] > max_est) max_est = est_re[i];
            end
            $display("  Freq selective: min_re=%0d, max_re=%0d", min_est, max_est);
            if (max_est - min_est < 2000) begin
                $display("FAIL: Test4 estimates lack expected frequency selectivity");
                errors = errors + 1;
            end
            tests = tests + 1;
        end

        // =====================================================================
        // Report
        // =====================================================================
        $display("");
        if (errors == 0)
            $display("PASS: All %0d channel_estimator tests passed.", tests);
        else
            $display("FAIL: %0d / %0d channel_estimator tests failed.", errors, tests);

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
