// =============================================================================
// tb_channel_model_top.sv — Testbench for channel_model_top module
// =============================================================================
// Self-checking testbench with 4 tests:
//   1. Bypass mode (channel_bypass=1, noise_enable=0)
//   2. FIR only (flat profile, noise_enable=0)
//   3. Noise only (channel_bypass=1, noise_enable=1, zero input)
//   4. FIR + noise (two-tap profile + noise)
//
// RTL dependencies:
//   lfsr64.sv
//   awgn_generator.sv
//   channel_fir_sparse.sv
//   channel_profile_rom.sv
//   channel_model_top.sv
//
// Compile (iverilog v12):
//   iverilog -g2012 -o tb_channel_model_top \
//     ../rtl/lfsr64.sv \
//     ../rtl/awgn_generator.sv \
//     ../rtl/channel_fir_sparse.sv \
//     ../rtl/channel_profile_rom.sv \
//     ../rtl/channel_model_top.sv \
//     tb_channel_model_top.sv
// =============================================================================

`timescale 1ns / 1ps

module tb_channel_model_top;

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    localparam real CLK_HALF = 5.0;  // 100 MHz

    // -------------------------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------------------------
    logic        clk;
    logic        rst_n;

    logic [31:0] s_tdata;
    logic        s_tvalid;
    logic        s_tready;
    logic        s_tlast;

    logic [31:0] m_tdata;
    logic        m_tvalid;
    logic        m_tlast;

    logic [3:0]  profile_sel;
    logic        load_profile;
    logic [15:0] noise_scale;
    logic        noise_enable;
    logic [63:0] awgn_seed_i;
    logic [63:0] awgn_seed_q;
    logic        channel_bypass;

    logic        coeff_wen;
    logic [2:0]  coeff_addr;
    logic [7:0]  coeff_delay;
    logic signed [15:0] coeff_re;
    logic signed [15:0] coeff_im;

    // -------------------------------------------------------------------------
    // DUT instantiation
    // -------------------------------------------------------------------------
    channel_model_top dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .s_tdata         (s_tdata),
        .s_tvalid        (s_tvalid),
        .s_tready        (s_tready),
        .s_tlast         (s_tlast),
        .m_tdata         (m_tdata),
        .m_tvalid        (m_tvalid),
        .m_tlast         (m_tlast),
        .profile_sel     (profile_sel),
        .load_profile    (load_profile),
        .noise_scale     (noise_scale),
        .noise_enable    (noise_enable),
        .awgn_seed_i     (awgn_seed_i),
        .awgn_seed_q     (awgn_seed_q),
        .channel_bypass  (channel_bypass),
        .coeff_wen       (coeff_wen),
        .coeff_addr      (coeff_addr),
        .coeff_delay     (coeff_delay),
        .coeff_re        (coeff_re),
        .coeff_im        (coeff_im)
    );

    // -------------------------------------------------------------------------
    // Clock generation
    // -------------------------------------------------------------------------
    initial clk = 0;
    always #(CLK_HALF) clk = ~clk;

    // -------------------------------------------------------------------------
    // Timeout watchdog: 20 ms
    // -------------------------------------------------------------------------
    initial begin
        #20_000_000;
        $display("TIMEOUT: Simulation exceeded 20 ms");
        $finish;
    end

    // -------------------------------------------------------------------------
    // Test variables (module-level for iverilog compatibility)
    // -------------------------------------------------------------------------
    integer pass_count;
    integer fail_count;
    integer i;
    integer max_err;
    integer err_i, err_q;
    integer nonzero_count;

    logic [31:0] out_data;
    logic        out_last;
    logic signed [15:0] in_i_val, in_q_val;
    logic signed [15:0] out_i, out_q;

    // -------------------------------------------------------------------------
    // Helper tasks
    // -------------------------------------------------------------------------

    // Send one AXI-Stream sample; wait for tready handshake
    task send_sample(
        input signed [15:0] i_val,
        input signed [15:0] q_val,
        input               last
    );
        s_tdata  <= {q_val, i_val};
        s_tvalid <= 1'b1;
        s_tlast  <= last;
        @(posedge clk);
        while (!s_tready) @(posedge clk);
        // Handshake occurred
        @(posedge clk);
        s_tvalid <= 1'b0;
        s_tlast  <= 1'b0;
    endtask

    // Wait for one output sample
    task wait_output;
        while (!m_tvalid) @(posedge clk);
        out_data = m_tdata;
        out_last = m_tlast;
        @(posedge clk);
    endtask

    // Load a profile and wait for completion
    task load_channel_profile(
        input [3:0] sel
    );
        profile_sel  <= sel;
        @(posedge clk);
        load_profile <= 1'b1;
        @(posedge clk);
        load_profile <= 1'b0;
        // Wait for profile load FSM to complete
        repeat (30) @(posedge clk);
    endtask

    // -------------------------------------------------------------------------
    // Main test sequence
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("tb_channel_model_top.vcd");
        $dumpvars(0, tb_channel_model_top);

        // Initialize all signals
        rst_n          = 1'b0;
        s_tdata        = 32'd0;
        s_tvalid       = 1'b0;
        s_tlast        = 1'b0;
        profile_sel    = 4'd0;
        load_profile   = 1'b0;
        noise_scale    = 16'h0080;   // 0.5 in Q8.8
        noise_enable   = 1'b0;
        awgn_seed_i    = 64'hDEAD_BEEF_CAFE_BABE;
        awgn_seed_q    = 64'h1234_5678_9ABC_DEF0;
        channel_bypass = 1'b0;
        coeff_wen      = 1'b0;
        coeff_addr     = 3'd0;
        coeff_delay    = 8'd0;
        coeff_re       = 16'sd0;
        coeff_im       = 16'sd0;
        pass_count     = 0;
        fail_count     = 0;

        // Release reset
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        // =============================================================
        // TEST 1: Bypass mode (channel_bypass=1, noise_enable=0)
        // =============================================================
        $display("\n=== TEST 1: Bypass mode ===");

        channel_bypass = 1'b1;
        noise_enable   = 1'b0;
        repeat (5) @(posedge clk);

        max_err = 0;
        for (i = 0; i < 20; i = i + 1) begin
            in_i_val = 16'sd1000 + i * 16'sd100;
            in_q_val = 16'sd2000 - i * 16'sd50;

            send_sample(in_i_val, in_q_val, (i == 19) ? 1'b1 : 1'b0);
            wait_output;

            out_i = $signed(out_data[15:0]);
            out_q = $signed(out_data[31:16]);

            err_i = (out_i > in_i_val) ? (out_i - in_i_val) : (in_i_val - out_i);
            err_q = (out_q > in_q_val) ? (out_q - in_q_val) : (in_q_val - out_q);
            if (err_i > max_err) max_err = err_i;
            if (err_q > max_err) max_err = err_q;
        end

        $display("  Max error: %0d", max_err);
        if (max_err == 0) begin
            $display("  TEST 1: PASS");
            pass_count = pass_count + 1;
        end else begin
            $display("  TEST 1: FAIL");
            fail_count = fail_count + 1;
        end

        // =============================================================
        // TEST 2: FIR only — flat profile (profile 0), noise off
        // =============================================================
        $display("\n=== TEST 2: FIR only (flat profile) ===");

        channel_bypass = 1'b0;
        noise_enable   = 1'b0;

        // Load flat profile (profile 0: 1 tap, delay 0, coeff 1.0)
        load_channel_profile(4'd0);

        max_err = 0;
        for (i = 0; i < 10; i = i + 1) begin
            in_i_val = 16'sd500 + i * 16'sd200;
            in_q_val = -(16'sd300 + i * 16'sd100);

            send_sample(in_i_val, in_q_val, (i == 9) ? 1'b1 : 1'b0);
            wait_output;

            out_i = $signed(out_data[15:0]);
            out_q = $signed(out_data[31:16]);

            err_i = (out_i > in_i_val) ? (out_i - in_i_val) : (in_i_val - out_i);
            err_q = (out_q > in_q_val) ? (out_q - in_q_val) : (in_q_val - out_q);
            if (err_i > max_err) max_err = err_i;
            if (err_q > max_err) max_err = err_q;

            $display("  Sample %0d: in=(%0d,%0d) out=(%0d,%0d) err=(%0d,%0d)",
                     i, in_i_val, in_q_val, out_i, out_q, err_i, err_q);
        end

        // Allow small rounding error (up to 2 LSB)
        if (max_err <= 2) begin
            $display("  TEST 2: PASS (max error = %0d)", max_err);
            pass_count = pass_count + 1;
        end else begin
            $display("  TEST 2: FAIL (max error = %0d)", max_err);
            fail_count = fail_count + 1;
        end

        // Flush pipeline
        repeat (5) begin
            send_sample(16'sd0, 16'sd0, 1'b0);
            repeat (30) @(posedge clk);
        end

        // =============================================================
        // TEST 3: Noise only (bypass=1, noise_enable=1, zero input)
        // =============================================================
        $display("\n=== TEST 3: Noise only (zero input + AWGN) ===");

        channel_bypass = 1'b1;
        noise_enable   = 1'b1;
        noise_scale    = 16'h0100;  // 1.0 in Q8.8
        repeat (5) @(posedge clk);

        nonzero_count = 0;

        for (i = 0; i < 20; i = i + 1) begin
            send_sample(16'sd0, 16'sd0, 1'b0);
            wait_output;

            out_i = $signed(out_data[15:0]);
            out_q = $signed(out_data[31:16]);

            if (out_i != 0 || out_q != 0)
                nonzero_count = nonzero_count + 1;

            $display("  Sample %0d: out=(%0d, %0d)", i, out_i, out_q);
        end

        $display("  Non-zero outputs: %0d / 20", nonzero_count);
        if (nonzero_count >= 5) begin
            $display("  TEST 3: PASS");
            pass_count = pass_count + 1;
        end else begin
            $display("  TEST 3: FAIL");
            fail_count = fail_count + 1;
        end

        // =============================================================
        // TEST 4: FIR + noise (two-tap profile + AWGN)
        // =============================================================
        $display("\n=== TEST 4: FIR + noise (two-tap profile) ===");

        channel_bypass = 1'b0;
        noise_enable   = 1'b1;
        noise_scale    = 16'h0040;  // 0.25 in Q8.8 (small noise)

        // Load two-tap profile (profile 1)
        load_channel_profile(4'd1);

        // Send impulse followed by zeros
        send_sample(16'sd10000, 16'sd0, 1'b0);
        wait_output;
        $display("  Impulse response[0]: I=%0d", $signed(out_data[15:0]));

        nonzero_count = 0;
        for (i = 1; i < 10; i = i + 1) begin
            send_sample(16'sd0, 16'sd0, (i == 9) ? 1'b1 : 1'b0);
            wait_output;
            out_i = $signed(out_data[15:0]);
            $display("  Impulse response[%0d]: I=%0d", i, out_i);
            if (out_i != 0)
                nonzero_count = nonzero_count + 1;
        end

        $display("  Non-zero trailing outputs: %0d / 9", nonzero_count);
        if (nonzero_count >= 1) begin
            $display("  TEST 4: PASS");
            pass_count = pass_count + 1;
        end else begin
            $display("  TEST 4: FAIL");
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
