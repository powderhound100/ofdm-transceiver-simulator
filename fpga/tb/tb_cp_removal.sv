// =============================================================================
// tb_cp_removal.sv — Testbench for cp_removal module
// =============================================================================
// Self-checking testbench with 4 tests:
//   1. Single symbol: 16 CP + 64 data -> verify only 64 data output
//   2. Three back-to-back symbols: verify correct CP removal for each
//   3. m_tlast asserted on sample 63 of each symbol
//   4. Backpressure test: deassert m_tready mid-symbol, verify no data loss
//
// RTL dependencies:
//   cp_removal.sv
//
// Compile (iverilog v12):
//   iverilog -g2012 -o tb_cp_removal \
//     ../rtl/cp_removal.sv \
//     tb_cp_removal.sv
// =============================================================================

`timescale 1ns / 1ps

module tb_cp_removal;

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    localparam int FFT_N  = 64;
    localparam int CP_LEN = 16;
    localparam int SYMBOL_LEN = FFT_N + CP_LEN;  // 80
    localparam real CLK_HALF = 5.0;  // 100 MHz

    // -------------------------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------------------------
    logic        clk;
    logic        rst_n;

    logic [31:0] s_tdata;
    logic        s_tvalid;
    logic        s_tready;

    logic [31:0] m_tdata;
    logic        m_tvalid;
    logic        m_tready;
    logic        m_tlast;

    // -------------------------------------------------------------------------
    // DUT instantiation
    // -------------------------------------------------------------------------
    cp_removal #(
        .FFT_N  (FFT_N),
        .CP_LEN (CP_LEN)
    ) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .s_tdata  (s_tdata),
        .s_tvalid (s_tvalid),
        .s_tready (s_tready),
        .m_tdata  (m_tdata),
        .m_tvalid (m_tvalid),
        .m_tready (m_tready),
        .m_tlast  (m_tlast)
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
    integer i, sym;
    integer errors;
    integer cap_count;

    // Output capture storage (up to 256 samples)
    logic [31:0] captured_data [0:255];
    logic        captured_last [0:255];

    // -------------------------------------------------------------------------
    // Helper task: send one sample (waits for handshake)
    // -------------------------------------------------------------------------
    task send_one(
        input [31:0] data
    );
        s_tdata  <= data;
        s_tvalid <= 1'b1;
        @(posedge clk);
        while (!s_tready) @(posedge clk);
        s_tvalid <= 1'b0;
    endtask

    // -------------------------------------------------------------------------
    // Main test sequence
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("tb_cp_removal.vcd");
        $dumpvars(0, tb_cp_removal);

        // Initialize
        rst_n      = 1'b0;
        s_tdata    = 32'd0;
        s_tvalid   = 1'b0;
        m_tready   = 1'b1;
        pass_count = 0;
        fail_count = 0;
        cap_count  = 0;

        // Initialize capture arrays
        for (i = 0; i < 256; i = i + 1) begin
            captured_data[i] = 32'd0;
            captured_last[i] = 1'b0;
        end

        // Release reset
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        // =============================================================
        // TEST 1: Single symbol — CP=[0xDEAD x16], Data=[0..63]
        // =============================================================
        $display("\n=== TEST 1: Single symbol CP removal ===");

        m_tready  = 1'b1;
        cap_count = 0;

        fork
            // Sender: send 16 CP samples then 64 data samples
            begin : t1_sender
                integer si;
                for (si = 0; si < CP_LEN; si = si + 1)
                    send_one(32'h0000DEAD);
                for (si = 0; si < FFT_N; si = si + 1)
                    send_one({16'd0, si[15:0]});
            end

            // Receiver: capture FFT_N outputs
            begin : t1_receiver
                integer ri;
                ri = 0;
                while (ri < FFT_N) begin
                    @(posedge clk);
                    if (m_tvalid && m_tready) begin
                        captured_data[ri] = m_tdata;
                        captured_last[ri] = m_tlast;
                        ri = ri + 1;
                    end
                end
                cap_count = ri;
            end
        join

        // Verify output == data values 0..63
        errors = 0;
        for (i = 0; i < FFT_N; i = i + 1) begin
            if (captured_data[i] != {16'd0, i[15:0]}) begin
                if (errors < 5)
                    $display("  ERROR: sample[%0d] = 0x%08X, expected 0x%08X",
                             i, captured_data[i], {16'd0, i[15:0]});
                errors = errors + 1;
            end
        end
        // Verify no CP leakage
        for (i = 0; i < FFT_N; i = i + 1) begin
            if (captured_data[i] == 32'h0000DEAD) begin
                $display("  ERROR: CP data leaked at output index %0d", i);
                errors = errors + 1;
            end
        end

        if (errors == 0) begin
            $display("  TEST 1: PASS (all 64 data samples correct)");
            pass_count = pass_count + 1;
        end else begin
            $display("  TEST 1: FAIL (%0d errors)", errors);
            fail_count = fail_count + 1;
        end

        // =============================================================
        // TEST 2: Three back-to-back symbols (240 input samples)
        // =============================================================
        $display("\n=== TEST 2: Three back-to-back symbols ===");

        m_tready  = 1'b1;
        cap_count = 0;
        for (i = 0; i < 256; i = i + 1) begin
            captured_data[i] = 32'd0;
            captured_last[i] = 1'b0;
        end

        fork
            // Sender: 3 symbols
            begin : t2_sender
                integer ss, si;
                for (ss = 0; ss < 3; ss = ss + 1) begin
                    // CP: value = 0xFFFF_0000 | sym_idx
                    for (si = 0; si < CP_LEN; si = si + 1)
                        send_one({16'hFFFF, ss[15:0]});
                    // Data: value = sym*64 + sample_index
                    for (si = 0; si < FFT_N; si = si + 1)
                        send_one({16'd0, (ss * FFT_N + si) & 16'hFFFF});
                end
            end

            // Receiver: capture 3*64 = 192 outputs
            begin : t2_receiver
                integer ri;
                ri = 0;
                while (ri < 3 * FFT_N) begin
                    @(posedge clk);
                    if (m_tvalid && m_tready) begin
                        captured_data[ri] = m_tdata;
                        captured_last[ri] = m_tlast;
                        ri = ri + 1;
                    end
                end
                cap_count = ri;
            end
        join

        // Verify each symbol's data
        errors = 0;
        for (sym = 0; sym < 3; sym = sym + 1) begin
            for (i = 0; i < FFT_N; i = i + 1) begin
                if (captured_data[sym * FFT_N + i] != {16'd0, (sym * FFT_N + i) & 16'hFFFF}) begin
                    if (errors < 5)
                        $display("  ERROR: sym%0d[%0d] = 0x%08X, expected 0x%08X",
                                 sym, i, captured_data[sym * FFT_N + i],
                                 {16'd0, (sym * FFT_N + i) & 16'hFFFF});
                    errors = errors + 1;
                end
            end
        end

        if (errors == 0) begin
            $display("  TEST 2: PASS (all 3 symbols decoded correctly)");
            pass_count = pass_count + 1;
        end else begin
            $display("  TEST 2: FAIL (%0d errors)", errors);
            fail_count = fail_count + 1;
        end

        // =============================================================
        // TEST 3: Verify m_tlast on sample 63 of each symbol
        // (uses captured_last from TEST 2)
        // =============================================================
        $display("\n=== TEST 3: m_tlast verification ===");

        errors = 0;
        for (sym = 0; sym < 3; sym = sym + 1) begin
            for (i = 0; i < FFT_N; i = i + 1) begin
                if (i == FFT_N - 1) begin
                    if (!captured_last[sym * FFT_N + i]) begin
                        $display("  ERROR: m_tlast NOT asserted on sym%0d sample 63", sym);
                        errors = errors + 1;
                    end
                end else begin
                    if (captured_last[sym * FFT_N + i]) begin
                        $display("  ERROR: m_tlast spuriously asserted on sym%0d sample %0d", sym, i);
                        errors = errors + 1;
                    end
                end
            end
        end

        if (errors == 0) begin
            $display("  TEST 3: PASS (m_tlast correct for all 3 symbols)");
            pass_count = pass_count + 1;
        end else begin
            $display("  TEST 3: FAIL (%0d errors)", errors);
            fail_count = fail_count + 1;
        end

        // =============================================================
        // TEST 4: Backpressure test
        // =============================================================
        $display("\n=== TEST 4: Backpressure test ===");

        m_tready  = 1'b1;
        cap_count = 0;
        for (i = 0; i < 256; i = i + 1) begin
            captured_data[i] = 32'd0;
            captured_last[i] = 1'b0;
        end

        fork
            // Sender: 1 symbol
            begin : t4_sender
                integer si;
                for (si = 0; si < CP_LEN; si = si + 1)
                    send_one(32'hBEEF_CAFE);
                for (si = 0; si < FFT_N; si = si + 1)
                    send_one({16'd0, si[15:0]});
            end

            // Receiver with backpressure: pause m_tready periodically
            begin : t4_receiver
                integer ri;
                ri = 0;
                while (ri < FFT_N) begin
                    @(posedge clk);
                    // Deassert m_tready for 3 cycles every 10 captured samples
                    if (ri > 0 && (ri % 10) == 0 && m_tready) begin
                        m_tready <= 1'b0;
                        repeat (3) @(posedge clk);
                        m_tready <= 1'b1;
                    end
                    if (m_tvalid && m_tready) begin
                        captured_data[ri] = m_tdata;
                        captured_last[ri] = m_tlast;
                        ri = ri + 1;
                    end
                end
                cap_count = ri;
            end
        join

        // Verify all 64 samples correct despite backpressure
        errors = 0;
        for (i = 0; i < FFT_N; i = i + 1) begin
            if (captured_data[i] != {16'd0, i[15:0]}) begin
                if (errors < 5)
                    $display("  ERROR: sample[%0d] = 0x%08X, expected 0x%08X",
                             i, captured_data[i], {16'd0, i[15:0]});
                errors = errors + 1;
            end
        end

        if (errors == 0) begin
            $display("  TEST 4: PASS (no data loss with backpressure)");
            pass_count = pass_count + 1;
        end else begin
            $display("  TEST 4: FAIL (%0d errors)", errors);
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
