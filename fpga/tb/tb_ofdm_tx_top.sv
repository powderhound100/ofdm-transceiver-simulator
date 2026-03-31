// =============================================================================
// tb_ofdm_tx_top.sv — Integration testbench for OFDM transmitter top level
// =============================================================================
// Exercises the full TX chain:
//   ldpc_encoder -> qam_mapper -> subcarrier_mux -> ifft_64pt -> cp_insertion
//
// Tests:
//   1. Known pattern: 324 info bits -> 560 TX IQ samples, compare vs reference
//   2. All-zero input: 324 zero bits -> verify 560 valid output samples
//   3. Frame framing: verify exactly 560 m_tvalid samples, m_tlast on last
//
// Uses $readmemh to load hex test vectors from test_vectors/ofdm/ directory.
// =============================================================================

`timescale 1ns / 1ps

module tb_ofdm_tx_top;

    // =========================================================================
    // Parameters
    // =========================================================================
    localparam integer FFT_N       = 64;
    localparam integer CP_LEN      = 16;
    localparam integer W_IQ        = 16;
    localparam integer TW          = 12;
    localparam integer NUM_INFO    = 324;
    localparam integer NUM_TX_SAMP = 560;  // 7 OFDM symbols * (64 + 16)
    localparam integer TOLERANCE   = 100;  // +/-100 per I/Q component

    localparam real CLK_PERIOD = 10.0;     // 100 MHz

    // =========================================================================
    // DUT signals
    // =========================================================================
    logic        clk;
    logic        rst_n;

    // AXI-Stream slave (info bits in)
    logic        s_tdata;
    logic        s_tvalid;
    logic        s_tready;
    logic        s_tlast;

    // AXI-Stream master (TX IQ out)
    logic [31:0] m_tdata;
    logic        m_tvalid;
    logic        m_tready;
    logic        m_tlast;

    // Configuration
    logic [3:0]  cfg_modulation;

    // Status
    logic        encoder_busy;

    // =========================================================================
    // DUT instantiation
    // =========================================================================
    ofdm_tx_top #(
        .FFT_N  (FFT_N),
        .CP_LEN (CP_LEN),
        .W_IQ   (W_IQ),
        .TW     (TW)
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .s_tdata        (s_tdata),
        .s_tvalid       (s_tvalid),
        .s_tready       (s_tready),
        .s_tlast        (s_tlast),
        .m_tdata        (m_tdata),
        .m_tvalid       (m_tvalid),
        .m_tready       (m_tready),
        .m_tlast        (m_tlast),
        .cfg_modulation (cfg_modulation),
        .encoder_busy   (encoder_busy)
    );

    // =========================================================================
    // Clock generation
    // =========================================================================
    initial clk = 0;
    always #(CLK_PERIOD / 2) clk = ~clk;

    // =========================================================================
    // Test vector storage
    // =========================================================================
    logic [0:0]  info_bits  [0:NUM_INFO-1];
    logic [31:0] ref_tx_iq  [0:NUM_TX_SAMP-1];

    // Captured output
    logic [31:0] cap_tx_iq  [0:NUM_TX_SAMP-1];
    int          cap_count;
    logic        cap_tlast_seen;
    int          cap_tlast_idx;

    // Test infrastructure
    int errors;
    int total_tests;

    // =========================================================================
    // Load test vectors
    // =========================================================================
    initial begin
        $readmemh("../../test_vectors/ofdm/ofdm_info_bits_flat_noiseless.hex", info_bits);
        $readmemh("../../test_vectors/ofdm/ofdm_tx_iq_flat_noiseless.hex", ref_tx_iq);
    end

    // =========================================================================
    // Tasks
    // =========================================================================

    // Send info bits via AXI-Stream slave interface
    task send_info_bits(input logic use_vector);
        for (int i = 0; i < NUM_INFO; i++) begin
            s_tdata  <= use_vector ? info_bits[i][0] : 1'b0;
            s_tvalid <= 1'b1;
            s_tlast  <= (i == NUM_INFO - 1);
            @(posedge clk);
            while (!s_tready) @(posedge clk);
        end
        s_tvalid <= 1'b0;
        s_tlast  <= 1'b0;
    endtask

    // Capture TX IQ output samples until we have num_expected or timeout
    task capture_tx_output(input int num_expected, input int max_cycles);
        int cyc;
        cap_count      = 0;
        cap_tlast_seen = 0;
        cap_tlast_idx  = -1;
        cyc            = 0;

        m_tready <= 1'b1;
        while (cap_count < num_expected && cyc < max_cycles) begin
            @(posedge clk);
            if (m_tvalid && m_tready) begin
                cap_tx_iq[cap_count] = m_tdata;
                if (m_tlast) begin
                    cap_tlast_seen = 1;
                    cap_tlast_idx  = cap_count;
                end
                cap_count++;
            end
            cyc++;
        end
        m_tready <= 1'b0;

        if (cap_count < num_expected)
            $display("  WARNING: Only captured %0d / %0d samples (timeout after %0d cycles)",
                     cap_count, num_expected, max_cycles);
    endtask

    // =========================================================================
    // Main test sequence
    // =========================================================================
    initial begin
        $dumpfile("tb_ofdm_tx_top.vcd");
        $dumpvars(0, tb_ofdm_tx_top);

        errors      = 0;
        total_tests = 0;

        // Initialize
        rst_n          = 0;
        s_tdata        = 0;
        s_tvalid       = 0;
        s_tlast        = 0;
        m_tready       = 0;
        cfg_modulation = 4'd0;  // QPSK

        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        // =================================================================
        // Test 1: Known pattern — compare TX IQ against reference
        // =================================================================
        begin
            int mismatch_count;
            int first_mismatch;
            logic signed [15:0] ref_i, ref_q, cap_i, cap_q;
            int diff_i, diff_q;

            $display("");
            $display("=== Test 1: Known pattern (324 info bits -> 560 TX IQ) ===");

            // Feed info bits from test vector
            fork
                send_info_bits(1'b1);
                capture_tx_output(NUM_TX_SAMP, 500000);
            join

            $display("  Captured %0d TX IQ samples", cap_count);

            if (cap_count != NUM_TX_SAMP) begin
                $display("  FAIL: Expected %0d samples, got %0d", NUM_TX_SAMP, cap_count);
                errors++;
            end else begin
                // Compare each sample with tolerance
                mismatch_count = 0;
                first_mismatch = -1;

                for (int i = 0; i < NUM_TX_SAMP; i++) begin
                    ref_i = ref_tx_iq[i][15:0];
                    ref_q = ref_tx_iq[i][31:16];
                    cap_i = cap_tx_iq[i][15:0];
                    cap_q = cap_tx_iq[i][31:16];

                    diff_i = (cap_i > ref_i) ? (cap_i - ref_i) : (ref_i - cap_i);
                    diff_q = (cap_q > ref_q) ? (cap_q - ref_q) : (ref_q - cap_q);

                    if (diff_i > TOLERANCE || diff_q > TOLERANCE) begin
                        if (first_mismatch == -1) first_mismatch = i;
                        mismatch_count++;
                        if (mismatch_count <= 5) begin
                            $display("  Mismatch [%0d]: ref={I:%04h,Q:%04h} got={I:%04h,Q:%04h} diff_I=%0d diff_Q=%0d",
                                     i, ref_i, ref_q, cap_i, cap_q, diff_i, diff_q);
                        end
                    end
                end

                $display("  Mismatched samples: %0d / %0d (tolerance +/-%0d per component)",
                         mismatch_count, NUM_TX_SAMP, TOLERANCE);

                if (mismatch_count == 0)
                    $display("  PASS: All TX IQ samples match reference within tolerance");
                else begin
                    $display("  FAIL: %0d samples exceed tolerance (first at index %0d)",
                             mismatch_count, first_mismatch);
                    errors++;
                end
            end

            total_tests++;
        end

        // Wait between tests, let pipeline fully flush
        repeat (100) @(posedge clk);

        // Reset DUT between tests to ensure clean state
        rst_n = 0;
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        // =================================================================
        // Test 2: All-zero input — verify valid output generation
        // =================================================================
        begin
            $display("");
            $display("=== Test 2: All-zero input (324 zero bits -> 560 TX IQ) ===");

            fork
                send_info_bits(1'b0);
                capture_tx_output(NUM_TX_SAMP, 500000);
            join

            $display("  Captured %0d TX IQ samples", cap_count);

            if (cap_count == NUM_TX_SAMP) begin
                $display("  PASS: All-zero input produced %0d valid output samples", cap_count);
            end else begin
                $display("  FAIL: Expected %0d samples, got %0d", NUM_TX_SAMP, cap_count);
                errors++;
            end

            total_tests++;
        end

        // Wait between tests
        repeat (100) @(posedge clk);

        // Reset DUT between tests
        rst_n = 0;
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        // =================================================================
        // Test 3: Frame framing — verify exactly 560 samples and m_tlast
        // =================================================================
        begin
            int extra_count;
            int extra_cyc;

            $display("");
            $display("=== Test 3: Frame framing check ===");

            fork
                send_info_bits(1'b1);
                capture_tx_output(NUM_TX_SAMP, 500000);
            join

            $display("  Captured %0d samples, m_tlast seen: %0b (at index %0d)",
                     cap_count, cap_tlast_seen, cap_tlast_idx);

            // Check sample count
            if (cap_count != NUM_TX_SAMP) begin
                $display("  FAIL: Expected exactly %0d valid samples, got %0d",
                         NUM_TX_SAMP, cap_count);
                errors++;
            end else begin
                $display("  PASS: Exactly %0d valid output samples received", NUM_TX_SAMP);
            end

            // Check m_tlast on last sample
            if (!cap_tlast_seen) begin
                $display("  FAIL: m_tlast was never asserted");
                errors++;
            end else if (cap_tlast_idx != NUM_TX_SAMP - 1) begin
                $display("  FAIL: m_tlast at index %0d, expected at %0d",
                         cap_tlast_idx, NUM_TX_SAMP - 1);
                errors++;
            end else begin
                $display("  PASS: m_tlast correctly asserted on final sample (index %0d)",
                         cap_tlast_idx);
            end

            // Verify no extra samples arrive after m_tlast
            extra_count = 0;
            m_tready    <= 1'b1;
            for (extra_cyc = 0; extra_cyc < 200; extra_cyc++) begin
                @(posedge clk);
                if (m_tvalid && m_tready) extra_count++;
            end
            m_tready <= 1'b0;

            if (extra_count > 0) begin
                $display("  FAIL: %0d extra samples arrived after frame end", extra_count);
                errors++;
            end else begin
                $display("  PASS: No extra samples after frame end");
            end

            total_tests++;
        end

        // =================================================================
        // Final report
        // =================================================================
        $display("");
        $display("============================================");
        if (errors == 0)
            $display("PASS: All %0d ofdm_tx_top tests passed.", total_tests);
        else
            $display("FAIL: %0d / %0d ofdm_tx_top tests failed.", errors, total_tests);
        $display("============================================");

        $finish;
    end

    // =========================================================================
    // Timeout watchdog — 20ms for full encoder+IFFT pipeline
    // =========================================================================
    initial begin
        #20000000;  // 20ms
        $display("ERROR: Global timeout reached (20 ms)!");
        $display("  cap_count = %0d, encoder_busy = %0b", cap_count, encoder_busy);
        $display("FAIL: Simulation timed out.");
        $finish;
    end

endmodule
