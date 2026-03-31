// =============================================================================
// tb_channel_fir_dense128.sv — Testbench for channel_fir_dense128 module
// =============================================================================
// Self-checking testbench with 4 tests:
//   1. Impulse response (single tap)
//   2. Flat channel (passthrough)
//   3. Two-tap multipath
//   4. Energy conservation
//
// RTL dependencies:
//   channel_fir_dense128.sv
//
// Compile (iverilog v12):
//   iverilog -g2012 -o tb_channel_fir_dense128 \
//     ../rtl/channel_fir_dense128.sv \
//     tb_channel_fir_dense128.sv
// =============================================================================

`timescale 1ns / 1ps

module tb_channel_fir_dense128;

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    localparam int NUM_TAPS = 128;
    localparam int IQ_W     = 16;

    // Clock: 100 MHz -> 5 ns half period
    localparam real CLK_HALF = 5.0;

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

    logic [2:0]  num_taps;

    logic        coeff_wen;
    logic [6:0]  coeff_addr;
    logic signed [15:0] coeff_re;
    logic signed [15:0] coeff_im;

    // -------------------------------------------------------------------------
    // DUT instantiation
    // -------------------------------------------------------------------------
    channel_fir_dense128 #(
        .NUM_TAPS   (NUM_TAPS),
        .IQ_W       (IQ_W)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .s_tdata   (s_tdata),
        .s_tvalid  (s_tvalid),
        .s_tready  (s_tready),
        .s_tlast   (s_tlast),
        .m_tdata   (m_tdata),
        .m_tvalid  (m_tvalid),
        .m_tlast   (m_tlast),
        .num_taps  (num_taps),
        .coeff_wen (coeff_wen),
        .coeff_addr(coeff_addr),
        .coeff_re  (coeff_re),
        .coeff_im  (coeff_im)
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
    integer i;
    integer max_err;
    integer err_i, err_q;
    integer pulse_count;
    integer first_pulse_idx, second_pulse_idx;
    real    ratio;

    logic [31:0] out_data;
    logic        out_last;
    logic signed [15:0] out_i, out_q;
    logic signed [15:0] in_i, in_q;
    logic signed [15:0] captured_i [0:31];

    // 64-bit accumulators for energy test
    logic signed [63:0] energy_in;
    logic signed [63:0] energy_out;

    // -------------------------------------------------------------------------
    // LFSR for pseudo-random test data (simple 32-bit)
    // -------------------------------------------------------------------------
    logic [31:0] lfsr_state;

    function [31:0] lfsr_next(input [31:0] s);
        logic feedback;
        feedback = s[31] ^ s[21] ^ s[1] ^ s[0];
        lfsr_next = {s[30:0], feedback};
    endfunction

    // -------------------------------------------------------------------------
    // Helper tasks
    // -------------------------------------------------------------------------

    // Write a single tap coefficient (dense: addr IS the delay)
    task write_tap(
        input [6:0]  addr,
        input signed [15:0] re,
        input signed [15:0] im
    );
        @(posedge clk);
        coeff_wen  <= 1'b1;
        coeff_addr <= addr;
        coeff_re   <= re;
        coeff_im   <= im;
        @(posedge clk);
        coeff_wen  <= 1'b0;
    endtask

    // Clear all taps to zero
    task clear_all_taps;
        for (i = 0; i < NUM_TAPS; i = i + 1) begin
            write_tap(i[6:0], 16'sd0, 16'sd0);
        end
    endtask

    // Send one sample (waits for tready handshake)
    task send_sample(
        input signed [15:0] i_val,
        input signed [15:0] q_val,
        input               last
    );
        while (!s_tready) @(posedge clk);
        s_tdata  <= {q_val, i_val};
        s_tvalid <= 1'b1;
        s_tlast  <= last;
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

    // -------------------------------------------------------------------------
    // Main test sequence
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("tb_channel_fir_dense128.vcd");
        $dumpvars(0, tb_channel_fir_dense128);

        // Initialize
        rst_n      = 1'b0;
        s_tdata    = 32'd0;
        s_tvalid   = 1'b0;
        s_tlast    = 1'b0;
        num_taps   = 3'd0;
        coeff_wen  = 1'b0;
        coeff_addr = 7'd0;
        coeff_re   = 16'sd0;
        coeff_im   = 16'sd0;
        pass_count = 0;
        fail_count = 0;
        lfsr_state = 32'hA5A5_1234;

        // Release reset
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        // =============================================================
        // TEST 1: Impulse response — single tap
        // =============================================================
        $display("\n=== TEST 1: Impulse response (single tap) ===");

        // Clear all taps, then set tap 0: coeff = 0.5+j0.25
        // 0.5 in Q1.14 = 8192, 0.25 in Q1.14 = 4096
        clear_all_taps;
        write_tap(7'd0, 16'sd8192, 16'sd4096);
        repeat (3) @(posedge clk);

        // Send impulse: I=16384 (1.0 in Q1.14 scale), Q=0
        send_sample(16'sd16384, 16'sd0, 1'b0);
        wait_output;

        out_i = $signed(out_data[15:0]);
        out_q = $signed(out_data[31:16]);

        // Expected: (1.0+j0) * (0.5+j0.25) = 0.5+j0.25
        // Result I = (16384*8192 - 0*4096) >> 14 = 8192
        // Result Q = (16384*4096 + 0*8192) >> 14 = 4096
        $display("  Output I=%0d (expected ~8192), Q=%0d (expected ~4096)", out_i, out_q);

        if (out_i >= 8000 && out_i <= 8400 && out_q >= 3900 && out_q <= 4300) begin
            $display("  TEST 1: PASS");
            pass_count = pass_count + 1;
        end else begin
            $display("  TEST 1: FAIL");
            fail_count = fail_count + 1;
        end

        // Flush: send zeros to clear the pipeline
        repeat (NUM_TAPS + 5) begin
            send_sample(16'sd0, 16'sd0, 1'b0);
            repeat (40) @(posedge clk);
        end

        // =============================================================
        // TEST 2: Flat channel — passthrough with unity coefficient
        // =============================================================
        $display("\n=== TEST 2: Flat channel (passthrough) ===");

        // Clear all taps, then set tap 0: coeff = 1.0+j0
        clear_all_taps;
        write_tap(7'd0, 16'sd16384, 16'sd0);
        repeat (3) @(posedge clk);

        max_err = 0;
        for (i = 0; i < 10; i = i + 1) begin
            // Generate pseudo-random samples
            lfsr_state = lfsr_next(lfsr_state);
            in_i = $signed(lfsr_state[15:0]) >>> 2;
            lfsr_state = lfsr_next(lfsr_state);
            in_q = $signed(lfsr_state[15:0]) >>> 2;

            send_sample(in_i, in_q, (i == 9) ? 1'b1 : 1'b0);
            wait_output;

            out_i = $signed(out_data[15:0]);
            out_q = $signed(out_data[31:16]);

            err_i = (out_i > in_i) ? (out_i - in_i) : (in_i - out_i);
            err_q = (out_q > in_q) ? (out_q - in_q) : (in_q - out_q);

            if (err_i > max_err) max_err = err_i;
            if (err_q > max_err) max_err = err_q;

            $display("  Sample %0d: in=(%0d,%0d) out=(%0d,%0d) err=(%0d,%0d)",
                     i, in_i, in_q, out_i, out_q, err_i, err_q);
        end

        if (max_err <= 2) begin
            $display("  TEST 2: PASS (max error = %0d)", max_err);
            pass_count = pass_count + 1;
        end else begin
            $display("  TEST 2: FAIL (max error = %0d)", max_err);
            fail_count = fail_count + 1;
        end

        // Flush pipeline
        repeat (NUM_TAPS + 5) begin
            send_sample(16'sd0, 16'sd0, 1'b0);
            repeat (40) @(posedge clk);
        end

        // =============================================================
        // TEST 3: Two-tap — impulse yields two pulses 5 samples apart
        // =============================================================
        $display("\n=== TEST 3: Two-tap (index 0 and 5, coeff 0.5 each) ===");

        // Clear all taps, then set tap 0 and tap 5: both 0.5+j0
        clear_all_taps;
        write_tap(7'd0, 16'sd8192, 16'sd0);
        write_tap(7'd5, 16'sd8192, 16'sd0);
        repeat (3) @(posedge clk);

        // Send impulse followed by 15 zeros
        send_sample(16'sd16384, 16'sd0, 1'b0);
        wait_output;
        captured_i[0] = $signed(out_data[15:0]);

        for (i = 1; i < 16; i = i + 1) begin
            send_sample(16'sd0, 16'sd0, (i == 15) ? 1'b1 : 1'b0);
            wait_output;
            captured_i[i] = $signed(out_data[15:0]);
        end

        // Analyze: expect two non-zero pulses separated by 5 samples
        pulse_count = 0;
        first_pulse_idx = -1;
        second_pulse_idx = -1;
        for (i = 0; i < 16; i = i + 1) begin
            $display("  Output[%0d]: I=%0d", i, captured_i[i]);
            if (captured_i[i] > 100 || captured_i[i] < -100) begin
                if (pulse_count == 0) first_pulse_idx = i;
                else if (pulse_count == 1) second_pulse_idx = i;
                pulse_count = pulse_count + 1;
            end
        end

        $display("  Pulses found: %0d, at indices %0d and %0d",
                 pulse_count, first_pulse_idx, second_pulse_idx);

        if (pulse_count == 2 && (second_pulse_idx - first_pulse_idx) == 5) begin
            $display("  TEST 3: PASS");
            pass_count = pass_count + 1;
        end else begin
            $display("  TEST 3: FAIL");
            fail_count = fail_count + 1;
        end

        // Flush pipeline
        repeat (NUM_TAPS + 10) begin
            send_sample(16'sd0, 16'sd0, 1'b0);
            repeat (40) @(posedge clk);
        end

        // =============================================================
        // TEST 4: Energy check — 100 samples through 3-tap filter
        // =============================================================
        $display("\n=== TEST 4: Energy conservation (3-tap filter) ===");

        // Clear all taps, then configure 3 taps, energy-normalized
        // c0=0.8(Q1.14=13107), c1=0.5(8192), c2=0.3(4915)
        // |c|^2 = 0.64+0.25+0.09 = 0.98
        clear_all_taps;
        write_tap(7'd0, 16'sd13107, 16'sd0);
        write_tap(7'd3, 16'sd8192,  16'sd0);
        write_tap(7'd7, 16'sd4915,  16'sd0);
        repeat (3) @(posedge clk);

        energy_in  = 0;
        energy_out = 0;

        // Send 100 random samples
        for (i = 0; i < 100; i = i + 1) begin
            lfsr_state = lfsr_next(lfsr_state);
            in_i = $signed(lfsr_state[15:0]) >>> 3;
            lfsr_state = lfsr_next(lfsr_state);
            in_q = $signed(lfsr_state[15:0]) >>> 3;

            energy_in = energy_in + (in_i * in_i) + (in_q * in_q);

            send_sample(in_i, in_q, (i == 99) ? 1'b1 : 1'b0);
            wait_output;

            out_i = $signed(out_data[15:0]);
            out_q = $signed(out_data[31:16]);
            energy_out = energy_out + (out_i * out_i) + (out_q * out_q);
        end

        // Collect tail energy (multipath extends beyond input)
        for (i = 0; i < 10; i = i + 1) begin
            send_sample(16'sd0, 16'sd0, 1'b0);
            wait_output;
            out_i = $signed(out_data[15:0]);
            out_q = $signed(out_data[31:16]);
            energy_out = energy_out + (out_i * out_i) + (out_q * out_q);
        end

        if (energy_in > 0)
            ratio = $itor(energy_out) / $itor(energy_in);
        else
            ratio = 0.0;

        $display("  Energy in:  %0d", energy_in);
        $display("  Energy out: %0d", energy_out);
        $display("  Ratio: %f", ratio);

        // Ratio should be near 0.98; allow 0.80 to 1.15
        if (ratio > 0.80 && ratio < 1.15) begin
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
