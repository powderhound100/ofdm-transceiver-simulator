// =============================================================================
// tb_barrel_shifter.sv — Testbench for barrel_shifter module
// =============================================================================
// Tests all shift values 0..Z-1 with a known pattern and verifies
// against expected cyclic shift.
// =============================================================================

`timescale 1ns / 1ps

module tb_barrel_shifter;

    // Parameters
    localparam int Z = 27;
    localparam int W = 6;

    // Signals
    logic              clk;
    logic              rst_n;
    logic [W*Z-1:0]   data_in;
    logic [8:0]        shift_val;
    logic [W*Z-1:0]   data_out;

    // DUT
    barrel_shifter #(.Z(Z), .W(W)) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .data_in  (data_in),
        .shift_val(shift_val),
        .data_out (data_out)
    );

    // Clock generation
    initial clk = 0;
    always #5 clk = ~clk;  // 100 MHz

    // Test variables
    int errors;
    int tests;

    // Expected output computation
    function automatic logic [W*Z-1:0] expected_shift(
        input logic [W*Z-1:0] din,
        input int shift
    );
        logic [W*Z-1:0] result;
        for (int i = 0; i < Z; i++) begin
            int src_idx;
            src_idx = (i + Z - shift) % Z;
            result[i*W +: W] = din[src_idx*W +: W];
        end
        return result;
    endfunction

    // Main test
    initial begin
        $dumpfile("tb_barrel_shifter.vcd");
        $dumpvars(0, tb_barrel_shifter);

        errors = 0;
        tests  = 0;

        // Reset
        rst_n = 0;
        data_in = '0;
        shift_val = '0;
        repeat (5) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // =====================================================================
        // Test 1: Identity pattern — each element = its index (mod 2^W)
        // =====================================================================
        $display("=== Test 1: Index pattern, all shift values ===");
        for (int i = 0; i < Z; i++) begin
            data_in[i*W +: W] = i[W-1:0];
        end

        for (int s = 0; s < Z; s++) begin
            shift_val = s[8:0];
            @(posedge clk);
            @(posedge clk);  // 2 cycle latency
            @(posedge clk);  // sample output
            begin
                automatic logic [W*Z-1:0] expected;
                expected = expected_shift(data_in, s);
                if (data_out !== expected) begin
                    $display("FAIL: shift=%0d, got=%h, expected=%h", s, data_out, expected);
                    errors++;
                end
                tests++;
            end
        end

        // =====================================================================
        // Test 2: All-ones pattern
        // =====================================================================
        $display("=== Test 2: All-ones pattern ===");
        for (int i = 0; i < Z; i++) begin
            data_in[i*W +: W] = {W{1'b1}};
        end

        shift_val = 9'd13;
        @(posedge clk);
        @(posedge clk);
        @(posedge clk);
        begin
            automatic logic [W*Z-1:0] expected;
            expected = expected_shift(data_in, 13);
            if (data_out !== expected) begin
                $display("FAIL: all-ones shift=13");
                errors++;
            end
            tests++;
        end

        // =====================================================================
        // Test 3: Alternating positive/negative pattern
        // =====================================================================
        $display("=== Test 3: Alternating sign pattern ===");
        for (int i = 0; i < Z; i++) begin
            if (i % 2 == 0)
                data_in[i*W +: W] = 6'b011111;  // +31
            else
                data_in[i*W +: W] = 6'b100001;  // -31
        end

        for (int s = 0; s < Z; s += 5) begin
            shift_val = s[8:0];
            @(posedge clk);
            @(posedge clk);
            @(posedge clk);
            begin
                automatic logic [W*Z-1:0] expected;
                expected = expected_shift(data_in, s);
                if (data_out !== expected) begin
                    $display("FAIL: alternating shift=%0d", s);
                    errors++;
                end
                tests++;
            end
        end

        // =====================================================================
        // Test 4: Shift by 0 (identity)
        // =====================================================================
        $display("=== Test 4: Shift by 0 ===");
        for (int i = 0; i < Z; i++)
            data_in[i*W +: W] = (i * 3)[W-1:0];

        shift_val = 9'd0;
        @(posedge clk);
        @(posedge clk);
        @(posedge clk);
        begin
            automatic logic [W*Z-1:0] expected;
            expected = expected_shift(data_in, 0);
            if (data_out !== expected) begin
                $display("FAIL: shift=0");
                errors++;
            end
            tests++;
        end

        // =====================================================================
        // Report
        // =====================================================================
        $display("");
        if (errors == 0)
            $display("PASS: All %0d barrel_shifter tests passed.", tests);
        else
            $display("FAIL: %0d / %0d barrel_shifter tests failed.", errors, tests);

        $finish;
    end

endmodule
