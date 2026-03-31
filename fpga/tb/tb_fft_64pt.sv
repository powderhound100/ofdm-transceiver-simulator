// =============================================================================
// tb_fft_64pt.sv — Testbench for 64-point SDF FFT
// =============================================================================
// Tests: DC input, impulse, single tone at bin 4.
// iverilog v12 compatible: no automatic in initial, no unpacked array params,
// no '{ } array literals. Uses logic types.
// =============================================================================
`timescale 1ns / 1ps

module tb_fft_64pt;

    // Parameters
    localparam integer FFT_N = 64;
    localparam integer W_IN  = 16;
    localparam integer W_OUT = 16;
    localparam integer TW    = 12;
    localparam integer TOL   = 6;

    // Clock / reset
    logic clk;
    logic rst_n;

    // DUT signals
    logic signed [W_IN-1:0]  s_re;
    logic signed [W_IN-1:0]  s_im;
    logic                     s_valid;
    logic signed [W_OUT-1:0] m_re;
    logic signed [W_OUT-1:0] m_im;
    logic                     m_valid;
    logic                     m_last;

    // DUT
    fft_64pt #(
        .FFT_N(FFT_N),
        .W_IN (W_IN),
        .W_OUT(W_OUT),
        .TW   (TW)
    ) dut (
        .clk    (clk),
        .rst_n  (rst_n),
        .s_re   (s_re),
        .s_im   (s_im),
        .s_valid(s_valid),
        .m_re   (m_re),
        .m_im   (m_im),
        .m_valid(m_valid),
        .m_last (m_last)
    );

    // Clock generation: 100 MHz
    initial clk = 0;
    always #5 clk = ~clk;

    // Output capture arrays
    logic signed [W_OUT-1:0] out_re [0:FFT_N-1];
    logic signed [W_OUT-1:0] out_im [0:FFT_N-1];
    integer out_cnt;

    // Cosine table for bin-4 tone (precomputed: cos(2*pi*4*n/64) * 16384 in Q1.14)
    // cos(2*pi*4*n/64) = cos(pi*n/8)
    logic signed [15:0] cos_lut [0:63];
    initial begin
        cos_lut[0]  = 16'sd16384;  cos_lut[1]  = 16'sd15137;  cos_lut[2]  = 16'sd11585;
        cos_lut[3]  = 16'sd6270;   cos_lut[4]  = 16'sd0;      cos_lut[5]  = -16'sd6270;
        cos_lut[6]  = -16'sd11585; cos_lut[7]  = -16'sd15137; cos_lut[8]  = -16'sd16384;
        cos_lut[9]  = -16'sd15137; cos_lut[10] = -16'sd11585; cos_lut[11] = -16'sd6270;
        cos_lut[12] = 16'sd0;      cos_lut[13] = 16'sd6270;   cos_lut[14] = 16'sd11585;
        cos_lut[15] = 16'sd15137;  cos_lut[16] = 16'sd16384;  cos_lut[17] = 16'sd15137;
        cos_lut[18] = 16'sd11585;  cos_lut[19] = 16'sd6270;   cos_lut[20] = 16'sd0;
        cos_lut[21] = -16'sd6270;  cos_lut[22] = -16'sd11585; cos_lut[23] = -16'sd15137;
        cos_lut[24] = -16'sd16384; cos_lut[25] = -16'sd15137; cos_lut[26] = -16'sd11585;
        cos_lut[27] = -16'sd6270;  cos_lut[28] = 16'sd0;      cos_lut[29] = 16'sd6270;
        cos_lut[30] = 16'sd11585;  cos_lut[31] = 16'sd15137;  cos_lut[32] = 16'sd16384;
        cos_lut[33] = 16'sd15137;  cos_lut[34] = 16'sd11585;  cos_lut[35] = 16'sd6270;
        cos_lut[36] = 16'sd0;      cos_lut[37] = -16'sd6270;  cos_lut[38] = -16'sd11585;
        cos_lut[39] = -16'sd15137; cos_lut[40] = -16'sd16384; cos_lut[41] = -16'sd15137;
        cos_lut[42] = -16'sd11585; cos_lut[43] = -16'sd6270;  cos_lut[44] = 16'sd0;
        cos_lut[45] = 16'sd6270;   cos_lut[46] = 16'sd11585;  cos_lut[47] = 16'sd15137;
        cos_lut[48] = 16'sd16384;  cos_lut[49] = 16'sd15137;  cos_lut[50] = 16'sd11585;
        cos_lut[51] = 16'sd6270;   cos_lut[52] = 16'sd0;      cos_lut[53] = -16'sd6270;
        cos_lut[54] = -16'sd11585; cos_lut[55] = -16'sd15137; cos_lut[56] = -16'sd16384;
        cos_lut[57] = -16'sd15137; cos_lut[58] = -16'sd11585; cos_lut[59] = -16'sd6270;
        cos_lut[60] = 16'sd0;      cos_lut[61] = 16'sd6270;   cos_lut[62] = 16'sd11585;
        cos_lut[63] = 16'sd15137;
    end

    // Bit-reverse function for input ordering
    function [5:0] bit_reverse6;
        input [5:0] val;
        begin
            bit_reverse6 = {val[0], val[1], val[2], val[3], val[4], val[5]};
        end
    endfunction

    // Helpers
    integer errors;
    integer tests;
    integer i;
    integer timeout_cnt;

    // Task: collect 64 output samples
    task collect_outputs;
        begin
            out_cnt = 0;
            timeout_cnt = 0;
            while (out_cnt < FFT_N && timeout_cnt < 1000000) begin
                @(posedge clk);
                timeout_cnt = timeout_cnt + 1;
                if (m_valid) begin
                    out_re[out_cnt] = m_re;
                    out_im[out_cnt] = m_im;
                    out_cnt = out_cnt + 1;
                end
            end
            if (timeout_cnt >= 1000000) begin
                $display("FAIL: Timeout waiting for FFT output");
                errors = errors + 1;
            end
        end
    endtask

    // Task: apply reset
    task do_reset;
        begin
            rst_n = 0;
            s_re = 0;
            s_im = 0;
            s_valid = 0;
            repeat (10) @(posedge clk);
            rst_n = 1;
            repeat (5) @(posedge clk);
        end
    endtask

    // Absolute value helper
    function integer abs_val;
        input integer v;
        begin
            abs_val = (v < 0) ? -v : v;
        end
    endfunction

    // Main test
    initial begin
        $dumpfile("tb_fft_64pt.vcd");
        $dumpvars(0, tb_fft_64pt);

        errors = 0;
        tests  = 0;

        // =====================================================================
        // Test 1: DC — all 64 inputs = (8192, 0) = 0.5 in Q1.14
        // Expected: bin[0] has large magnitude, others ~0
        // DC sum = 64 * 8192 = 524288 (saturates to 32767 in 16-bit)
        // =====================================================================
        $display("=== Test 1: DC input ===");
        do_reset;

        for (i = 0; i < FFT_N; i = i + 1) begin
            @(posedge clk);
            s_re = 16'sd8192;
            s_im = 16'sd0;
            s_valid = 1;
        end
        @(posedge clk);
        s_valid = 0;
        s_re = 0;
        s_im = 0;

        collect_outputs;

        // Bin 0 should have a large value (positive or saturated)
        if (abs_val(out_re[0]) < 1000) begin
            $display("FAIL: Test1 bin[0] re=%0d too small, expected large DC", out_re[0]);
            errors = errors + 1;
        end
        tests = tests + 1;

        // All other bins should be near zero
        for (i = 1; i < FFT_N; i = i + 1) begin
            if (abs_val(out_re[i]) > 100 || abs_val(out_im[i]) > 100) begin
                $display("FAIL: Test1 bin[%0d] = (%0d, %0d), expected ~0", i, out_re[i], out_im[i]);
                errors = errors + 1;
            end
            tests = tests + 1;
        end

        // =====================================================================
        // Test 2: Impulse — x[0] = (16384, 0), rest = 0
        // Expected: all bins roughly equal magnitude (flat spectrum)
        // Without normalization, all bins = (16384, 0) ideally, but with
        // saturation and rounding, just check all bins have similar magnitude.
        // =====================================================================
        $display("=== Test 2: Impulse input ===");
        do_reset;

        for (i = 0; i < FFT_N; i = i + 1) begin
            @(posedge clk);
            if (bit_reverse6(i[5:0]) == 6'd0) begin
                s_re = 16'sd16384;
                s_im = 16'sd0;
            end else begin
                s_re = 16'sd0;
                s_im = 16'sd0;
            end
            s_valid = 1;
        end
        @(posedge clk);
        s_valid = 0;
        s_re = 0;
        s_im = 0;

        collect_outputs;

        // Check all bins have roughly equal magnitude
        begin
            integer min_mag, max_mag, mag;
            min_mag = 999999;
            max_mag = 0;
            for (i = 0; i < FFT_N; i = i + 1) begin
                mag = abs_val(out_re[i]) + abs_val(out_im[i]); // Manhattan distance
                if (mag < min_mag) min_mag = mag;
                if (mag > max_mag) max_mag = mag;
            end
            $display("  Impulse: min_mag=%0d, max_mag=%0d", min_mag, max_mag);
            // All magnitudes should be within a reasonable range of each other
            if (min_mag == 0 || max_mag > 4 * min_mag) begin
                $display("FAIL: Test2 impulse spectrum not flat enough (min=%0d, max=%0d)", min_mag, max_mag);
                errors = errors + 1;
            end
            tests = tests + 1;
        end

        // =====================================================================
        // Test 3: Single tone at bin 4 — x[n] = cos(2*pi*4*n/64)
        // Expected: energy at bins 4 and 60 (conjugate symmetric)
        // =====================================================================
        $display("=== Test 3: Single tone at bin 4 ===");
        do_reset;

        // Feed samples in natural order; the FFT expects bit-reversed input
        // internally via its br_cnt mechanism. The FFT's sample_cnt increments
        // on each s_valid, so we feed samples in natural order and the FFT
        // handles bit-reversal internally.
        for (i = 0; i < FFT_N; i = i + 1) begin
            @(posedge clk);
            s_re = cos_lut[i];
            s_im = 16'sd0;
            s_valid = 1;
        end
        @(posedge clk);
        s_valid = 0;
        s_re = 0;
        s_im = 0;

        collect_outputs;

        // Bins 4 and 60 should have large magnitude
        begin
            integer mag4, mag60, mag_other;
            mag4  = abs_val(out_re[4]) + abs_val(out_im[4]);
            mag60 = abs_val(out_re[60]) + abs_val(out_im[60]);

            $display("  Bin[4]  = (%0d, %0d), mag=%0d", out_re[4], out_im[4], mag4);
            $display("  Bin[60] = (%0d, %0d), mag=%0d", out_re[60], out_im[60], mag60);

            if (mag4 < 1000) begin
                $display("FAIL: Test3 bin[4] magnitude too small: %0d", mag4);
                errors = errors + 1;
            end
            tests = tests + 1;

            if (mag60 < 1000) begin
                $display("FAIL: Test3 bin[60] magnitude too small: %0d", mag60);
                errors = errors + 1;
            end
            tests = tests + 1;

            // Other bins should be much smaller
            for (i = 0; i < FFT_N; i = i + 1) begin
                if (i != 4 && i != 60) begin
                    mag_other = abs_val(out_re[i]) + abs_val(out_im[i]);
                    if (mag_other > mag4 / 4) begin
                        $display("FAIL: Test3 bin[%0d] = (%0d, %0d) has unexpected energy",
                                 i, out_re[i], out_im[i]);
                        errors = errors + 1;
                    end
                    tests = tests + 1;
                end
            end
        end

        // =====================================================================
        // Report
        // =====================================================================
        $display("");
        if (errors == 0)
            $display("PASS: All %0d fft_64pt tests passed.", tests);
        else
            $display("FAIL: %0d / %0d fft_64pt tests failed.", errors, tests);

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
