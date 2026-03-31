// =============================================================================
// tb_min2_finder.sv — Testbench for min2_finder module
// =============================================================================
// Tests with known magnitude vectors, verifies min1, min2, and argmin1.
// =============================================================================

`timescale 1ns / 1ps

module tb_min2_finder;

    // Parameters
    localparam int WIDTH    = 20;
    localparam int MAG_BITS = 5;

    // Signals
    logic                       clk;
    logic                       rst_n;
    logic [MAG_BITS*WIDTH-1:0]  mags_in;
    logic [4:0]                 degree;
    logic                       in_valid;
    logic [MAG_BITS-1:0]        min1_val;
    logic [MAG_BITS-1:0]        min2_val;
    logic [4:0]                 argmin1;
    logic                       valid;

    // DUT
    min2_finder #(
        .WIDTH   (WIDTH),
        .MAG_BITS(MAG_BITS)
    ) dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .mags_in (mags_in),
        .degree  (degree),
        .in_valid(in_valid),
        .min1_val(min1_val),
        .min2_val(min2_val),
        .argmin1 (argmin1),
        .valid   (valid)
    );

    // Clock
    initial clk = 0;
    always #5 clk = ~clk;

    // Test infrastructure
    int errors;
    int tests;

    task check_result(
        input string test_name,
        input logic [MAG_BITS-1:0] exp_min1,
        input logic [MAG_BITS-1:0] exp_min2,
        input logic [4:0]          exp_argmin1
    );
        // Wait for valid output (2 cycle latency)
        @(posedge clk);
        @(posedge clk);
        @(posedge clk);  // sample after 2-cycle pipeline + 1

        if (!valid) begin
            $display("FAIL [%s]: valid not asserted", test_name);
            errors++;
        end else begin
            if (min1_val !== exp_min1) begin
                $display("FAIL [%s]: min1=%0d, expected=%0d", test_name, min1_val, exp_min1);
                errors++;
            end
            if (min2_val !== exp_min2) begin
                $display("FAIL [%s]: min2=%0d, expected=%0d", test_name, min2_val, exp_min2);
                errors++;
            end
            if (argmin1 !== exp_argmin1) begin
                $display("FAIL [%s]: argmin1=%0d, expected=%0d", test_name, argmin1, exp_argmin1);
                errors++;
            end
        end
        tests++;
    endtask

    // Main test
    initial begin
        $dumpfile("tb_min2_finder.vcd");
        $dumpvars(0, tb_min2_finder);

        errors   = 0;
        tests    = 0;
        mags_in  = '1;  // all max
        degree   = '0;
        in_valid = 0;

        // Reset
        rst_n = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // =====================================================================
        // Test 1: Simple case — degree=5, mags = [10, 3, 7, 1, 5, ...]
        // Expected: min1=1 (idx=3), min2=3
        // =====================================================================
        $display("=== Test 1: Basic min2 ===");
        mags_in = '1;
        mags_in[0*MAG_BITS +: MAG_BITS] = 5'd10;
        mags_in[1*MAG_BITS +: MAG_BITS] = 5'd3;
        mags_in[2*MAG_BITS +: MAG_BITS] = 5'd7;
        mags_in[3*MAG_BITS +: MAG_BITS] = 5'd1;
        mags_in[4*MAG_BITS +: MAG_BITS] = 5'd5;
        degree   = 5'd5;
        in_valid = 1;
        @(posedge clk);
        in_valid = 0;
        check_result("basic", 5'd1, 5'd3, 5'd3);

        // =====================================================================
        // Test 2: Min at first position — degree=4, mags = [0, 15, 8, 12, ...]
        // Expected: min1=0 (idx=0), min2=8
        // =====================================================================
        $display("=== Test 2: Min at first position ===");
        mags_in = '1;
        mags_in[0*MAG_BITS +: MAG_BITS] = 5'd0;
        mags_in[1*MAG_BITS +: MAG_BITS] = 5'd15;
        mags_in[2*MAG_BITS +: MAG_BITS] = 5'd8;
        mags_in[3*MAG_BITS +: MAG_BITS] = 5'd12;
        degree   = 5'd4;
        in_valid = 1;
        @(posedge clk);
        in_valid = 0;
        check_result("min_first", 5'd0, 5'd8, 5'd0);

        // =====================================================================
        // Test 3: All same values — degree=6, mags = [5, 5, 5, 5, 5, 5, ...]
        // Expected: min1=5 (idx=0), min2=5
        // =====================================================================
        $display("=== Test 3: All same values ===");
        mags_in = '1;
        for (int i = 0; i < 6; i++)
            mags_in[i*MAG_BITS +: MAG_BITS] = 5'd5;
        degree   = 5'd6;
        in_valid = 1;
        @(posedge clk);
        in_valid = 0;
        check_result("all_same", 5'd5, 5'd5, 5'd0);

        // =====================================================================
        // Test 4: Degree=2 — mags = [20, 10, ...]
        // Expected: min1=10 (idx=1), min2=20
        // =====================================================================
        $display("=== Test 4: Degree=2 ===");
        mags_in = '1;
        mags_in[0*MAG_BITS +: MAG_BITS] = 5'd20;
        mags_in[1*MAG_BITS +: MAG_BITS] = 5'd10;
        degree   = 5'd2;
        in_valid = 1;
        @(posedge clk);
        in_valid = 0;
        check_result("degree2", 5'd10, 5'd20, 5'd1);

        // =====================================================================
        // Test 5: Min in second half — degree=12, min at position 11
        // =====================================================================
        $display("=== Test 5: Min in second half ===");
        mags_in = '1;
        for (int i = 0; i < 12; i++)
            mags_in[i*MAG_BITS +: MAG_BITS] = 5'd15;
        mags_in[11*MAG_BITS +: MAG_BITS] = 5'd2;
        mags_in[3*MAG_BITS +: MAG_BITS]  = 5'd4;
        degree   = 5'd12;
        in_valid = 1;
        @(posedge clk);
        in_valid = 0;
        check_result("min_second_half", 5'd2, 5'd4, 5'd11);

        // =====================================================================
        // Test 6: Degree=1 — mags = [7, ...]
        // Expected: min1=7 (idx=0), min2=31 (only one input)
        // =====================================================================
        $display("=== Test 6: Degree=1 ===");
        mags_in = '1;
        mags_in[0*MAG_BITS +: MAG_BITS] = 5'd7;
        degree   = 5'd1;
        in_valid = 1;
        @(posedge clk);
        in_valid = 0;
        check_result("degree1", 5'd7, 5'd31, 5'd0);

        // =====================================================================
        // Report
        // =====================================================================
        $display("");
        if (errors == 0)
            $display("PASS: All %0d min2_finder tests passed.", tests);
        else
            $display("FAIL: %0d / %0d min2_finder tests failed.", errors, tests);

        $finish;
    end

endmodule
