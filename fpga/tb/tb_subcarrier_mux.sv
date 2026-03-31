// =============================================================================
// tb_subcarrier_mux.sv — Testbench for subcarrier_mux module
// =============================================================================
// Self-checking testbench with 3 tests:
//   1. Known data: 48 distinct values -> verify guard/pilot/data placement
//   2. All-zero data: verify pilots present, guards zero
//   3. Back-to-back: 96 data symbols (2 frames) -> verify both frames
//
// RTL dependencies:
//   subcarrier_mux.sv
//
// Compile (iverilog v12):
//   iverilog -g2012 -o tb_subcarrier_mux \
//     ../rtl/subcarrier_mux.sv \
//     tb_subcarrier_mux.sv
// =============================================================================
`timescale 1ns / 1ps

module tb_subcarrier_mux;

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    localparam integer FFT_N      = 64;
    localparam integer NUM_DATA   = 48;
    localparam integer NUM_PILOTS = 4;
    localparam integer NUM_GUARD  = 12;  // 6 lower + 6 upper

    // Pilot value: BPSK +1.0 in Q1.14 = {Q=0x0000, I=0x4000}
    localparam [31:0] PILOT_VAL = {16'h0000, 16'h4000};
    localparam [31:0] ZERO_VAL  = 32'h00000000;

    // -------------------------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------------------------
    logic        clk;
    logic        rst_n;
    logic [31:0] data_in;
    logic        data_valid;
    logic [31:0] bin_out;
    logic        bin_valid;
    logic        bin_last;
    logic        bin_first;

    // -------------------------------------------------------------------------
    // DUT instantiation
    // -------------------------------------------------------------------------
    subcarrier_mux #(
        .FFT_N (FFT_N)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .data_in    (data_in),
        .data_valid (data_valid),
        .bin_out    (bin_out),
        .bin_valid  (bin_valid),
        .bin_last   (bin_last),
        .bin_first  (bin_first)
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
    // Bin classification: mirrors RTL bin_type function
    // 0 = guard (zero), 1 = pilot, 2 = data
    // -------------------------------------------------------------------------
    function [1:0] bin_type;
        input [5:0] idx;
        begin
            if (idx <= 6'd5 || idx >= 6'd58)
                bin_type = 2'd0;  // guard
            else if (idx == 6'd6 || idx == 6'd18 ||
                     idx == 6'd30 || idx == 6'd42)
                bin_type = 2'd1;  // pilot
            else
                bin_type = 2'd2;  // data
        end
    endfunction

    // -------------------------------------------------------------------------
    // Output capture
    // -------------------------------------------------------------------------
    logic [31:0] cap_bin  [0:255];
    logic        cap_last [0:255];
    logic        cap_first [0:255];
    integer      cap_idx;

    always @(posedge clk) begin
        if (bin_valid) begin
            cap_bin[cap_idx]   <= bin_out;
            cap_last[cap_idx]  <= bin_last;
            cap_first[cap_idx] <= bin_first;
            cap_idx            <= cap_idx + 1;
        end
    end

    // -------------------------------------------------------------------------
    // Module-level variables (iverilog -g2012 compatibility)
    // -------------------------------------------------------------------------
    integer pass_count;
    integer fail_count;
    integer errors;
    integer i, j;
    integer data_idx;
    integer frame;

    // Data symbol arrays for stimulus
    logic [31:0] tx_data_f0 [0:47];  // frame 0
    logic [31:0] tx_data_f1 [0:47];  // frame 1

    // -------------------------------------------------------------------------
    // Build expected data bin list (for reference in checking)
    // -------------------------------------------------------------------------
    // Data bin indices within 64: 7-17, 19-29, 31-41, 43-57
    // (everything in 6..57 that is not a pilot at 6,18,30,42)
    logic [5:0] data_bins [0:47];
    integer     data_bin_cnt;

    initial begin
        data_bin_cnt = 0;
        for (j = 6; j <= 57; j = j + 1) begin
            if (j != 6 && j != 18 && j != 30 && j != 42) begin
                data_bins[data_bin_cnt] = j[5:0];
                data_bin_cnt = data_bin_cnt + 1;
            end
        end
        // data_bin_cnt should be 48
    end

    // -------------------------------------------------------------------------
    // Task: apply reset
    // -------------------------------------------------------------------------
    task do_reset;
        begin
            rst_n      = 1'b0;
            data_in    = 32'd0;
            data_valid = 1'b0;
            repeat (10) @(posedge clk);
            rst_n = 1'b1;
            repeat (5) @(posedge clk);
        end
    endtask

    // -------------------------------------------------------------------------
    // Task: feed N data symbols from a flat array (blocking)
    // -------------------------------------------------------------------------
    task feed_data_symbols;
        input integer count;
        input integer frame_sel;  // 0 = tx_data_f0, 1 = tx_data_f1
        integer fi;
        begin
            for (fi = 0; fi < count; fi = fi + 1) begin
                @(posedge clk);
                if (frame_sel == 0)
                    data_in = tx_data_f0[fi];
                else
                    data_in = tx_data_f1[fi];
                data_valid = 1'b1;
            end
            @(posedge clk);
            data_valid = 1'b0;
            data_in    = 32'd0;
        end
    endtask

    // -------------------------------------------------------------------------
    // Task: wait for N bin outputs to be captured
    // -------------------------------------------------------------------------
    task wait_for_bins;
        input integer expected_count;
        integer wt;
        begin
            wt = 0;
            while (cap_idx < expected_count && wt < 100_000) begin
                @(posedge clk);
                wt = wt + 1;
            end
            if (wt >= 100_000) begin
                $display("  FAIL: Timeout waiting for %0d bins (got %0d)",
                         expected_count, cap_idx);
                errors = errors + 1;
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Main test sequence
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("tb_subcarrier_mux.vcd");
        $dumpvars(0, tb_subcarrier_mux);

        pass_count = 0;
        fail_count = 0;

        // Initialize capture
        cap_idx = 0;
        for (i = 0; i < 256; i = i + 1) begin
            cap_bin[i]   = 32'd0;
            cap_last[i]  = 1'b0;
            cap_first[i] = 1'b0;
        end

        // Build test data: frame 0 uses values 0x0001_1001 through 0x0001_1030
        // (48 distinct 32-bit complex symbols with nonzero I and Q)
        for (i = 0; i < NUM_DATA; i = i + 1) begin
            tx_data_f0[i] = {16'(i + 1), 16'(16'h1000 + i)};  // {Q, I}
            tx_data_f1[i] = {16'(i + 101), 16'(16'h2000 + i)}; // different frame
        end

        // =================================================================
        // TEST 1: Known data — 48 distinct symbols
        // -----------------------------------------------------------------
        // Verify:
        //   - Guard bins (0-5, 58-63) are zero
        //   - Pilot bins (6, 18, 30, 42) = PILOT_VAL = {0x0000, 0x4000}
        //   - Data bins contain the 48 input symbols in correct order
        //   - bin_first asserted on bin 0, bin_last on bin 63
        // =================================================================
        $display("\n=== TEST 1: 48 known data symbols ===");
        do_reset;
        errors = 0;
        cap_idx = 0;

        feed_data_symbols(NUM_DATA, 0);

        // Wait for all 64 bin outputs
        wait_for_bins(FFT_N);

        // Check total output count
        if (cap_idx != FFT_N) begin
            $display("  FAIL: Expected %0d bin outputs, got %0d", FFT_N, cap_idx);
            errors = errors + 1;
        end

        // Check bin_first on bin 0
        if (!cap_first[0]) begin
            $display("  FAIL: bin_first not asserted on bin 0");
            errors = errors + 1;
        end

        // Check bin_first NOT asserted on any other bin
        for (i = 1; i < FFT_N && i < cap_idx; i = i + 1) begin
            if (cap_first[i]) begin
                $display("  FAIL: bin_first unexpectedly asserted on bin %0d", i);
                errors = errors + 1;
            end
        end

        // Check bin_last on bin 63
        if (cap_idx >= FFT_N && !cap_last[FFT_N - 1]) begin
            $display("  FAIL: bin_last not asserted on bin 63");
            errors = errors + 1;
        end

        // Check bin_last NOT asserted on any other bin
        for (i = 0; i < FFT_N - 1 && i < cap_idx; i = i + 1) begin
            if (cap_last[i]) begin
                $display("  FAIL: bin_last unexpectedly asserted on bin %0d", i);
                errors = errors + 1;
            end
        end

        // Walk through all 64 bins and verify content
        data_idx = 0;
        for (i = 0; i < FFT_N && i < cap_idx; i = i + 1) begin
            case (bin_type(i[5:0]))
                2'd0: begin
                    // Guard: must be zero
                    if (cap_bin[i] != ZERO_VAL) begin
                        $display("  FAIL: Guard bin[%0d] = 0x%08h, expected 0x00000000",
                                 i, cap_bin[i]);
                        errors = errors + 1;
                    end
                end
                2'd1: begin
                    // Pilot: must be PILOT_VAL
                    if (cap_bin[i] != PILOT_VAL) begin
                        $display("  FAIL: Pilot bin[%0d] = 0x%08h, expected 0x%08h",
                                 i, cap_bin[i], PILOT_VAL);
                        errors = errors + 1;
                    end
                end
                2'd2: begin
                    // Data: must match tx_data_f0[data_idx]
                    if (cap_bin[i] != tx_data_f0[data_idx]) begin
                        $display("  FAIL: Data bin[%0d] (data_idx=%0d) = 0x%08h, expected 0x%08h",
                                 i, data_idx, cap_bin[i], tx_data_f0[data_idx]);
                        errors = errors + 1;
                    end
                    data_idx = data_idx + 1;
                end
                default: begin end
            endcase
        end

        // Verify we consumed all 48 data symbols
        if (data_idx != NUM_DATA) begin
            $display("  FAIL: Only %0d of %0d data symbols placed in bins", data_idx, NUM_DATA);
            errors = errors + 1;
        end

        $display("  Guard bins checked: 0-5, 58-63 (12 total)");
        $display("  Pilot bins checked: 6, 18, 30, 42 (4 total)");
        $display("  Data bins checked:  %0d of %0d", data_idx, NUM_DATA);

        if (errors == 0) begin
            $display("  TEST 1: PASS");
            pass_count = pass_count + 1;
        end else begin
            $display("  TEST 1: FAIL (%0d errors)", errors);
            fail_count = fail_count + 1;
        end

        // =================================================================
        // TEST 2: All-zero data — pilots should still be present
        // =================================================================
        $display("\n=== TEST 2: All-zero data (verify pilots and guards) ===");
        do_reset;
        errors = 0;
        cap_idx = 0;

        // Feed 48 zero-valued data symbols
        for (i = 0; i < NUM_DATA; i = i + 1) begin
            @(posedge clk);
            data_in    = 32'd0;
            data_valid = 1'b1;
        end
        @(posedge clk);
        data_valid = 1'b0;
        data_in    = 32'd0;

        wait_for_bins(FFT_N);

        if (cap_idx != FFT_N) begin
            $display("  FAIL: Expected %0d bin outputs, got %0d", FFT_N, cap_idx);
            errors = errors + 1;
        end

        for (i = 0; i < FFT_N && i < cap_idx; i = i + 1) begin
            case (bin_type(i[5:0]))
                2'd0: begin
                    // Guard: must be zero
                    if (cap_bin[i] != ZERO_VAL) begin
                        $display("  FAIL: Guard bin[%0d] = 0x%08h, expected zero", i, cap_bin[i]);
                        errors = errors + 1;
                    end
                end
                2'd1: begin
                    // Pilot: must be PILOT_VAL even with zero data
                    if (cap_bin[i] != PILOT_VAL) begin
                        $display("  FAIL: Pilot bin[%0d] = 0x%08h, expected 0x%08h",
                                 i, cap_bin[i], PILOT_VAL);
                        errors = errors + 1;
                    end
                end
                2'd2: begin
                    // Data: should be zero
                    if (cap_bin[i] != ZERO_VAL) begin
                        $display("  FAIL: Data bin[%0d] = 0x%08h, expected zero", i, cap_bin[i]);
                        errors = errors + 1;
                    end
                end
                default: begin end
            endcase
        end

        if (errors == 0) begin
            $display("  TEST 2: PASS");
            pass_count = pass_count + 1;
        end else begin
            $display("  TEST 2: FAIL (%0d errors)", errors);
            fail_count = fail_count + 1;
        end

        // =================================================================
        // TEST 3: Back-to-back frames — 96 data symbols (2 frames)
        // -----------------------------------------------------------------
        // Frame 0: tx_data_f0[0..47]
        // Frame 1: tx_data_f1[0..47]
        // Verify both frames output correctly (128 total bin outputs)
        // =================================================================
        $display("\n=== TEST 3: Back-to-back frames (2 x 48 data) ===");
        do_reset;
        errors = 0;
        cap_idx = 0;

        // Feed frame 0 then frame 1 back-to-back
        feed_data_symbols(NUM_DATA, 0);
        feed_data_symbols(NUM_DATA, 1);

        // Wait for 128 bin outputs (2 x 64)
        wait_for_bins(2 * FFT_N);

        if (cap_idx != 2 * FFT_N) begin
            $display("  FAIL: Expected %0d bin outputs, got %0d", 2 * FFT_N, cap_idx);
            errors = errors + 1;
        end

        // Verify each frame
        for (frame = 0; frame < 2; frame = frame + 1) begin
            data_idx = 0;
            for (i = 0; i < FFT_N; i = i + 1) begin
                j = frame * FFT_N + i;  // index into capture array
                if (j >= cap_idx) begin
                    // Not enough outputs captured
                    if (errors == 0)
                        $display("  FAIL: Frame %0d bin %0d not captured", frame, i);
                    errors = errors + 1;
                end else begin
                    case (bin_type(i[5:0]))
                        2'd0: begin
                            if (cap_bin[j] != ZERO_VAL) begin
                                $display("  FAIL: Frame %0d guard bin[%0d] = 0x%08h, expected zero",
                                         frame, i, cap_bin[j]);
                                errors = errors + 1;
                            end
                        end
                        2'd1: begin
                            if (cap_bin[j] != PILOT_VAL) begin
                                $display("  FAIL: Frame %0d pilot bin[%0d] = 0x%08h, expected 0x%08h",
                                         frame, i, cap_bin[j], PILOT_VAL);
                                errors = errors + 1;
                            end
                        end
                        2'd2: begin
                            if (frame == 0) begin
                                if (cap_bin[j] != tx_data_f0[data_idx]) begin
                                    $display("  FAIL: Frame 0 data bin[%0d] (d=%0d) = 0x%08h, expected 0x%08h",
                                             i, data_idx, cap_bin[j], tx_data_f0[data_idx]);
                                    errors = errors + 1;
                                end
                            end else begin
                                if (cap_bin[j] != tx_data_f1[data_idx]) begin
                                    $display("  FAIL: Frame 1 data bin[%0d] (d=%0d) = 0x%08h, expected 0x%08h",
                                             i, data_idx, cap_bin[j], tx_data_f1[data_idx]);
                                    errors = errors + 1;
                                end
                            end
                            data_idx = data_idx + 1;
                        end
                        default: begin end
                    endcase
                end
            end

            if (data_idx != NUM_DATA) begin
                $display("  FAIL: Frame %0d only matched %0d data symbols", frame, data_idx);
                errors = errors + 1;
            end
        end

        // Verify bin_first/bin_last for both frames
        // Frame 0: bin_first at cap index 0, bin_last at cap index 63
        // Frame 1: bin_first at cap index 64, bin_last at cap index 127
        if (cap_idx >= FFT_N) begin
            if (!cap_first[0]) begin
                $display("  FAIL: bin_first not asserted at frame 0 bin 0");
                errors = errors + 1;
            end
            if (!cap_last[FFT_N - 1]) begin
                $display("  FAIL: bin_last not asserted at frame 0 bin 63");
                errors = errors + 1;
            end
        end
        if (cap_idx >= 2 * FFT_N) begin
            if (!cap_first[FFT_N]) begin
                $display("  FAIL: bin_first not asserted at frame 1 bin 0");
                errors = errors + 1;
            end
            if (!cap_last[2 * FFT_N - 1]) begin
                $display("  FAIL: bin_last not asserted at frame 1 bin 63");
                errors = errors + 1;
            end
        end

        // Verify no spurious bin_first/bin_last
        for (i = 0; i < 2 * FFT_N && i < cap_idx; i = i + 1) begin
            if (cap_first[i] && i != 0 && i != FFT_N) begin
                $display("  FAIL: Spurious bin_first at capture index %0d", i);
                errors = errors + 1;
            end
            if (cap_last[i] && i != (FFT_N - 1) && i != (2 * FFT_N - 1)) begin
                $display("  FAIL: Spurious bin_last at capture index %0d", i);
                errors = errors + 1;
            end
        end

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
