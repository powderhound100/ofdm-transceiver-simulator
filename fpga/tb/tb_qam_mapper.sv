// =============================================================================
// tb_qam_mapper.sv — Testbench for QAM Symbol Mapper
// =============================================================================
// Tests: QPSK bits 00, 10, 11, and 8-bit sequence.
// iverilog v12 compatible.
// =============================================================================
`timescale 1ns / 1ps

module tb_qam_mapper;

    // Clock / reset
    logic        clk;
    logic        rst_n;

    // DUT signals
    logic        bit_in;
    logic        bit_valid;
    logic [3:0]  cfg_modulation;
    logic [31:0] sym_out;
    logic        sym_valid;

    // DUT
    qam_mapper dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .bit_in        (bit_in),
        .bit_valid     (bit_valid),
        .cfg_modulation(cfg_modulation),
        .sym_out       (sym_out),
        .sym_valid     (sym_valid)
    );

    // Clock: 100 MHz
    initial clk = 0;
    always #5 clk = ~clk;

    // Helpers
    integer errors;
    integer tests;
    integer timeout_cnt;
    integer i;

    // Expected QPSK values
    localparam signed [15:0] QPSK_POS =  16'sd11585;
    localparam signed [15:0] QPSK_NEG = -16'sd11585;

    logic signed [15:0] cap_re;
    logic signed [15:0] cap_im;

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
            bit_in         = 0;
            bit_valid      = 0;
            cfg_modulation = 4'd0; // QPSK
            repeat (10) @(posedge clk);
            rst_n = 1;
            repeat (5) @(posedge clk);
        end
    endtask

    // Task: send 2 bits for QPSK and capture symbol
    // Bits are sent MSB first: b1 then b0
    task send_qpsk_bits;
        input logic b1, b0;
        begin
            @(posedge clk);
            bit_in    = b1; // first bit (I sign)
            bit_valid = 1;
            @(posedge clk);
            bit_in    = b0; // second bit (Q sign)
            bit_valid = 1;
            @(posedge clk);
            bit_valid = 0;

            // Wait for sym_valid
            timeout_cnt = 0;
            while (!sym_valid && timeout_cnt < 100) begin
                @(posedge clk);
                timeout_cnt = timeout_cnt + 1;
            end

            // Capture on the cycle sym_valid is asserted
            // sym_valid may already be high
            if (sym_valid) begin
                cap_re = $signed(sym_out[15:0]);
                cap_im = $signed(sym_out[31:16]);
            end else begin
                $display("FAIL: Timeout waiting for sym_valid");
                errors = errors + 1;
                cap_re = 0;
                cap_im = 0;
            end
        end
    endtask

    // Captured symbols for Test 4
    logic signed [15:0] sym_re_arr [0:3];
    logic signed [15:0] sym_im_arr [0:3];
    integer sym_cnt;

    // Main test
    initial begin
        $dumpfile("tb_qam_mapper.vcd");
        $dumpvars(0, tb_qam_mapper);

        errors = 0;
        tests  = 0;

        // =====================================================================
        // Test 1: QPSK bits [0,0] -> (+11585, +11585)
        // bit_sr = {b1=0, b0=0}
        // bit_sr[1]=0 -> map_i=POS, bit_sr[0]=0 -> map_q=POS
        // But output: {Q, I} = {map_q, map_i}
        // In the RTL, bit_sr[0] is b0 (last bit sent), and the sym_out
        // uses bit_sr[0] for I and bit_in for Q in the completion cycle.
        // =====================================================================
        $display("=== Test 1: QPSK bits [0,0] ===");
        do_reset;
        send_qpsk_bits(1'b0, 1'b0);
        $display("  Symbol: I=%0d, Q=%0d", cap_re, cap_im);
        if (abs_val(cap_re - QPSK_POS) > 1 || abs_val(cap_im - QPSK_POS) > 1) begin
            $display("FAIL: Test1 got (%0d,%0d), expected (%0d,%0d)",
                     cap_re, cap_im, QPSK_POS, QPSK_POS);
            errors = errors + 1;
        end
        tests = tests + 1;

        // =====================================================================
        // Test 2: QPSK bits [1,0] -> (-11585, +11585)
        // bit_sr[0]=1 (I), bit_in=0 (Q) in completion cycle
        // =====================================================================
        $display("=== Test 2: QPSK bits [1,0] ===");
        do_reset;
        send_qpsk_bits(1'b1, 1'b0);
        $display("  Symbol: I=%0d, Q=%0d", cap_re, cap_im);
        if (abs_val(cap_re - QPSK_NEG) > 1 || abs_val(cap_im - QPSK_POS) > 1) begin
            $display("FAIL: Test2 got (%0d,%0d), expected (%0d,%0d)",
                     cap_re, cap_im, QPSK_NEG, QPSK_POS);
            errors = errors + 1;
        end
        tests = tests + 1;

        // =====================================================================
        // Test 3: QPSK bits [1,1] -> (-11585, -11585)
        // =====================================================================
        $display("=== Test 3: QPSK bits [1,1] ===");
        do_reset;
        send_qpsk_bits(1'b1, 1'b1);
        $display("  Symbol: I=%0d, Q=%0d", cap_re, cap_im);
        if (abs_val(cap_re - QPSK_NEG) > 1 || abs_val(cap_im - QPSK_NEG) > 1) begin
            $display("FAIL: Test3 got (%0d,%0d), expected (%0d,%0d)",
                     cap_re, cap_im, QPSK_NEG, QPSK_NEG);
            errors = errors + 1;
        end
        tests = tests + 1;

        // =====================================================================
        // Test 4: Feed 8 bits for QPSK -> 4 symbols, verify all
        // Bit stream: 0,0, 0,1, 1,0, 1,1 -> 4 symbols
        // =====================================================================
        $display("=== Test 4: 8 bits -> 4 QPSK symbols ===");
        do_reset;

        // Send 8 bits continuously and collect 4 symbols
        sym_cnt = 0;
        fork
            // Producer: send 8 bits
            begin
                logic [7:0] bits;
                bits = 8'b00_01_10_11;
                for (i = 7; i >= 0; i = i - 1) begin
                    @(posedge clk);
                    bit_in    = bits[i];
                    bit_valid = 1;
                end
                @(posedge clk);
                bit_valid = 0;
            end

            // Consumer: collect 4 symbols
            begin
                timeout_cnt = 0;
                while (sym_cnt < 4 && timeout_cnt < 200) begin
                    @(posedge clk);
                    timeout_cnt = timeout_cnt + 1;
                    if (sym_valid) begin
                        sym_re_arr[sym_cnt] = $signed(sym_out[15:0]);
                        sym_im_arr[sym_cnt] = $signed(sym_out[31:16]);
                        sym_cnt = sym_cnt + 1;
                    end
                end
            end
        join

        if (sym_cnt != 4) begin
            $display("FAIL: Test4 got %0d symbols, expected 4", sym_cnt);
            errors = errors + 1;
        end else begin
            $display("  Sym0: I=%0d Q=%0d", sym_re_arr[0], sym_im_arr[0]);
            $display("  Sym1: I=%0d Q=%0d", sym_re_arr[1], sym_im_arr[1]);
            $display("  Sym2: I=%0d Q=%0d", sym_re_arr[2], sym_im_arr[2]);
            $display("  Sym3: I=%0d Q=%0d", sym_re_arr[3], sym_im_arr[3]);

            // Verify all 4 symbols have valid QPSK magnitudes
            for (i = 0; i < 4; i = i + 1) begin
                if (abs_val(abs_val(sym_re_arr[i]) - 11585) > 1 ||
                    abs_val(abs_val(sym_im_arr[i]) - 11585) > 1) begin
                    $display("FAIL: Test4 sym[%0d]=(%0d,%0d) not valid QPSK",
                             i, sym_re_arr[i], sym_im_arr[i]);
                    errors = errors + 1;
                end
                tests = tests + 1;
            end
        end
        tests = tests + 1;

        // =====================================================================
        // Report
        // =====================================================================
        $display("");
        if (errors == 0)
            $display("PASS: All %0d qam_mapper tests passed.", tests);
        else
            $display("FAIL: %0d / %0d qam_mapper tests failed.", errors, tests);

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
