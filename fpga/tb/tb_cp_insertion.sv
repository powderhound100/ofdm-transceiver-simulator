// =============================================================================
// tb_cp_insertion.sv — Testbench for Cyclic Prefix Insertion
// =============================================================================
// Tests: 64 samples -> 80 output, m_tlast on sample 79.
// iverilog v12 compatible.
// =============================================================================
`timescale 1ns / 1ps

module tb_cp_insertion;

    // Parameters
    localparam integer FFT_N  = 64;
    localparam integer CP_LEN = 16;
    localparam integer TOTAL  = FFT_N + CP_LEN; // 80

    // Clock / reset
    logic        clk;
    logic        rst_n;

    // DUT signals
    logic [31:0] s_tdata;
    logic        s_tvalid;
    logic        s_tready;
    logic [31:0] m_tdata;
    logic        m_tvalid;
    logic        m_tready;
    logic        m_tlast;

    // DUT
    cp_insertion #(
        .FFT_N (FFT_N),
        .CP_LEN(CP_LEN)
    ) dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .s_tdata (s_tdata),
        .s_tvalid(s_tvalid),
        .s_tready(s_tready),
        .m_tdata (m_tdata),
        .m_tvalid(m_tvalid),
        .m_tready(m_tready),
        .m_tlast (m_tlast)
    );

    // Clock: 100 MHz
    initial clk = 0;
    always #5 clk = ~clk;

    // Helpers
    integer errors;
    integer tests;
    integer timeout_cnt;
    integer i;

    // Output capture
    logic [31:0] out_samples [0:TOTAL-1];
    integer out_cnt;
    logic   saw_tlast;
    integer tlast_idx;

    // Task: reset
    task do_reset;
        begin
            rst_n    = 0;
            s_tdata  = 0;
            s_tvalid = 0;
            m_tready = 1;
            repeat (10) @(posedge clk);
            rst_n = 1;
            repeat (5) @(posedge clk);
        end
    endtask

    // Task: feed 64 samples with values 0..63 (packed as {Q=0, I=value})
    task feed_samples;
        integer j;
        begin
            for (j = 0; j < FFT_N; j = j + 1) begin
                @(posedge clk);
                while (!s_tready) @(posedge clk);
                s_tdata  = {16'd0, j[15:0]};  // {Q=0, I=j}
                s_tvalid = 1;
            end
            @(posedge clk);
            s_tvalid = 0;
        end
    endtask

    // Task: collect 80 output samples
    task collect_output;
        begin
            out_cnt   = 0;
            saw_tlast = 0;
            tlast_idx = -1;
            timeout_cnt = 0;
            while (out_cnt < TOTAL && timeout_cnt < 10000) begin
                @(posedge clk);
                timeout_cnt = timeout_cnt + 1;
                if (m_tvalid && m_tready) begin
                    out_samples[out_cnt] = m_tdata;
                    if (m_tlast) begin
                        saw_tlast = 1;
                        tlast_idx = out_cnt;
                    end
                    out_cnt = out_cnt + 1;
                end
            end
            if (timeout_cnt >= 10000) begin
                $display("FAIL: Timeout collecting output (got %0d/%0d)", out_cnt, TOTAL);
                errors = errors + 1;
            end
        end
    endtask

    // Main test
    initial begin
        $dumpfile("tb_cp_insertion.vcd");
        $dumpvars(0, tb_cp_insertion);

        errors = 0;
        tests  = 0;

        // =====================================================================
        // Test 1: Feed 64 samples (0..63), verify CP + data output
        // Expected: first 16 samples = samples[48..63] (cyclic prefix)
        //           next 64 samples = samples[0..63]
        // Total = 80 samples
        // =====================================================================
        $display("=== Test 1: CP insertion ===");
        do_reset;

        // Start collecting in parallel with feeding
        fork
            feed_samples;
            collect_output;
        join

        // Verify total count
        if (out_cnt != TOTAL) begin
            $display("FAIL: Test1 got %0d samples, expected %0d", out_cnt, TOTAL);
            errors = errors + 1;
        end
        tests = tests + 1;

        // Verify cyclic prefix: first 16 samples should be input[48..63]
        for (i = 0; i < CP_LEN; i = i + 1) begin
            begin
                integer expected_val;
                logic [15:0] got_val;
                expected_val = FFT_N - CP_LEN + i; // 48, 49, ..., 63
                got_val = out_samples[i][15:0];
                if (got_val != expected_val[15:0]) begin
                    $display("FAIL: Test1 CP sample[%0d]=%0d, expected %0d",
                             i, got_val, expected_val);
                    errors = errors + 1;
                end
                tests = tests + 1;
            end
        end

        // Verify data portion: next 64 samples should be input[0..63]
        for (i = 0; i < FFT_N; i = i + 1) begin
            begin
                logic [15:0] got_val;
                got_val = out_samples[CP_LEN + i][15:0];
                if (got_val != i[15:0]) begin
                    $display("FAIL: Test1 data sample[%0d]=%0d, expected %0d",
                             i, got_val, i);
                    errors = errors + 1;
                end
                tests = tests + 1;
            end
        end

        // =====================================================================
        // Test 2: Verify m_tlast on sample 79 (last output)
        // =====================================================================
        $display("=== Test 2: m_tlast on last sample ===");
        if (!saw_tlast) begin
            $display("FAIL: Test2 m_tlast never asserted");
            errors = errors + 1;
        end else if (tlast_idx != TOTAL - 1) begin
            $display("FAIL: Test2 m_tlast at index %0d, expected %0d", tlast_idx, TOTAL - 1);
            errors = errors + 1;
        end
        tests = tests + 1;

        // =====================================================================
        // Report
        // =====================================================================
        $display("");
        if (errors == 0)
            $display("PASS: All %0d cp_insertion tests passed.", tests);
        else
            $display("FAIL: %0d / %0d cp_insertion tests failed.", errors, tests);

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
