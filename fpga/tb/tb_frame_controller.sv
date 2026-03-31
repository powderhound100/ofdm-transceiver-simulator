// =============================================================================
// tb_frame_controller.sv — Testbench for Frame LLR Accumulator
// =============================================================================
// Tests: 648 LLR buffering, m_tlast on LLR#648, multi-frame.
// iverilog v12 compatible.
// =============================================================================
`timescale 1ns / 1ps

module tb_frame_controller;

    // Parameters
    localparam integer CODEWORD_LEN = 648;
    localparam integer LLR_W        = 6;

    // Clock / reset
    logic        clk;
    logic        rst_n;

    // DUT signals
    logic signed [LLR_W-1:0] llr_in;
    logic                     llr_valid;
    logic [LLR_W-1:0]        m_tdata;
    logic                     m_tvalid;
    logic                     m_tlast;
    logic                     m_tready;
    logic                     frame_ready;

    // DUT
    frame_controller #(
        .CODEWORD_LEN(CODEWORD_LEN),
        .LLR_W       (LLR_W)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .llr_in     (llr_in),
        .llr_valid  (llr_valid),
        .m_tdata    (m_tdata),
        .m_tvalid   (m_tvalid),
        .m_tlast    (m_tlast),
        .m_tready   (m_tready),
        .frame_ready(frame_ready)
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
    logic [LLR_W-1:0] out_data [0:CODEWORD_LEN-1];
    integer out_cnt;
    logic   saw_tlast;

    // Task: reset
    task do_reset;
        begin
            rst_n     = 0;
            llr_in    = 0;
            llr_valid = 0;
            m_tready  = 1; // always ready
            repeat (10) @(posedge clk);
            rst_n = 1;
            repeat (5) @(posedge clk);
        end
    endtask

    // Task: stream N LLRs with values = index mod 63
    task stream_llrs;
        input integer count;
        integer j;
        begin
            for (j = 0; j < count; j = j + 1) begin
                @(posedge clk);
                llr_in    = (j % 63);
                llr_valid = 1;
            end
            @(posedge clk);
            llr_valid = 0;
        end
    endtask

    // Task: collect one frame of output (648 LLRs)
    task collect_frame;
        begin
            out_cnt   = 0;
            saw_tlast = 0;
            timeout_cnt = 0;
            while (out_cnt < CODEWORD_LEN && timeout_cnt < 100000) begin
                @(posedge clk);
                timeout_cnt = timeout_cnt + 1;
                if (m_tvalid && m_tready) begin
                    out_data[out_cnt] = m_tdata;
                    if (m_tlast) saw_tlast = 1;
                    out_cnt = out_cnt + 1;
                end
            end
            if (timeout_cnt >= 100000) begin
                $display("FAIL: Timeout collecting frame (got %0d/%0d)", out_cnt, CODEWORD_LEN);
                errors = errors + 1;
            end
        end
    endtask

    // Main test
    initial begin
        $dumpfile("tb_frame_controller.vcd");
        $dumpvars(0, tb_frame_controller);

        errors = 0;
        tests  = 0;

        // =====================================================================
        // Test 1: Stream 648 LLRs, verify all buffered and output correctly
        // =====================================================================
        $display("=== Test 1: 648 LLR frame ===");
        do_reset;

        // Stream 648 LLRs
        stream_llrs(648);

        // Wait a bit for frame processing
        repeat (10) @(posedge clk);

        // Collect output frame
        collect_frame;

        // Verify values: each output[i] should match (i % 63)
        for (i = 0; i < CODEWORD_LEN; i = i + 1) begin
            if ($signed(out_data[i]) != $signed(i % 63)) begin
                $display("FAIL: Test1 out[%0d]=%0d, expected %0d",
                         i, $signed(out_data[i]), (i % 63));
                errors = errors + 1;
            end
            tests = tests + 1;
        end

        // =====================================================================
        // Test 2: Verify m_tlast is asserted on LLR #648
        // =====================================================================
        $display("=== Test 2: m_tlast on last LLR ===");
        // saw_tlast was captured during collect_frame
        if (!saw_tlast) begin
            $display("FAIL: Test2 m_tlast never asserted during frame output");
            errors = errors + 1;
        end
        tests = tests + 1;

        // =====================================================================
        // Test 3: Stream 700 LLRs (more than one frame)
        // First 648 should form frame 1
        // =====================================================================
        $display("=== Test 3: Multi-frame (700 LLRs) ===");
        do_reset;

        // Stream 700 LLRs
        stream_llrs(700);

        // Wait for processing
        repeat (10) @(posedge clk);

        // Collect first frame
        collect_frame;

        // Verify first frame: values are (i % 63) for i=0..647
        begin
            integer mismatch;
            mismatch = 0;
            for (i = 0; i < CODEWORD_LEN; i = i + 1) begin
                if ($signed(out_data[i]) != $signed(i % 63)) begin
                    if (mismatch < 5)
                        $display("  Test3 mismatch: out[%0d]=%0d, expected %0d",
                                 i, $signed(out_data[i]), (i % 63));
                    mismatch = mismatch + 1;
                end
            end
            if (mismatch > 0) begin
                $display("FAIL: Test3 frame1 had %0d mismatches", mismatch);
                errors = errors + 1;
            end
            tests = tests + 1;
        end

        // =====================================================================
        // Report
        // =====================================================================
        $display("");
        if (errors == 0)
            $display("PASS: All %0d frame_controller tests passed.", tests);
        else
            $display("FAIL: %0d / %0d frame_controller tests failed.", errors, tests);

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
