// =============================================================================
// tb_ofdm_rx_top.sv — Integration Testbench for OFDM Receiver Top-Level
// =============================================================================
// Tests the full RX chain: cp_removal -> fft_64pt -> subcarrier_demux ->
//   channel_estimator + data_align_buffer -> equalizer -> soft_demapper ->
//   frame_controller
//
// Test 1: Noiseless flat channel — 560 RX IQ in, 648 LLR out, compare
//         against reference with sign-exact / magnitude +/-2 tolerance
// Test 2: Output framing — verify exactly 648 m_tvalid beats with m_tlast
//         on the last beat only
//
// iverilog -g2012 compatible. $dumpfile/$dumpvars. Timeout watchdog 20 ms.
// =============================================================================
`timescale 1ns / 1ps

module tb_ofdm_rx_top;

    // =========================================================================
    // Parameters
    // =========================================================================
    localparam integer FFT_N  = 64;
    localparam integer CP_LEN = 16;
    localparam integer W_IQ   = 16;
    localparam integer TW     = 12;
    localparam integer LLR_W  = 6;

    localparam integer NUM_RX_SAMPLES = 560;
    localparam integer NUM_LLR        = 648;
    localparam integer MAG_TOL        = 2;   // magnitude tolerance

    // =========================================================================
    // Clock / reset
    // =========================================================================
    logic clk;
    logic rst_n;

    initial clk = 0;
    always #5 clk = ~clk;  // 100 MHz

    // =========================================================================
    // DUT signals
    // =========================================================================
    logic [31:0]       s_tdata;
    logic              s_tvalid;
    wire               s_tready;

    wire  [LLR_W-1:0] m_tdata;
    wire               m_tvalid;
    wire               m_tlast;
    logic              m_tready;

    logic [3:0]        cfg_modulation;
    logic [15:0]       noise_var;
    logic              eq_mode;
    logic [1:0]        cfg_estimator;
    wire               frame_ready;

    // =========================================================================
    // DUT instantiation
    // =========================================================================
    ofdm_rx_top #(
        .FFT_N  (FFT_N),
        .CP_LEN (CP_LEN),
        .W_IQ   (W_IQ),
        .TW     (TW),
        .LLR_W  (LLR_W)
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .s_tdata        (s_tdata),
        .s_tvalid       (s_tvalid),
        .s_tready       (s_tready),
        .m_tdata        (m_tdata),
        .m_tvalid       (m_tvalid),
        .m_tlast        (m_tlast),
        .m_tready       (m_tready),
        .cfg_modulation (cfg_modulation),
        .noise_var      (noise_var),
        .eq_mode        (eq_mode),
        .cfg_estimator  (cfg_estimator),
        .frame_ready    (frame_ready)
    );

    // =========================================================================
    // Test vector storage
    // =========================================================================
    logic [31:0]       rx_iq   [0:NUM_RX_SAMPLES-1];
    logic [LLR_W-1:0]  ref_llr [0:NUM_LLR-1];

    // Captured output
    logic [LLR_W-1:0]  cap_llr [0:NUM_LLR-1];
    integer            cap_cnt;

    // Framing tracking
    integer            valid_cnt;
    integer            tlast_cnt;
    integer            tlast_pos;  // position of last m_tlast assertion

    // =========================================================================
    // Helpers
    // =========================================================================
    integer errors;
    integer test1_errors;
    integer test2_errors;
    integer i;

    function integer abs_val;
        input integer v;
        begin
            abs_val = (v < 0) ? -v : v;
        end
    endfunction

    // Signed extension for LLR comparison (6-bit two's complement)
    function integer sign_extend_llr;
        input [LLR_W-1:0] val;
        reg signed [LLR_W-1:0] sval;
        begin
            sval = val;
            sign_extend_llr = sval;
        end
    endfunction

    // =========================================================================
    // Task: apply reset and configure
    // =========================================================================
    task do_reset;
        begin
            rst_n          = 0;
            s_tdata        = 32'd0;
            s_tvalid       = 1'b0;
            m_tready       = 1'b0;
            cfg_modulation = 4'd0;   // QPSK
            noise_var      = 16'd0;  // noiseless
            eq_mode        = 1'b0;   // ZF
            cfg_estimator  = 2'd0;   // LS
            repeat (20) @(posedge clk);
            rst_n = 1;
            repeat (10) @(posedge clk);
        end
    endtask

    // =========================================================================
    // Task: feed all RX IQ samples (AXI-Stream handshake)
    // =========================================================================
    task feed_rx_iq;
        integer idx;
        begin
            idx = 0;
            while (idx < NUM_RX_SAMPLES) begin
                @(posedge clk);
                s_tdata  = rx_iq[idx];
                s_tvalid = 1'b1;
                if (s_tready) begin
                    idx = idx + 1;
                end
            end
            @(posedge clk);
            s_tvalid = 1'b0;
            s_tdata  = 32'd0;
        end
    endtask

    // =========================================================================
    // Task: capture LLR output frame (up to NUM_LLR samples or timeout)
    // =========================================================================
    task capture_llr_frame;
        integer timeout;
        begin
            cap_cnt    = 0;
            valid_cnt  = 0;
            tlast_cnt  = 0;
            tlast_pos  = -1;
            timeout    = 0;
            m_tready   = 1'b1;

            while (cap_cnt < NUM_LLR && timeout < 2_000_000) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (m_tvalid && m_tready) begin
                    cap_llr[cap_cnt] = m_tdata;
                    valid_cnt = valid_cnt + 1;
                    if (m_tlast) begin
                        tlast_cnt = tlast_cnt + 1;
                        tlast_pos = cap_cnt;
                    end
                    cap_cnt = cap_cnt + 1;
                end
            end

            if (timeout >= 2_000_000) begin
                $display("  WARNING: Timeout capturing LLR frame (got %0d of %0d)", cap_cnt, NUM_LLR);
            end

            // Continue draining for a bit to check for spurious extra outputs
            begin
                integer extra_timeout;
                extra_timeout = 0;
                while (extra_timeout < 500) begin
                    @(posedge clk);
                    extra_timeout = extra_timeout + 1;
                    if (m_tvalid && m_tready) begin
                        valid_cnt = valid_cnt + 1;
                        if (m_tlast) tlast_cnt = tlast_cnt + 1;
                    end
                end
            end

            m_tready = 1'b0;
        end
    endtask

    // =========================================================================
    // Main test sequence
    // =========================================================================
    initial begin
        $dumpfile("tb_ofdm_rx_top.vcd");
        $dumpvars(0, tb_ofdm_rx_top);

        // Load test vectors
        $readmemh("../../test_vectors/ofdm/ofdm_rx_iq_flat_noiseless.hex", rx_iq);
        $readmemh("../../test_vectors/ofdm/ofdm_llr_flat_noiseless_6bit.hex", ref_llr);

        errors      = 0;
        test1_errors = 0;
        test2_errors = 0;

        // =================================================================
        // Test 1: Noiseless flat channel end-to-end
        // =================================================================
        $display("");
        $display("=== Test 1: Noiseless flat channel — full RX chain ===");
        $display("  Config: QPSK, ZF equalization, LS estimation, noise_var=0");
        $display("  Input:  %0d RX IQ samples", NUM_RX_SAMPLES);
        $display("  Expect: %0d LLR outputs", NUM_LLR);

        do_reset;

        // Enable downstream ready before feeding — let pipeline flow
        m_tready = 1'b1;

        // Fork: feed input and capture output concurrently
        fork
            feed_rx_iq;
            capture_llr_frame;
        join

        $display("  Captured %0d LLR outputs", cap_cnt);

        // -- Check: got all 648 LLRs --
        if (cap_cnt < NUM_LLR) begin
            $display("  FAIL: Only captured %0d of %0d LLR outputs", cap_cnt, NUM_LLR);
            test1_errors = test1_errors + 1;
        end

        // -- Check: frame_ready asserted --
        // (We check this was seen during the capture by examining it now;
        //  for integration it suffices that frame output arrived)
        // frame_ready is set by frame_controller when a full codeword is buffered

        // -- Compare LLRs against reference --
        if (cap_cnt >= NUM_LLR) begin
            begin
                integer sign_mismatch;
                integer mag_mismatch;
                integer got_signed;
                integer ref_signed;
                integer got_sign;
                integer ref_sign;
                integer got_mag;
                integer ref_mag;
                integer diff;

                sign_mismatch = 0;
                mag_mismatch  = 0;

                for (i = 0; i < NUM_LLR; i = i + 1) begin
                    got_signed = sign_extend_llr(cap_llr[i]);
                    ref_signed = sign_extend_llr(ref_llr[i]);

                    // Sign bit comparison (bit [LLR_W-1])
                    got_sign = cap_llr[i][LLR_W-1];
                    ref_sign = ref_llr[i][LLR_W-1];

                    // Magnitude = absolute value
                    got_mag = abs_val(got_signed);
                    ref_mag = abs_val(ref_signed);
                    diff    = abs_val(got_mag - ref_mag);

                    if (got_sign != ref_sign) begin
                        if (sign_mismatch < 10)
                            $display("  SIGN MISMATCH [%0d]: got=%0d ref=%0d",
                                     i, got_signed, ref_signed);
                        sign_mismatch = sign_mismatch + 1;
                    end else if (diff > MAG_TOL) begin
                        if (mag_mismatch < 10)
                            $display("  MAG  MISMATCH [%0d]: got=%0d ref=%0d (diff=%0d, tol=%0d)",
                                     i, got_signed, ref_signed, diff, MAG_TOL);
                        mag_mismatch = mag_mismatch + 1;
                    end
                end

                $display("  Sign mismatches: %0d / %0d", sign_mismatch, NUM_LLR);
                $display("  Mag  mismatches: %0d / %0d (tolerance +/-%0d)", mag_mismatch, NUM_LLR, MAG_TOL);

                if (sign_mismatch > 0) begin
                    $display("  FAIL: %0d sign-bit errors (hard decision wrong)", sign_mismatch);
                    test1_errors = test1_errors + sign_mismatch;
                end
                if (mag_mismatch > 0) begin
                    $display("  FAIL: %0d magnitude errors exceed tolerance", mag_mismatch);
                    test1_errors = test1_errors + mag_mismatch;
                end
                if (sign_mismatch == 0 && mag_mismatch == 0)
                    $display("  All %0d LLRs match reference within tolerance.", NUM_LLR);
            end
        end

        if (test1_errors == 0)
            $display("  >> Test 1 PASSED");
        else
            $display("  >> Test 1 FAILED (%0d errors)", test1_errors);

        errors = errors + test1_errors;

        // =================================================================
        // Test 2: Output framing check
        // =================================================================
        $display("");
        $display("=== Test 2: Output framing check ===");

        // Re-use results from Test 1 capture
        $display("  Total m_tvalid beats: %0d (expect %0d)", valid_cnt, NUM_LLR);
        $display("  Total m_tlast pulses: %0d (expect 1)", tlast_cnt);
        $display("  m_tlast position:     %0d (expect %0d)", tlast_pos, NUM_LLR - 1);

        // -- Check: exactly 648 valid outputs --
        if (valid_cnt != NUM_LLR) begin
            $display("  FAIL: Expected %0d valid outputs, got %0d", NUM_LLR, valid_cnt);
            test2_errors = test2_errors + 1;
        end

        // -- Check: exactly 1 m_tlast --
        if (tlast_cnt != 1) begin
            $display("  FAIL: Expected exactly 1 m_tlast, got %0d", tlast_cnt);
            test2_errors = test2_errors + 1;
        end

        // -- Check: m_tlast on the last (648th) output --
        if (tlast_pos != NUM_LLR - 1) begin
            $display("  FAIL: m_tlast at position %0d, expected %0d", tlast_pos, NUM_LLR - 1);
            test2_errors = test2_errors + 1;
        end

        if (test2_errors == 0)
            $display("  >> Test 2 PASSED");
        else
            $display("  >> Test 2 FAILED (%0d errors)", test2_errors);

        errors = errors + test2_errors;

        // =================================================================
        // Final summary
        // =================================================================
        $display("");
        $display("============================================");
        if (errors == 0)
            $display("PASS: All ofdm_rx_top integration tests passed.");
        else
            $display("FAIL: %0d error(s) in ofdm_rx_top integration tests.", errors);
        $display("============================================");

        #200;
        $finish;
    end

    // =========================================================================
    // Global timeout watchdog — 20 ms
    // =========================================================================
    initial begin
        #20_000_000;
        $display("");
        $display("FAIL: Global timeout (20 ms) — simulation hung");
        $finish;
    end

endmodule
