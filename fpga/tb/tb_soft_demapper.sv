// =============================================================================
// tb_soft_demapper.sv — Testbench for Soft QAM Demapper
// =============================================================================
// Tests: QPSK quadrants ++, -+, --, scaled distance, saturation.
// iverilog v12 compatible.
// =============================================================================
`timescale 1ns / 1ps

module tb_soft_demapper;

    // Clock / reset
    logic        clk;
    logic        rst_n;

    // DUT signals
    logic [31:0] eq_data;
    logic        eq_valid;
    logic [3:0]  cfg_modulation;
    logic [15:0] noise_var;
    logic signed [5:0] llr_out;
    logic        llr_valid;
    logic [3:0]  llr_bit_idx;
    logic        llr_last_bit;

    // DUT
    soft_demapper dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .eq_data       (eq_data),
        .eq_valid      (eq_valid),
        .cfg_modulation(cfg_modulation),
        .noise_var     (noise_var),
        .llr_out       (llr_out),
        .llr_valid     (llr_valid),
        .llr_bit_idx   (llr_bit_idx),
        .llr_last_bit  (llr_last_bit)
    );

    // Clock: 100 MHz
    initial clk = 0;
    always #5 clk = ~clk;

    // Helpers
    integer errors;
    integer tests;
    integer timeout_cnt;
    localparam integer TOL = 1;

    // Captured LLRs for current symbol
    logic signed [5:0] llr_vals [0:3];
    integer llr_cnt;

    function integer abs_val;
        input integer v;
        begin
            abs_val = (v < 0) ? -v : v;
        end
    endfunction

    // Task: reset
    task do_reset;
        begin
            rst_n          = 0;
            eq_data        = 0;
            eq_valid       = 0;
            cfg_modulation = 4'd0; // QPSK
            noise_var      = 16'h0100; // 1.0 in Q8.8
            repeat (10) @(posedge clk);
            rst_n = 1;
            repeat (5) @(posedge clk);
        end
    endtask

    // Task: send one equalized symbol and capture BPS LLRs
    task send_symbol;
        input signed [15:0] sym_re, sym_im;
        input integer bps;
        begin
            @(posedge clk);
            #1;
            eq_data  = {sym_im[15:0], sym_re[15:0]};
            eq_valid = 1;
            @(posedge clk);
            #1;
            eq_valid = 0;

            llr_cnt = 0;
            timeout_cnt = 0;
            while (llr_cnt < bps && timeout_cnt < 1000) begin
                @(posedge clk);
                timeout_cnt = timeout_cnt + 1;
                if (llr_valid) begin
                    llr_vals[llr_cnt] = llr_out;
                    llr_cnt = llr_cnt + 1;
                end
            end
            if (timeout_cnt >= 1000) begin
                $display("FAIL: Timeout waiting for LLR output (got %0d/%0d)", llr_cnt, bps);
                errors = errors + 1;
            end
        end
    endtask

    // Main test
    initial begin
        $dumpfile("tb_soft_demapper.vcd");
        $dumpvars(0, tb_soft_demapper);

        errors = 0;
        tests  = 0;

        // =====================================================================
        // Test 1: QPSK quadrant ++ — Input (11585, 11585) = 0.707+j0.707
        // For QPSK: LLR[0] = scaled_re (positive), LLR[1] = scaled_im (positive)
        // Both should be > 0
        // =====================================================================
        $display("=== Test 1: QPSK quadrant ++ ===");
        do_reset;
        send_symbol(16'sd11585, 16'sd11585, 2);
        $display("  LLR[0]=%0d, LLR[1]=%0d", llr_vals[0], llr_vals[1]);
        if (llr_vals[0] <= 0) begin
            $display("FAIL: Test1 LLR[0]=%0d, expected > 0", llr_vals[0]);
            errors = errors + 1;
        end
        tests = tests + 1;
        if (llr_vals[1] <= 0) begin
            $display("FAIL: Test1 LLR[1]=%0d, expected > 0", llr_vals[1]);
            errors = errors + 1;
        end
        tests = tests + 1;

        // =====================================================================
        // Test 2: QPSK quadrant -+ — Input (-11585, 11585)
        // LLR[0] < 0 (negative Re), LLR[1] > 0 (positive Im)
        // =====================================================================
        $display("=== Test 2: QPSK quadrant -+ ===");
        do_reset;
        send_symbol(-16'sd11585, 16'sd11585, 2);
        $display("  LLR[0]=%0d, LLR[1]=%0d", llr_vals[0], llr_vals[1]);
        if (llr_vals[0] >= 0) begin
            $display("FAIL: Test2 LLR[0]=%0d, expected < 0", llr_vals[0]);
            errors = errors + 1;
        end
        tests = tests + 1;
        if (llr_vals[1] <= 0) begin
            $display("FAIL: Test2 LLR[1]=%0d, expected > 0", llr_vals[1]);
            errors = errors + 1;
        end
        tests = tests + 1;

        // =====================================================================
        // Test 3: QPSK quadrant -- — Input (-11585, -11585)
        // Both LLRs < 0
        // =====================================================================
        $display("=== Test 3: QPSK quadrant -- ===");
        do_reset;
        send_symbol(-16'sd11585, -16'sd11585, 2);
        $display("  LLR[0]=%0d, LLR[1]=%0d", llr_vals[0], llr_vals[1]);
        if (llr_vals[0] >= 0) begin
            $display("FAIL: Test3 LLR[0]=%0d, expected < 0", llr_vals[0]);
            errors = errors + 1;
        end
        tests = tests + 1;
        if (llr_vals[1] >= 0) begin
            $display("FAIL: Test3 LLR[1]=%0d, expected < 0", llr_vals[1]);
            errors = errors + 1;
        end
        tests = tests + 1;

        // =====================================================================
        // Test 4: QPSK scaled — Input (23170, 23170) = 2x distance
        // LLR magnitudes should be larger than Test 1
        // =====================================================================
        $display("=== Test 4: QPSK scaled (2x distance) ===");
        do_reset;
        begin
            logic signed [5:0] llr0_test1, llr1_test1;
            // Re-run test1 to get baseline
            send_symbol(16'sd11585, 16'sd11585, 2);
            llr0_test1 = llr_vals[0];
            llr1_test1 = llr_vals[1];

            // Wait for FSM to go idle
            repeat (5) @(posedge clk);

            send_symbol(16'sd23170, 16'sd23170, 2);
            $display("  Baseline LLR[0]=%0d, Scaled LLR[0]=%0d", llr0_test1, llr_vals[0]);
            // Both may saturate to ±31, which is acceptable
            if (abs_val(llr_vals[0]) < abs_val(llr0_test1)) begin
                $display("FAIL: Test4 scaled LLR[0]=%0d smaller than baseline %0d",
                         llr_vals[0], llr0_test1);
                errors = errors + 1;
            end
            tests = tests + 1;
        end

        // =====================================================================
        // Test 5: Saturation — Very large input
        // LLR should be clipped to +/-31
        // =====================================================================
        $display("=== Test 5: Saturation ===");
        do_reset;
        send_symbol(16'sd32767, 16'sd32767, 2);
        $display("  LLR[0]=%0d, LLR[1]=%0d", llr_vals[0], llr_vals[1]);
        if (llr_vals[0] != 6'sd31) begin
            $display("FAIL: Test5 LLR[0]=%0d, expected 31 (saturated)", llr_vals[0]);
            errors = errors + 1;
        end
        tests = tests + 1;
        if (llr_vals[1] != 6'sd31) begin
            $display("FAIL: Test5 LLR[1]=%0d, expected 31 (saturated)", llr_vals[1]);
            errors = errors + 1;
        end
        tests = tests + 1;

        // =====================================================================
        // Report
        // =====================================================================
        $display("");
        if (errors == 0)
            $display("PASS: All %0d soft_demapper tests passed.", tests);
        else
            $display("FAIL: %0d / %0d soft_demapper tests failed.", errors, tests);

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
