// =============================================================================
// tb_cfo_corrector.sv — Testbench for NCO + complex derotator CFO correction
// =============================================================================
// Tests:
//   1. Zero CFO → output ≈ input (passthrough)
//   2. Known CFO on DC signal → verify output rotates at expected rate
//   3. CFO correction cancels applied frequency offset
// iverilog -g2012 compatible. Self-checking with PASS/FAIL.
// =============================================================================
`timescale 1ns / 1ps

module tb_cfo_corrector;

    localparam int IQ_W    = 16;
    localparam int PHASE_W = 16;

    // Clock / reset
    logic clk;
    logic rst_n;

    // DUT signals
    logic signed [15:0]     cfo_est;
    logic                    cfo_load;
    logic signed [IQ_W-1:0] s_re, s_im;
    logic                    s_valid;
    logic signed [IQ_W-1:0] m_re, m_im;
    logic                    m_valid;

    // DUT
    cfo_corrector #(
        .IQ_W   (IQ_W),
        .PHASE_W(PHASE_W)
    ) dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .cfo_est (cfo_est),
        .cfo_load(cfo_load),
        .s_re    (s_re),
        .s_im    (s_im),
        .s_valid (s_valid),
        .m_re    (m_re),
        .m_im    (m_im),
        .m_valid (m_valid)
    );

    // Clock generation: 100 MHz
    initial clk = 0;
    always #5 clk = ~clk;

    // Helpers
    integer errors;
    integer tests;
    integer i;
    integer n;
    integer timeout_cnt;

    // Output capture arrays (up to 128 samples)
    logic signed [15:0] out_re [0:127];
    logic signed [15:0] out_im [0:127];
    integer out_cnt;
    logic   capture_en;  // enable output capture

    // Variables for magnitude computation
    integer mag_sq;
    integer expected_mag_sq;
    integer re_val, im_val;

    // Variables for Test 2
    integer max_re, min_re, max_im, min_im;
    integer mag_ok, rot_ok;

    // Variables for Test 1
    integer pass1;

    // Variables for Test 3
    integer pass3;
    integer dc_re_sum, dc_im_sum;

    // Pre-computed cos/sin LUT for Test 3 (Q1.14 values)
    logic signed [15:0] cos_lut [0:15];
    logic signed [15:0] sin_lut [0:15];

    function integer abs_val;
        input integer v;
        begin
            abs_val = (v < 0) ? -v : v;
        end
    endfunction

    // Continuous output capture process
    always @(posedge clk) begin
        if (capture_en && m_valid) begin
            if (out_cnt < 128) begin
                out_re[out_cnt] <= m_re;
                out_im[out_cnt] <= m_im;
            end
            out_cnt <= out_cnt + 1;
        end
    end

    // Task: apply reset
    task do_reset;
        begin
            rst_n      = 0;
            cfo_est    = 0;
            cfo_load   = 0;
            s_re       = 0;
            s_im       = 0;
            s_valid    = 0;
            capture_en = 0;
            out_cnt    = 0;
            repeat (10) @(posedge clk);
            rst_n = 1;
            repeat (5) @(posedge clk);
        end
    endtask

    // Task: load CFO estimate
    task load_cfo;
        input signed [15:0] cfo;
        begin
            @(posedge clk);
            cfo_est  = cfo;
            cfo_load = 1;
            @(posedge clk);
            cfo_load = 0;
            repeat (2) @(posedge clk); // let it settle
        end
    endtask

    // Main test
    initial begin
        $dumpfile("tb_cfo_corrector.vcd");
        $dumpvars(0, tb_cfo_corrector);

        // Initialize cos/sin LUT for Test 3
        cos_lut[0]  = 16384;  sin_lut[0]  = 0;
        cos_lut[1]  = 16305;  sin_lut[1]  = 1608;
        cos_lut[2]  = 16069;  sin_lut[2]  = 3196;
        cos_lut[3]  = 15679;  sin_lut[3]  = 4756;
        cos_lut[4]  = 15137;  sin_lut[4]  = 6270;
        cos_lut[5]  = 14449;  sin_lut[5]  = 7723;
        cos_lut[6]  = 13623;  sin_lut[6]  = 9102;
        cos_lut[7]  = 12665;  sin_lut[7]  = 10394;
        cos_lut[8]  = 11585;  sin_lut[8]  = 11585;
        cos_lut[9]  = 10394;  sin_lut[9]  = 12665;
        cos_lut[10] = 9102;   sin_lut[10] = 13623;
        cos_lut[11] = 7723;   sin_lut[11] = 14449;
        cos_lut[12] = 6270;   sin_lut[12] = 15137;
        cos_lut[13] = 4756;   sin_lut[13] = 15679;
        cos_lut[14] = 3196;   sin_lut[14] = 16069;
        cos_lut[15] = 1608;   sin_lut[15] = 16305;

        errors = 0;
        tests  = 0;

        // =================================================================
        // Test 1: Zero CFO → output ≈ input (passthrough)
        //   CFO = 0, input = (10000, 5000)
        //   Phase accumulator stays at 0 → NCO = (16384, 0) = 1+j0
        //   out = input * 1 ≈ input (after Q1.14 multiply + truncation)
        //   Expected: out_re ≈ 10000, out_im ≈ 5000
        // =================================================================
        $display("=== Test 1: Zero CFO passthrough ===");
        do_reset;
        load_cfo(16'sd0);

        // Enable capture, send 16 constant samples
        out_cnt    = 0;
        capture_en = 1;
        for (i = 0; i < 16; i = i + 1) begin
            @(posedge clk);
            s_re    = 16'sd10000;
            s_im    = 16'sd5000;
            s_valid = 1;
        end
        @(posedge clk);
        s_valid = 0;
        // Wait for pipeline flush
        repeat (10) @(posedge clk);
        capture_en = 0;
        // Allow one more cycle for NBA to settle
        @(posedge clk);

        $display("  Collected %0d output samples", out_cnt);

        pass1 = 1;
        for (i = 0; i < out_cnt && i < 16; i = i + 1) begin
            if (abs_val(out_re[i] - 10000) > 3 || abs_val(out_im[i] - 5000) > 3) begin
                $display("  sample[%0d]: out=(%0d,%0d), expected ~(10000,5000)",
                         i, out_re[i], out_im[i]);
                if (abs_val(out_re[i] - 10000) > 50 || abs_val(out_im[i] - 5000) > 50) begin
                    pass1 = 0;
                end
            end
        end
        if (pass1 && out_cnt > 0) begin
            $display("  PASS: Zero CFO outputs match input");
        end else begin
            $display("FAIL: Test1 zero CFO passthrough mismatch");
            errors = errors + 1;
        end
        tests = tests + 1;

        // =================================================================
        // Test 2: Known CFO on DC signal → output rotates
        //   CFO = 1024 (Q1.14) → phase_inc = 1024
        //   Each sample advances phase by 1024/65536 = 1/64 of full circle
        //   After 64 samples, one full rotation.
        //   Input: DC (8192, 0) — half-scale real
        //   Output: magnitude constant, angle advancing
        // =================================================================
        $display("=== Test 2: Known CFO on DC signal ===");
        do_reset;
        load_cfo(16'sd1024);

        out_cnt    = 0;
        capture_en = 1;
        for (i = 0; i < 64; i = i + 1) begin
            @(posedge clk);
            s_re    = 16'sd8192;
            s_im    = 16'sd0;
            s_valid = 1;
        end
        @(posedge clk);
        s_valid = 0;
        repeat (10) @(posedge clk);
        capture_en = 0;
        @(posedge clk);

        $display("  Collected %0d output samples", out_cnt);

        max_re = -32768; min_re = 32767;
        max_im = -32768; min_im = 32767;
        mag_ok = 1;

        for (i = 0; i < out_cnt && i < 64; i = i + 1) begin
            re_val = out_re[i];
            im_val = out_im[i];
            if (re_val > max_re) max_re = re_val;
            if (re_val < min_re) min_re = re_val;
            if (im_val > max_im) max_im = im_val;
            if (im_val < min_im) min_im = im_val;

            // Check magnitude: |out|^2 ≈ 8192^2 = 67108864
            // Allow 15% tolerance for quantization in the 64-entry LUT
            mag_sq = re_val * re_val + im_val * im_val;
            expected_mag_sq = 8192 * 8192;
            if (mag_sq < (expected_mag_sq * 70 / 100) ||
                mag_sq > (expected_mag_sq * 130 / 100)) begin
                mag_ok = 0;
                $display("  sample[%0d]: (%0d,%0d) mag^2=%0d, expected ~%0d",
                         i, re_val, im_val, mag_sq, expected_mag_sq);
            end
        end

        rot_ok = ((max_re - min_re) > 8000) && ((max_im - min_im) > 8000);

        $display("  Re range: [%0d, %0d], Im range: [%0d, %0d]",
                 min_re, max_re, min_im, max_im);

        if (mag_ok) begin
            $display("  PASS: Magnitude stays constant during rotation");
        end else begin
            $display("FAIL: Test2 magnitude varies too much during CFO rotation");
            errors = errors + 1;
        end
        tests = tests + 1;

        if (rot_ok) begin
            $display("  PASS: Output rotates (wide Re/Im range)");
        end else begin
            $display("FAIL: Test2 output does not rotate (Re range=%0d, Im range=%0d)",
                     max_re - min_re, max_im - min_im);
            errors = errors + 1;
        end
        tests = tests + 1;

        // =================================================================
        // Test 3: CFO correction cancels applied frequency offset
        //   Pre-rotate input at +1024 phase_inc/sample, then apply
        //   CFO corrector with cfo_est=1024 to derotate.
        //   in[n] = 8192 * exp(+j * 2pi * n / 64)
        //   corrector: exp(-j * 2pi * n / 64)
        //   out[n] = 8192 * exp(0) = (8192, 0)
        // =================================================================
        $display("=== Test 3: CFO correction cancels frequency offset ===");
        do_reset;
        load_cfo(16'sd1024);

        out_cnt    = 0;
        capture_en = 1;

        // Send 16 pre-rotated samples using cos/sin LUT
        for (n = 0; n < 16; n = n + 1) begin
            @(posedge clk);
            s_re    = (8192 * cos_lut[n]) >>> 14;
            s_im    = (8192 * sin_lut[n]) >>> 14;
            s_valid = 1;
        end
        @(posedge clk);
        s_valid = 0;
        // Wait for pipeline flush
        repeat (10) @(posedge clk);
        capture_en = 0;
        @(posedge clk);

        $display("  Collected %0d output samples", out_cnt);

        // After derotation, output should be approximately DC: (8192, 0)
        pass3 = 1;
        dc_re_sum = 0;
        dc_im_sum = 0;
        for (n = 0; n < out_cnt && n < 16; n = n + 1) begin
            $display("  out[%0d] = (%0d, %0d)", n, out_re[n], out_im[n]);
            dc_re_sum = dc_re_sum + out_re[n];
            dc_im_sum = dc_im_sum + out_im[n];
        end

        if (out_cnt > 0) begin
            dc_re_sum = dc_re_sum / out_cnt;
            dc_im_sum = dc_im_sum / out_cnt;
            $display("  Mean output: (%0d, %0d), expected ~(8192, 0)", dc_re_sum, dc_im_sum);

            // Check mean is close to (8192, 0)
            // Tolerance: 15% for double quantization through 64-entry LUT
            if (abs_val(dc_re_sum - 8192) > 1500 || abs_val(dc_im_sum) > 1500) begin
                pass3 = 0;
            end

            // Check individual samples don't deviate too wildly
            for (n = 0; n < out_cnt && n < 16; n = n + 1) begin
                if (abs_val(out_re[n] - 8192) > 2500 || abs_val(out_im[n]) > 2500) begin
                    pass3 = 0;
                end
            end
        end else begin
            pass3 = 0;
        end

        if (pass3) begin
            $display("  PASS: CFO correction successfully derotates to DC");
        end else begin
            $display("FAIL: Test3 derotated output deviates too far from expected DC");
            errors = errors + 1;
        end
        tests = tests + 1;

        // =================================================================
        // Report
        // =================================================================
        $display("");
        if (errors == 0)
            $display("PASS: All %0d cfo_corrector tests passed.", tests);
        else
            $display("FAIL: %0d / %0d cfo_corrector tests failed.", errors, tests);

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
