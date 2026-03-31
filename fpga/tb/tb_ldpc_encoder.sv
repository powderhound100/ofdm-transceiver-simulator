// =============================================================================
// tb_ldpc_encoder.sv — Testbench for LDPC Encoder
// =============================================================================
// Tests: all-zero info bits, alternating pattern.
// iverilog v12 compatible.
// =============================================================================
`timescale 1ns / 1ps

module tb_ldpc_encoder;

    // Parameters
    localparam integer Z  = 27;
    localparam integer MB = 12;
    localparam integer NB = 24;
    localparam integer K  = MB * Z;  // 324 info bits
    localparam integer N  = NB * Z;  // 648 codeword bits

    // Clock / reset
    logic clk;
    logic rst_n;

    // DUT signals
    logic s_tdata;
    logic s_tvalid;
    logic s_tready;
    logic s_tlast;

    logic m_tdata;
    logic m_tvalid;
    logic m_tready;
    logic m_tlast;
    logic busy;

    // DUT
    ldpc_encoder #(
        .Z (Z),
        .MB(MB),
        .NB(NB)
    ) dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .s_tdata (s_tdata),
        .s_tvalid(s_tvalid),
        .s_tready(s_tready),
        .s_tlast (s_tlast),
        .m_tdata (m_tdata),
        .m_tvalid(m_tvalid),
        .m_tready(m_tready),
        .m_tlast (m_tlast),
        .busy    (busy)
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
    logic codeword [0:N-1];
    integer out_cnt;
    logic   saw_tlast;

    // Task: reset
    task do_reset;
        begin
            rst_n     = 0;
            s_tdata   = 0;
            s_tvalid  = 0;
            s_tlast   = 0;
            m_tready  = 1;
            repeat (10) @(posedge clk);
            rst_n = 1;
            repeat (5) @(posedge clk);
        end
    endtask

    // Task: send K info bits (0 = all zero, 1 = alternating)
    task send_info;
        input integer pattern; // 0=all-zero, 1=alternating
        integer j;
        begin
            for (j = 0; j < K; j = j + 1) begin
                // Wait for tready
                while (!s_tready) @(posedge clk);
                @(posedge clk);
                if (pattern == 0)
                    s_tdata = 1'b0;
                else
                    s_tdata = j[0]; // alternating: 0,1,0,1,...
                s_tvalid = 1;
                s_tlast  = (j == K - 1) ? 1'b1 : 1'b0;
            end
            @(posedge clk);
            s_tvalid = 0;
            s_tlast  = 0;
        end
    endtask

    // Task: collect N=648 codeword bits
    task collect_codeword;
        begin
            out_cnt   = 0;
            saw_tlast = 0;
            timeout_cnt = 0;
            while (out_cnt < N && timeout_cnt < 500000) begin
                @(posedge clk);
                timeout_cnt = timeout_cnt + 1;
                if (m_tvalid && m_tready) begin
                    codeword[out_cnt] = m_tdata;
                    if (m_tlast) saw_tlast = 1;
                    out_cnt = out_cnt + 1;
                end
            end
            if (timeout_cnt >= 500000) begin
                $display("FAIL: Timeout collecting codeword (got %0d/%0d)", out_cnt, N);
                errors = errors + 1;
            end
        end
    endtask

    // Main test
    initial begin
        $dumpfile("tb_ldpc_encoder.vcd");
        $dumpvars(0, tb_ldpc_encoder);

        errors = 0;
        tests  = 0;

        // =====================================================================
        // Test 1: All-zero info bits -> all-zero codeword (linearity)
        // =====================================================================
        $display("=== Test 1: All-zero info bits ===");
        do_reset;
        send_info(0);
        collect_codeword;

        // Verify codeword length
        if (out_cnt != N) begin
            $display("FAIL: Test1 codeword length=%0d, expected %0d", out_cnt, N);
            errors = errors + 1;
        end
        tests = tests + 1;

        // Verify all bits are zero
        begin
            integer nonzero;
            nonzero = 0;
            for (i = 0; i < N; i = i + 1) begin
                if (codeword[i] != 1'b0) nonzero = nonzero + 1;
            end
            if (nonzero != 0) begin
                $display("FAIL: Test1 all-zero codeword has %0d nonzero bits", nonzero);
                errors = errors + 1;
            end
            tests = tests + 1;
        end

        // =====================================================================
        // Test 2: Alternating info bits — verify systematic property and length
        // =====================================================================
        $display("=== Test 2: Alternating info bits ===");
        do_reset;
        send_info(1);
        collect_codeword;

        // Verify codeword length = 648
        if (out_cnt != N) begin
            $display("FAIL: Test2 codeword length=%0d, expected %0d", out_cnt, N);
            errors = errors + 1;
        end
        tests = tests + 1;

        // Verify systematic property: first K bits = info bits
        begin
            integer sys_err;
            sys_err = 0;
            for (i = 0; i < K; i = i + 1) begin
                if (codeword[i] != i[0]) begin
                    sys_err = sys_err + 1;
                end
            end
            if (sys_err != 0) begin
                $display("FAIL: Test2 systematic portion has %0d mismatches", sys_err);
                errors = errors + 1;
            end
            tests = tests + 1;
        end

        // Verify m_tlast was asserted
        if (!saw_tlast) begin
            $display("FAIL: Test2 m_tlast never asserted");
            errors = errors + 1;
        end
        tests = tests + 1;

        // Verify parity bits are not all zero (non-trivial encoding)
        begin
            integer parity_ones;
            parity_ones = 0;
            for (i = K; i < N; i = i + 1) begin
                if (codeword[i]) parity_ones = parity_ones + 1;
            end
            $display("  Parity bits: %0d ones out of %0d", parity_ones, N - K);
            if (parity_ones == 0) begin
                $display("FAIL: Test2 parity bits all zero for non-zero input");
                errors = errors + 1;
            end
            tests = tests + 1;
        end

        // =====================================================================
        // Report
        // =====================================================================
        $display("");
        if (errors == 0)
            $display("PASS: All %0d ldpc_encoder tests passed.", tests);
        else
            $display("FAIL: %0d / %0d ldpc_encoder tests failed.", errors, tests);

        #100;
        $finish;
    end

    // Global timeout
    initial begin
        #20_000_000;
        $display("FAIL: Global timeout (20ms)");
        $finish;
    end

endmodule
