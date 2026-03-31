// =============================================================================
// tb_variable_node_unit.sv — Testbench for variable_node_unit
// =============================================================================
// Tests the VNU with known channel LLR and c2v inputs, verifying posterior
// and v2c outputs including saturation behavior.
// =============================================================================

`timescale 1ns / 1ps

module tb_variable_node_unit;

    // Parameters
    localparam int Z = 27;
    localparam int W = 6;

    // Signals
    logic              clk;
    logic              rst_n;
    logic [W*Z-1:0]   channel_llr;
    logic [W*Z-1:0]   c2v_in;
    logic              first_check;
    logic              in_valid;
    logic [W*Z-1:0]   v2c_out;
    logic [W*Z-1:0]   posterior_out;
    logic              valid;

    // DUT
    variable_node_unit #(.Z(Z), .W(W)) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .channel_llr  (channel_llr),
        .c2v_in       (c2v_in),
        .first_check  (first_check),
        .in_valid     (in_valid),
        .v2c_out      (v2c_out),
        .posterior_out(posterior_out),
        .valid        (valid)
    );

    // Clock
    initial clk = 0;
    always #5 clk = ~clk;

    // Test infrastructure
    int errors;
    int tests;
    int fail;
    logic signed [W-1:0] post_val;
    logic signed [W-1:0] v2c_val;

    // Saturation function for checking
    function automatic logic signed [W-1:0] sat(input int val);
        if (val > 31)  return 6'sd31;
        if (val < -31) return -6'sd31;
        return val[W-1:0];
    endfunction

    // Main test
    initial begin
        $dumpfile("tb_variable_node_unit.vcd");
        $dumpvars(0, tb_variable_node_unit);

        errors = 0;
        tests  = 0;

        // Reset
        rst_n       = 0;
        channel_llr = '0;
        c2v_in      = '0;
        first_check = 0;
        in_valid    = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // =====================================================================
        // Test 1: Single c2v message
        // channel_llr = +10 for all Z, c2v = +5 for all Z, first_check=1
        // Expected: posterior = 10 + 5 = 15, v2c = 15 - 5 = 10
        // =====================================================================
        $display("=== Test 1: Single c2v, channel=+10, c2v=+5 ===");
        for (int z = 0; z < Z; z++) begin
            channel_llr[z*W +: W] = 6'sd10;
            c2v_in[z*W +: W]     = 6'sd5;
        end
        first_check = 1;
        in_valid    = 1;
        @(posedge clk);
        in_valid    = 0;
        first_check = 0;

        // Wait for valid (1 cycle latency from input register + 1 from computation)
        @(posedge clk);
        @(posedge clk);

        if (valid) begin
            fail = 0;
            for (int z = 0; z < Z; z++) begin
                post_val = posterior_out[z*W +: W];
                v2c_val  = v2c_out[z*W +: W];
                if (post_val != 6'sd15) begin
                    if (fail == 0)
                        $display("FAIL: posterior[%0d]=%0d, expected 15", z, post_val);
                    fail = 1;
                end
                if (v2c_val != 6'sd10) begin
                    if (fail == 0)
                        $display("FAIL: v2c[%0d]=%0d, expected 10", z, v2c_val);
                    fail = 1;
                end
            end
            if (fail) errors++;
            else $display("  PASS");
        end else begin
            $display("FAIL: valid not asserted");
            errors++;
        end
        tests++;

        // =====================================================================
        // Test 2: Two c2v messages accumulated
        // channel_llr = +8, c2v1 = +3 (first), c2v2 = +4 (second)
        // After c2v1: acc=3, posterior=8+3=11, v2c=11-3=8
        // After c2v2: acc=3+4=7, posterior=8+7=15, v2c=15-4=11
        // =====================================================================
        $display("=== Test 2: Two c2v messages ===");
        for (int z = 0; z < Z; z++) begin
            channel_llr[z*W +: W] = 6'sd8;
            c2v_in[z*W +: W]     = 6'sd3;
        end
        first_check = 1;
        in_valid    = 1;
        @(posedge clk);

        // Second c2v
        for (int z = 0; z < Z; z++)
            c2v_in[z*W +: W] = 6'sd4;
        first_check = 0;
        @(posedge clk);
        in_valid = 0;

        // Check second output
        @(posedge clk);
        @(posedge clk);

        if (valid) begin
            post_val = posterior_out[0*W +: W];
            v2c_val  = v2c_out[0*W +: W];
            if (post_val != 6'sd15 || v2c_val != 6'sd11) begin
                $display("FAIL: post=%0d (exp 15), v2c=%0d (exp 11)", post_val, v2c_val);
                errors++;
            end else begin
                $display("  PASS");
            end
        end else begin
            $display("FAIL: valid not asserted");
            errors++;
        end
        tests++;

        // =====================================================================
        // Test 3: Saturation — positive overflow
        // channel_llr = +31, c2v = +31, first_check=1
        // Expected: posterior = sat(31+31) = +31, v2c = sat(31-31) = 0
        // =====================================================================
        $display("=== Test 3: Positive saturation ===");
        for (int z = 0; z < Z; z++) begin
            channel_llr[z*W +: W] = 6'sd31;
            c2v_in[z*W +: W]     = 6'sd31;
        end
        first_check = 1;
        in_valid    = 1;
        @(posedge clk);
        in_valid    = 0;
        first_check = 0;

        @(posedge clk);
        @(posedge clk);

        if (valid) begin
            post_val = posterior_out[0*W +: W];
            v2c_val  = v2c_out[0*W +: W];
            if (post_val != 6'sd31) begin
                $display("FAIL: saturated posterior=%0d, expected 31", post_val);
                errors++;
            end else if (v2c_val != 6'sd0) begin
                $display("FAIL: v2c=%0d, expected 0", v2c_val);
                errors++;
            end else begin
                $display("  PASS");
            end
        end else begin
            $display("FAIL: valid not asserted");
            errors++;
        end
        tests++;

        // =====================================================================
        // Test 4: Negative values
        // channel_llr = -15, c2v = -10, first_check=1
        // Expected: posterior = sat(-15 + -10) = -25, v2c = sat(-25 - -10) = -15
        // =====================================================================
        $display("=== Test 4: Negative values ===");
        for (int z = 0; z < Z; z++) begin
            channel_llr[z*W +: W] = -6'sd15;
            c2v_in[z*W +: W]     = -6'sd10;
        end
        first_check = 1;
        in_valid    = 1;
        @(posedge clk);
        in_valid    = 0;
        first_check = 0;

        @(posedge clk);
        @(posedge clk);

        if (valid) begin
            post_val = posterior_out[0*W +: W];
            v2c_val  = v2c_out[0*W +: W];
            if (post_val != -6'sd25) begin
                $display("FAIL: posterior=%0d, expected -25", post_val);
                errors++;
            end else if (v2c_val != -6'sd15) begin
                $display("FAIL: v2c=%0d, expected -15", v2c_val);
                errors++;
            end else begin
                $display("  PASS");
            end
        end else begin
            $display("FAIL: valid not asserted");
            errors++;
        end
        tests++;

        // =====================================================================
        // Test 5: Negative saturation
        // channel_llr = -31, c2v = -31
        // Expected: posterior = -31 (saturated), v2c = -31-(-31) = 0
        // =====================================================================
        $display("=== Test 5: Negative saturation ===");
        for (int z = 0; z < Z; z++) begin
            channel_llr[z*W +: W] = -6'sd31;
            c2v_in[z*W +: W]     = -6'sd31;
        end
        first_check = 1;
        in_valid    = 1;
        @(posedge clk);
        in_valid    = 0;
        first_check = 0;

        @(posedge clk);
        @(posedge clk);

        if (valid) begin
            post_val = posterior_out[0*W +: W];
            v2c_val  = v2c_out[0*W +: W];
            if (post_val != -6'sd31) begin
                $display("FAIL: saturated posterior=%0d, expected -31", post_val);
                errors++;
            end else begin
                $display("  PASS");
            end
        end else begin
            $display("FAIL: valid not asserted");
            errors++;
        end
        tests++;

        // =====================================================================
        // Test 6: Mixed signs across Z elements
        // =====================================================================
        $display("=== Test 6: Mixed signs across Z ===");
        for (int z = 0; z < Z; z++) begin
            if (z % 2 == 0) begin
                channel_llr[z*W +: W] = 6'sd20;
                c2v_in[z*W +: W]     = 6'sd5;
            end else begin
                channel_llr[z*W +: W] = -6'sd20;
                c2v_in[z*W +: W]     = -6'sd5;
            end
        end
        first_check = 1;
        in_valid    = 1;
        @(posedge clk);
        in_valid    = 0;
        first_check = 0;

        @(posedge clk);
        @(posedge clk);

        if (valid) begin
            fail = 0;
            for (int z = 0; z < Z; z++) begin
                post_val = posterior_out[z*W +: W];
                v2c_val  = v2c_out[z*W +: W];
                if (z % 2 == 0) begin
                    if (post_val != 6'sd25) fail = 1;
                    if (v2c_val != 6'sd20) fail = 1;
                end else begin
                    if (post_val != -6'sd25) fail = 1;
                    if (v2c_val != -6'sd20) fail = 1;
                end
            end
            if (fail) begin
                $display("FAIL: mixed sign mismatch");
                errors++;
            end else begin
                $display("  PASS");
            end
        end else begin
            $display("FAIL: valid not asserted");
            errors++;
        end
        tests++;

        // =====================================================================
        // Report
        // =====================================================================
        $display("");
        if (errors == 0)
            $display("PASS: All %0d variable_node_unit tests passed.", tests);
        else
            $display("FAIL: %0d / %0d variable_node_unit tests failed.", errors, tests);

        $finish;
    end

endmodule
