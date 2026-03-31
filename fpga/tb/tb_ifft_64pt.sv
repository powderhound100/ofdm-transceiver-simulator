// =============================================================================
// tb_ifft_64pt.sv — Testbench for 64-point IFFT (conjugate-FFT method)
// =============================================================================
// Tests:
//   1. DC only: X[0]=16384, rest=0 -> flat time domain ~256
//   2. Single bin at k=4: X[4]=16384 -> cos(2*pi*4*n/64) * 256
//   3. All-equal frequency: X[k]=256 for all k -> impulse at n=0
//
// RTL dependencies:
//   ifft_64pt.sv, fft_64pt.sv, twiddle_rom.sv
//
// Compile (iverilog v12):
//   iverilog -g2012 -o tb_ifft_64pt \
//     ../rtl/twiddle_rom.sv ../rtl/fft_64pt.sv ../rtl/ifft_64pt.sv \
//     tb_ifft_64pt.sv
// =============================================================================
`timescale 1ns / 1ps

module tb_ifft_64pt;

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    localparam integer FFT_N = 64;
    localparam integer W     = 16;
    localparam integer TW    = 12;

    // Tolerance for fixed-point comparison (accounts for twiddle quantization
    // and rounding through 6 SDF stages + IFFT /64 rounding)
    localparam integer TOL   = 20;

    // -------------------------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------------------------
    logic                  clk;
    logic                  rst_n;
    logic signed [W-1:0]  s_re;
    logic signed [W-1:0]  s_im;
    logic                  s_valid;
    logic signed [W-1:0]  m_re;
    logic signed [W-1:0]  m_im;
    logic                  m_valid;
    logic                  m_last;

    // -------------------------------------------------------------------------
    // DUT instantiation
    // -------------------------------------------------------------------------
    ifft_64pt #(
        .FFT_N (FFT_N),
        .W     (W),
        .TW    (TW)
    ) dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .s_re    (s_re),
        .s_im    (s_im),
        .s_valid (s_valid),
        .m_re    (m_re),
        .m_im    (m_im),
        .m_valid (m_valid),
        .m_last  (m_last)
    );

    // -------------------------------------------------------------------------
    // Clock generation: 100 MHz
    // -------------------------------------------------------------------------
    initial clk = 0;
    always #5 clk = ~clk;

    // -------------------------------------------------------------------------
    // Timeout watchdog: 10 ms
    // -------------------------------------------------------------------------
    initial begin
        #10_000_000;
        $display("FAIL: Global timeout (10 ms)");
        $finish;
    end

    // -------------------------------------------------------------------------
    // Output capture arrays
    // -------------------------------------------------------------------------
    logic signed [W-1:0] out_re [0:FFT_N-1];
    logic signed [W-1:0] out_im [0:FFT_N-1];
    integer out_idx;
    integer timeout_cnt;

    // -------------------------------------------------------------------------
    // Cosine LUT for Test 2 expected values
    // -------------------------------------------------------------------------
    // IFFT of X[4]=16384, rest=0 should produce:
    //   x[n] = (16384/64) * cos(2*pi*4*n/64) = 256 * cos(pi*n/8)
    // Precomputed: round(256 * cos(2*pi*4*n/64)) for n = 0..63
    logic signed [W-1:0] cos4_lut [0:63];
    initial begin
        cos4_lut[0]  =  16'sd256;   cos4_lut[1]  =  16'sd237;
        cos4_lut[2]  =  16'sd181;   cos4_lut[3]  =  16'sd98;
        cos4_lut[4]  =  16'sd0;     cos4_lut[5]  = -16'sd98;
        cos4_lut[6]  = -16'sd181;   cos4_lut[7]  = -16'sd237;
        cos4_lut[8]  = -16'sd256;   cos4_lut[9]  = -16'sd237;
        cos4_lut[10] = -16'sd181;   cos4_lut[11] = -16'sd98;
        cos4_lut[12] =  16'sd0;     cos4_lut[13] =  16'sd98;
        cos4_lut[14] =  16'sd181;   cos4_lut[15] =  16'sd237;
        cos4_lut[16] =  16'sd256;   cos4_lut[17] =  16'sd237;
        cos4_lut[18] =  16'sd181;   cos4_lut[19] =  16'sd98;
        cos4_lut[20] =  16'sd0;     cos4_lut[21] = -16'sd98;
        cos4_lut[22] = -16'sd181;   cos4_lut[23] = -16'sd237;
        cos4_lut[24] = -16'sd256;   cos4_lut[25] = -16'sd237;
        cos4_lut[26] = -16'sd181;   cos4_lut[27] = -16'sd98;
        cos4_lut[28] =  16'sd0;     cos4_lut[29] =  16'sd98;
        cos4_lut[30] =  16'sd181;   cos4_lut[31] =  16'sd237;
        cos4_lut[32] =  16'sd256;   cos4_lut[33] =  16'sd237;
        cos4_lut[34] =  16'sd181;   cos4_lut[35] =  16'sd98;
        cos4_lut[36] =  16'sd0;     cos4_lut[37] = -16'sd98;
        cos4_lut[38] = -16'sd181;   cos4_lut[39] = -16'sd237;
        cos4_lut[40] = -16'sd256;   cos4_lut[41] = -16'sd237;
        cos4_lut[42] = -16'sd181;   cos4_lut[43] = -16'sd98;
        cos4_lut[44] =  16'sd0;     cos4_lut[45] =  16'sd98;
        cos4_lut[46] =  16'sd181;   cos4_lut[47] =  16'sd237;
        cos4_lut[48] =  16'sd256;   cos4_lut[49] =  16'sd237;
        cos4_lut[50] =  16'sd181;   cos4_lut[51] =  16'sd98;
        cos4_lut[52] =  16'sd0;     cos4_lut[53] = -16'sd98;
        cos4_lut[54] = -16'sd181;   cos4_lut[55] = -16'sd237;
        cos4_lut[56] = -16'sd256;   cos4_lut[57] = -16'sd237;
        cos4_lut[58] = -16'sd181;   cos4_lut[59] = -16'sd98;
        cos4_lut[60] =  16'sd0;     cos4_lut[61] =  16'sd98;
        cos4_lut[62] =  16'sd181;   cos4_lut[63] =  16'sd237;
    end

    // -------------------------------------------------------------------------
    // Module-level variables (iverilog compatibility: no automatic in initial)
    // -------------------------------------------------------------------------
    integer pass_count;
    integer fail_count;
    integer errors;
    integer i;
    integer m_last_count;
    integer diff;

    // -------------------------------------------------------------------------
    // Absolute value helper
    // -------------------------------------------------------------------------
    function integer abs_val;
        input integer v;
        begin
            abs_val = (v < 0) ? -v : v;
        end
    endfunction

    // -------------------------------------------------------------------------
    // Task: apply reset
    // -------------------------------------------------------------------------
    task do_reset;
        begin
            rst_n   = 1'b0;
            s_re    = 0;
            s_im    = 0;
            s_valid = 1'b0;
            repeat (10) @(posedge clk);
            rst_n = 1'b1;
            repeat (5) @(posedge clk);
        end
    endtask

    // -------------------------------------------------------------------------
    // Task: collect 64 output samples
    // -------------------------------------------------------------------------
    task collect_outputs;
        begin
            out_idx     = 0;
            timeout_cnt = 0;
            m_last_count = 0;
            while (out_idx < FFT_N && timeout_cnt < 1_000_000) begin
                @(posedge clk);
                timeout_cnt = timeout_cnt + 1;
                if (m_valid) begin
                    out_re[out_idx] = m_re;
                    out_im[out_idx] = m_im;
                    if (m_last)
                        m_last_count = m_last_count + 1;
                    out_idx = out_idx + 1;
                end
            end
            if (timeout_cnt >= 1_000_000) begin
                $display("FAIL: Timeout waiting for IFFT output (collected %0d/%0d)",
                         out_idx, FFT_N);
                errors = errors + 1;
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Main test sequence
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("tb_ifft_64pt.vcd");
        $dumpvars(0, tb_ifft_64pt);

        pass_count = 0;
        fail_count = 0;

        // =================================================================
        // TEST 1: DC only — X[0] = 16384, X[k]=0 for k>0
        // -----------------------------------------------------------------
        // IFFT: x[n] = (1/64) * sum_{k=0}^{63} X[k] * exp(j2pi*kn/64)
        //            = (1/64) * X[0] = 16384/64 = 256 for all n
        // Expected: all samples approximately (256, 0)
        // =================================================================
        $display("\n=== TEST 1: DC only (X[0]=16384, rest=0) ===");
        do_reset;
        errors = 0;

        // Feed 64 frequency-domain samples in natural order.
        // The IFFT conjugates and feeds into FFT which handles ordering.
        for (i = 0; i < FFT_N; i = i + 1) begin
            @(posedge clk);
            if (i == 0) begin
                s_re = 16'sd16384;
                s_im = 16'sd0;
            end else begin
                s_re = 16'sd0;
                s_im = 16'sd0;
            end
            s_valid = 1'b1;
        end
        @(posedge clk);
        s_valid = 1'b0;
        s_re    = 0;
        s_im    = 0;

        collect_outputs;

        // Verify: all samples should be near (256, 0)
        for (i = 0; i < FFT_N; i = i + 1) begin
            diff = abs_val(out_re[i] - 256);
            if (diff > TOL) begin
                $display("  FAIL: x[%0d].re = %0d, expected ~256 (diff=%0d, tol=%0d)",
                         i, out_re[i], diff, TOL);
                errors = errors + 1;
            end
            diff = abs_val(out_im[i]);
            if (diff > TOL) begin
                $display("  FAIL: x[%0d].im = %0d, expected ~0 (diff=%0d, tol=%0d)",
                         i, out_im[i], diff, TOL);
                errors = errors + 1;
            end
        end

        // Verify m_last was asserted exactly once
        if (m_last_count != 1) begin
            $display("  FAIL: m_last asserted %0d times, expected 1", m_last_count);
            errors = errors + 1;
        end

        $display("  Sample dump: x[0]=(%0d,%0d) x[1]=(%0d,%0d) x[32]=(%0d,%0d) x[63]=(%0d,%0d)",
                 out_re[0], out_im[0], out_re[1], out_im[1],
                 out_re[32], out_im[32], out_re[63], out_im[63]);

        if (errors == 0) begin
            $display("  TEST 1: PASS");
            pass_count = pass_count + 1;
        end else begin
            $display("  TEST 1: FAIL (%0d errors)", errors);
            fail_count = fail_count + 1;
        end

        // =================================================================
        // TEST 2: Single bin at k=4 — X[4] = 16384 (real), rest = 0
        // -----------------------------------------------------------------
        // IFFT: x[n] = (16384/64) * exp(j*2*pi*4*n/64)
        //            = 256 * [cos(2*pi*4*n/64) + j*sin(2*pi*4*n/64)]
        // Since X is purely real at bin 4 only (not Hermitian symmetric),
        // the time-domain will be complex:
        //   x[n].re = 256 * cos(2*pi*4*n/64)
        //   x[n].im = 256 * sin(2*pi*4*n/64)
        // =================================================================
        $display("\n=== TEST 2: Single bin k=4 (X[4]=16384) ===");
        do_reset;
        errors = 0;

        for (i = 0; i < FFT_N; i = i + 1) begin
            @(posedge clk);
            if (i == 4) begin
                s_re = 16'sd16384;
                s_im = 16'sd0;
            end else begin
                s_re = 16'sd0;
                s_im = 16'sd0;
            end
            s_valid = 1'b1;
        end
        @(posedge clk);
        s_valid = 1'b0;
        s_re    = 0;
        s_im    = 0;

        collect_outputs;

        // Verify real part matches cosine pattern
        $display("  Checking real part against 256*cos(2*pi*4*n/64)...");
        for (i = 0; i < FFT_N; i = i + 1) begin
            diff = abs_val(out_re[i] - cos4_lut[i]);
            if (diff > TOL) begin
                $display("  FAIL: x[%0d].re = %0d, expected %0d (diff=%0d, tol=%0d)",
                         i, out_re[i], cos4_lut[i], diff, TOL);
                errors = errors + 1;
            end
        end

        // Verify: check that the waveform has the correct period
        // cos(2*pi*4*n/64) has period 64/4 = 16 samples
        // So x[0] should equal x[16] and x[32] and x[48]
        begin
            integer period_err;
            period_err = 0;
            for (i = 0; i < FFT_N - 16; i = i + 1) begin
                if (abs_val(out_re[i] - out_re[i + 16]) > TOL)
                    period_err = period_err + 1;
            end
            if (period_err > 0) begin
                $display("  FAIL: Real part period-16 check failed (%0d mismatches)", period_err);
                errors = errors + 1;
            end else begin
                $display("  Real part period-16 check: OK");
            end
        end

        // Verify m_last
        if (m_last_count != 1) begin
            $display("  FAIL: m_last asserted %0d times, expected 1", m_last_count);
            errors = errors + 1;
        end

        $display("  Sample dump: x[0]=(%0d,%0d) x[4]=(%0d,%0d) x[8]=(%0d,%0d) x[16]=(%0d,%0d)",
                 out_re[0], out_im[0], out_re[4], out_im[4],
                 out_re[8], out_im[8], out_re[16], out_im[16]);

        if (errors == 0) begin
            $display("  TEST 2: PASS");
            pass_count = pass_count + 1;
        end else begin
            $display("  TEST 2: FAIL (%0d errors)", errors);
            fail_count = fail_count + 1;
        end

        // =================================================================
        // TEST 3: All-equal frequency bins — X[k] = 256 for all k
        // -----------------------------------------------------------------
        // IFFT: x[n] = (1/64) * sum_{k=0}^{63} 256 * exp(j*2*pi*kn/64)
        //            = (256/64) * 64 * delta[n] = 256 * delta[n]
        // i.e. x[0] = 256, x[n] = 0 for n > 0  (impulse in time domain)
        //
        // Due to /64 and the sum of twiddles being a Kronecker delta,
        // IFFT of a flat spectrum = impulse at n=0.
        // =================================================================
        $display("\n=== TEST 3: All bins equal (X[k]=256 for all k) -> impulse ===");
        do_reset;
        errors = 0;

        for (i = 0; i < FFT_N; i = i + 1) begin
            @(posedge clk);
            s_re    = 16'sd256;
            s_im    = 16'sd0;
            s_valid = 1'b1;
        end
        @(posedge clk);
        s_valid = 1'b0;
        s_re    = 0;
        s_im    = 0;

        collect_outputs;

        // x[0] should be ~256, all others ~0
        diff = abs_val(out_re[0] - 256);
        if (diff > TOL) begin
            $display("  FAIL: x[0].re = %0d, expected ~256 (diff=%0d)", out_re[0], diff);
            errors = errors + 1;
        end
        diff = abs_val(out_im[0]);
        if (diff > TOL) begin
            $display("  FAIL: x[0].im = %0d, expected ~0 (diff=%0d)", out_im[0], diff);
            errors = errors + 1;
        end

        for (i = 1; i < FFT_N; i = i + 1) begin
            if (abs_val(out_re[i]) > TOL || abs_val(out_im[i]) > TOL) begin
                $display("  FAIL: x[%0d] = (%0d, %0d), expected ~(0, 0)",
                         i, out_re[i], out_im[i]);
                errors = errors + 1;
            end
        end

        // Verify m_last
        if (m_last_count != 1) begin
            $display("  FAIL: m_last asserted %0d times, expected 1", m_last_count);
            errors = errors + 1;
        end

        $display("  Sample dump: x[0]=(%0d,%0d) x[1]=(%0d,%0d) x[2]=(%0d,%0d) x[63]=(%0d,%0d)",
                 out_re[0], out_im[0], out_re[1], out_im[1],
                 out_re[2], out_im[2], out_re[63], out_im[63]);

        if (errors == 0) begin
            $display("  TEST 3: PASS");
            pass_count = pass_count + 1;
        end else begin
            $display("  TEST 3: FAIL (%0d errors)", errors);
            fail_count = fail_count + 1;
        end

        // =================================================================
        // Summary
        // =================================================================
        $display("\n===================================");
        $display("  RESULTS: %0d PASS, %0d FAIL", pass_count, fail_count);
        if (fail_count == 0)
            $display("  ALL TESTS PASSED");
        else
            $display("  SOME TESTS FAILED");
        $display("===================================\n");

        #100;
        $finish;
    end

endmodule
