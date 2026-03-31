// =============================================================================
// tb_ldpc_sweep.sv -- Streamlined LDPC decode TB for BER co-simulation
// =============================================================================
// Reads LLRs from rtl_sweep_llr.hex, decodes, prints decoded bits + stats.
// No VCD dump for speed.
// =============================================================================

`timescale 1ns / 1ps

module tb_ldpc_sweep;

    localparam int Z        = 27;
    localparam int W        = 6;
    localparam int MB       = 12;
    localparam int NB       = 24;
    localparam int N        = NB * Z;  // 648
    localparam int MAX_ITER = 50;
    localparam real CLK_PERIOD = 10.0;

    logic              clk;
    logic              rst_n;
    logic [W-1:0]      s_tdata;
    logic              s_tvalid;
    logic              s_tready;
    logic              s_tlast;
    logic              m_tdata;
    logic              m_tvalid;
    logic              m_tready;
    logic              m_tlast;
    logic              busy;
    logic              decode_done;
    logic              decode_converged;
    logic [5:0]        decode_iterations;

    ldpc_top #(
        .Z(Z), .W(W), .MB(MB), .NB(NB), .MAX_ITER(MAX_ITER)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .s_tdata(s_tdata), .s_tvalid(s_tvalid), .s_tready(s_tready), .s_tlast(s_tlast),
        .m_tdata(m_tdata), .m_tvalid(m_tvalid), .m_tready(m_tready), .m_tlast(m_tlast),
        .busy(busy), .decode_done(decode_done),
        .decode_converged(decode_converged), .decode_iterations(decode_iterations)
    );

    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    logic [W-1:0] llr_data [0:N-1];
    logic decoded_bits [0:N-1];

    initial begin
        $readmemh("../../test_vectors/rtl_sweep_llr.hex", llr_data);
    end

    task send_llr_frame();
        for (int i = 0; i < N; i++) begin
            s_tdata  <= llr_data[i];
            s_tvalid <= 1'b1;
            s_tlast  <= (i == N - 1);
            @(posedge clk);
            while (!s_tready) @(posedge clk);
        end
        s_tvalid <= 1'b0;
        s_tlast  <= 1'b0;
    endtask

    task wait_for_done(input int max_cycles);
        int cnt;
        cnt = 0;
        while (!decode_done && cnt < max_cycles) begin
            @(posedge clk);
            cnt++;
        end
    endtask

    task read_decoded_bits();
        int idx;
        idx = 0;
        m_tready <= 1'b1;
        while (idx < N) begin
            @(posedge clk);
            if (m_tvalid) begin
                decoded_bits[idx] = m_tdata;
                idx++;
            end
        end
        m_tready <= 1'b0;
    endtask

    // Pack bits into hex for output
    initial begin
        rst_n    = 0;
        s_tdata  = '0;
        s_tvalid = 0;
        s_tlast  = 0;
        m_tready = 0;

        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        send_llr_frame();
        wait_for_done(1000000);

        if (decode_done) begin
            read_decoded_bits();

            // Print decoded bits as hex string
            // Pack N bits into hex nibbles
            begin
                reg [N-1:0] packed_bits;
                int bit_errors;
                bit_errors = 0;
                for (int i = 0; i < N; i++) begin
                    packed_bits[N-1-i] = decoded_bits[i];
                end
                $display("DECODED:%0h", packed_bits);
                $display("STATS:converged=%0b,iters=%0d", decode_converged, decode_iterations);
            end
        end else begin
            $display("STATS:converged=0,iters=%0d", MAX_ITER);
        end

        $finish;
    end

    // Timeout
    initial begin
        #50000000;
        $display("STATS:converged=0,iters=%0d", MAX_ITER);
        $finish;
    end

endmodule
