// =============================================================================
// tb_subcarrier_demux.sv — Testbench for subcarrier_demux module
// =============================================================================
// Self-checking testbench with 2 tests:
//   1. Single symbol: bin[k] = k identity pattern
//      - Verify pilot outputs are {6, 18, 30, 42}
//      - Verify data outputs are the 48 bins in [6..57] excluding pilots
//      - Verify guard bands (0-5, 58-63) are discarded
//   2. Two symbols back-to-back: verify correct separation for both
//
// RTL dependencies:
//   subcarrier_demux.sv
//
// Compile (iverilog v12):
//   iverilog -g2012 -o tb_subcarrier_demux \
//     ../rtl/subcarrier_demux.sv \
//     tb_subcarrier_demux.sv
// =============================================================================

`timescale 1ns / 1ps

module tb_subcarrier_demux;

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    localparam int FFT_N      = 64;
    localparam int NUM_PILOTS = 4;
    localparam int NUM_DATA   = 48;
    localparam real CLK_HALF  = 5.0;  // 100 MHz

    // -------------------------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------------------------
    logic        clk;
    logic        rst_n;

    logic [31:0] fft_data;
    logic        fft_valid;
    logic        fft_last;

    logic [31:0] pilot_data;
    logic        pilot_valid;
    logic        pilot_last;

    logic [31:0] data_out;
    logic        data_valid;
    logic        data_last;

    // -------------------------------------------------------------------------
    // DUT instantiation
    // -------------------------------------------------------------------------
    subcarrier_demux #(
        .FFT_N (FFT_N)
    ) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .fft_data    (fft_data),
        .fft_valid   (fft_valid),
        .fft_last    (fft_last),
        .pilot_data  (pilot_data),
        .pilot_valid (pilot_valid),
        .pilot_last  (pilot_last),
        .data_out    (data_out),
        .data_valid  (data_valid),
        .data_last   (data_last)
    );

    // -------------------------------------------------------------------------
    // Clock generation
    // -------------------------------------------------------------------------
    initial clk = 0;
    always #(CLK_HALF) clk = ~clk;

    // -------------------------------------------------------------------------
    // Timeout watchdog: 10 ms
    // -------------------------------------------------------------------------
    initial begin
        #10_000_000;
        $display("TIMEOUT: Simulation exceeded 10 ms");
        $finish;
    end

    // -------------------------------------------------------------------------
    // Test variables (module-level for iverilog compatibility)
    // -------------------------------------------------------------------------
    integer pass_count;
    integer fail_count;
    integer errors;
    integer i, k;

    // Capture buffers
    logic [31:0] cap_pilot [0:15];
    logic        cap_pilot_last [0:15];
    integer      cap_pilot_idx;

    logic [31:0] cap_data [0:127];
    logic        cap_data_last [0:127];
    integer      cap_data_idx;

    // Expected pilot bin indices
    logic [5:0] exp_pilot [0:3];

    // Expected data bin indices (48 entries)
    logic [5:0] exp_data [0:47];
    integer     exp_data_cnt;

    // -------------------------------------------------------------------------
    // Build expected arrays at initialization
    // -------------------------------------------------------------------------
    initial begin
        exp_pilot[0] = 6'd6;
        exp_pilot[1] = 6'd18;
        exp_pilot[2] = 6'd30;
        exp_pilot[3] = 6'd42;

        exp_data_cnt = 0;
        for (k = 6; k <= 57; k = k + 1) begin
            if (k != 6 && k != 18 && k != 30 && k != 42) begin
                exp_data[exp_data_cnt] = k[5:0];
                exp_data_cnt = exp_data_cnt + 1;
            end
        end
        // exp_data_cnt should be 48
    end

    // -------------------------------------------------------------------------
    // Output capture process (always-running)
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (pilot_valid) begin
            cap_pilot[cap_pilot_idx]      <= pilot_data;
            cap_pilot_last[cap_pilot_idx] <= pilot_last;
            cap_pilot_idx                 <= cap_pilot_idx + 1;
        end
        if (data_valid) begin
            cap_data[cap_data_idx]      <= data_out;
            cap_data_last[cap_data_idx] <= data_last;
            cap_data_idx                <= cap_data_idx + 1;
        end
    end

    // -------------------------------------------------------------------------
    // Helper task: send one FFT symbol with bin[k] = base + k
    // -------------------------------------------------------------------------
    task send_symbol(
        input integer base_offset
    );
        integer sk;
        for (sk = 0; sk < FFT_N; sk = sk + 1) begin
            @(posedge clk);
            fft_data  <= {16'd0, (base_offset + sk) & 16'hFFFF};
            fft_valid <= 1'b1;
            fft_last  <= (sk == FFT_N - 1) ? 1'b1 : 1'b0;
        end
        @(posedge clk);
        fft_valid <= 1'b0;
        fft_last  <= 1'b0;
    endtask

    // -------------------------------------------------------------------------
    // Main test sequence
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("tb_subcarrier_demux.vcd");
        $dumpvars(0, tb_subcarrier_demux);

        // Initialize
        rst_n         = 1'b0;
        fft_data      = 32'd0;
        fft_valid     = 1'b0;
        fft_last      = 1'b0;
        pass_count    = 0;
        fail_count    = 0;
        cap_pilot_idx = 0;
        cap_data_idx  = 0;

        for (i = 0; i < 16; i = i + 1) begin
            cap_pilot[i]      = 32'd0;
            cap_pilot_last[i] = 1'b0;
        end
        for (i = 0; i < 128; i = i + 1) begin
            cap_data[i]      = 32'd0;
            cap_data_last[i] = 1'b0;
        end

        // Release reset
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        // =============================================================
        // TEST 1: Single symbol with identity pattern (bin[k] = k)
        // =============================================================
        $display("\n=== TEST 1: Single symbol identity pattern ===");

        cap_pilot_idx = 0;
        cap_data_idx  = 0;

        send_symbol(0);

        // Wait for registered outputs to propagate
        repeat (5) @(posedge clk);

        errors = 0;

        // ---- Check pilot outputs ----
        $display("  Pilot outputs (%0d captured):", cap_pilot_idx);
        for (i = 0; i < NUM_PILOTS; i = i + 1) begin
            $display("    pilot[%0d] = %0d (expected %0d)",
                     i, (i < cap_pilot_idx) ? cap_pilot[i][15:0] : 16'hXXXX,
                     exp_pilot[i]);
            if (i < cap_pilot_idx && cap_pilot[i][15:0] != {10'd0, exp_pilot[i]}) begin
                errors = errors + 1;
            end
        end

        if (cap_pilot_idx != NUM_PILOTS) begin
            $display("  ERROR: expected %0d pilots, got %0d", NUM_PILOTS, cap_pilot_idx);
            errors = errors + 1;
        end

        // Check pilot_last on the 4th pilot
        if (cap_pilot_idx >= NUM_PILOTS && !cap_pilot_last[NUM_PILOTS - 1]) begin
            $display("  ERROR: pilot_last not asserted on 4th pilot");
            errors = errors + 1;
        end

        // ---- Check data outputs ----
        $display("  Data outputs (%0d captured, showing first 5 and last 2):", cap_data_idx);
        for (i = 0; i < NUM_DATA; i = i + 1) begin
            if (i < 5 || i >= NUM_DATA - 2) begin
                $display("    data[%0d] = %0d (expected %0d)", i,
                         (i < cap_data_idx) ? cap_data[i][15:0] : 16'hXXXX,
                         exp_data[i]);
            end
            if (i < cap_data_idx && cap_data[i][15:0] != {10'd0, exp_data[i]}) begin
                errors = errors + 1;
            end
        end

        if (cap_data_idx != NUM_DATA) begin
            $display("  ERROR: expected %0d data bins, got %0d", NUM_DATA, cap_data_idx);
            errors = errors + 1;
        end

        // Check data_last on the 48th data bin
        if (cap_data_idx >= NUM_DATA && !cap_data_last[NUM_DATA - 1]) begin
            $display("  ERROR: data_last not asserted on last data bin");
            errors = errors + 1;
        end

        // Verify no guard band values leaked into data
        for (i = 0; i < cap_data_idx; i = i + 1) begin
            if (cap_data[i][15:0] <= 16'd5 || cap_data[i][15:0] >= 16'd58) begin
                $display("  ERROR: guard band value %0d in data output at index %0d",
                         cap_data[i][15:0], i);
                errors = errors + 1;
            end
        end

        if (errors == 0) begin
            $display("  TEST 1: PASS");
            pass_count = pass_count + 1;
        end else begin
            $display("  TEST 1: FAIL (%0d errors)", errors);
            fail_count = fail_count + 1;
        end

        // =============================================================
        // TEST 2: Two symbols back-to-back
        // =============================================================
        $display("\n=== TEST 2: Two symbols back-to-back ===");

        // Reset capture indices
        cap_pilot_idx = 0;
        cap_data_idx  = 0;

        // Send symbol 0: bin[k] = k, symbol 1: bin[k] = 1000 + k
        send_symbol(0);
        send_symbol(1000);

        // Wait for outputs
        repeat (5) @(posedge clk);

        errors = 0;

        $display("  Pilots captured: %0d (expected %0d)", cap_pilot_idx, 2 * NUM_PILOTS);
        $display("  Data captured:   %0d (expected %0d)", cap_data_idx, 2 * NUM_DATA);

        if (cap_pilot_idx != 2 * NUM_PILOTS) begin
            $display("  ERROR: pilot count mismatch");
            errors = errors + 1;
        end
        if (cap_data_idx != 2 * NUM_DATA) begin
            $display("  ERROR: data count mismatch");
            errors = errors + 1;
        end

        // Verify symbol 0 pilots
        for (i = 0; i < NUM_PILOTS; i = i + 1) begin
            if (i < cap_pilot_idx && cap_pilot[i][15:0] != {10'd0, exp_pilot[i]}) begin
                $display("  ERROR: sym0 pilot[%0d] = %0d, expected %0d",
                         i, cap_pilot[i][15:0], exp_pilot[i]);
                errors = errors + 1;
            end
        end

        // Verify symbol 1 pilots (offset by 1000)
        for (i = 0; i < NUM_PILOTS; i = i + 1) begin
            if ((i + NUM_PILOTS) < cap_pilot_idx) begin
                if (cap_pilot[i + NUM_PILOTS][15:0] != ((16'd1000 + {10'd0, exp_pilot[i]}) & 16'hFFFF)) begin
                    $display("  ERROR: sym1 pilot[%0d] = %0d, expected %0d",
                             i, cap_pilot[i + NUM_PILOTS][15:0],
                             (16'd1000 + {10'd0, exp_pilot[i]}) & 16'hFFFF);
                    errors = errors + 1;
                end
            end
        end

        // Verify symbol 0 data
        for (i = 0; i < NUM_DATA; i = i + 1) begin
            if (i < cap_data_idx && cap_data[i][15:0] != {10'd0, exp_data[i]}) begin
                if (errors < 10)
                    $display("  ERROR: sym0 data[%0d] = %0d, expected %0d",
                             i, cap_data[i][15:0], exp_data[i]);
                errors = errors + 1;
            end
        end

        // Verify symbol 1 data (offset by 1000)
        for (i = 0; i < NUM_DATA; i = i + 1) begin
            if ((i + NUM_DATA) < cap_data_idx) begin
                if (cap_data[i + NUM_DATA][15:0] != ((16'd1000 + {10'd0, exp_data[i]}) & 16'hFFFF)) begin
                    if (errors < 10)
                        $display("  ERROR: sym1 data[%0d] = %0d, expected %0d",
                                 i, cap_data[i + NUM_DATA][15:0],
                                 (16'd1000 + {10'd0, exp_data[i]}) & 16'hFFFF);
                    errors = errors + 1;
                end
            end
        end

        // Check pilot_last on 4th pilot of each symbol
        if (cap_pilot_idx >= NUM_PILOTS && !cap_pilot_last[NUM_PILOTS - 1]) begin
            $display("  ERROR: pilot_last not asserted for sym0");
            errors = errors + 1;
        end
        if (cap_pilot_idx >= 2 * NUM_PILOTS && !cap_pilot_last[2 * NUM_PILOTS - 1]) begin
            $display("  ERROR: pilot_last not asserted for sym1");
            errors = errors + 1;
        end

        // Check data_last on 48th data bin of each symbol
        if (cap_data_idx >= NUM_DATA && !cap_data_last[NUM_DATA - 1]) begin
            $display("  ERROR: data_last not asserted for sym0");
            errors = errors + 1;
        end
        if (cap_data_idx >= 2 * NUM_DATA && !cap_data_last[2 * NUM_DATA - 1]) begin
            $display("  ERROR: data_last not asserted for sym1");
            errors = errors + 1;
        end

        if (errors == 0) begin
            $display("  TEST 2: PASS");
            pass_count = pass_count + 1;
        end else begin
            $display("  TEST 2: FAIL (%0d errors)", errors);
            fail_count = fail_count + 1;
        end

        // =============================================================
        // Summary
        // =============================================================
        $display("\n===================================");
        $display("  RESULTS: %0d PASS, %0d FAIL", pass_count, fail_count);
        if (fail_count == 0)
            $display("  ALL TESTS PASSED");
        else
            $display("  SOME TESTS FAILED");
        $display("===================================\n");

        $finish;
    end

endmodule
