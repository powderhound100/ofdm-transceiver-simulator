// =============================================================================
// tb_ofdm_loopback.sv — End-to-end loopback testbench for OFDM transceiver
// =============================================================================
// Self-checking testbench that exercises the full chain:
//   info_bits -> ofdm_tx_top -> channel_model_top -> ofdm_rx_top -> ldpc_top
//                                                                     |
//                                                               BER comparator
//
// Tests:
//   1. Noiseless flat channel (BER=0) — loads 324 info bits from test vector,
//      bypasses FIR and AWGN, verifies zero bit errors after decode.
//   2. All-zeros test (BER=0) — same config but with all-zero info bits,
//      verifies zero bit errors.
//
// RTL dependencies (all modules in the loopback design):
//   barrel_shifter.sv, sign_xor_tree.sv, min2_finder.sv, check_node_unit.sv,
//   variable_node_unit.sv, message_ram.sv, base_matrix_rom.sv, iteration_ctrl.sv,
//   syndrome_checker.sv, llr_input_buffer.sv, output_buffer.sv, ldpc_top.sv,
//   ldpc_encoder.sv, qam_mapper.sv,
//   fft_butterfly.sv, twiddle_rom.sv, fft_64pt.sv, ifft_64pt.sv,
//   subcarrier_mux.sv, cp_insertion.sv, ofdm_tx_top.sv,
//   channel_fir_sparse.sv, lfsr64.sv, awgn_generator.sv, channel_profile_rom.sv,
//   channel_model_top.sv,
//   cp_removal.sv, subcarrier_demux.sv, channel_estimator.sv, data_align_buffer.sv,
//   reciprocal_lut.sv, equalizer.sv, soft_demapper.sv, frame_controller.sv,
//   ofdm_rx_top.sv,
//   ofdm_loopback_top.sv
//
// Compile (iverilog v12):
//   iverilog -g2012 -o tb_ofdm_loopback \
//     ../rtl/barrel_shifter.sv ../rtl/sign_xor_tree.sv ../rtl/min2_finder.sv \
//     ../rtl/check_node_unit.sv ../rtl/variable_node_unit.sv \
//     ../rtl/message_ram.sv ../rtl/base_matrix_rom.sv ../rtl/iteration_ctrl.sv \
//     ../rtl/syndrome_checker.sv ../rtl/llr_input_buffer.sv \
//     ../rtl/output_buffer.sv ../rtl/ldpc_top.sv ../rtl/ldpc_encoder.sv \
//     ../rtl/qam_mapper.sv ../rtl/fft_butterfly.sv ../rtl/twiddle_rom.sv \
//     ../rtl/fft_64pt.sv ../rtl/ifft_64pt.sv ../rtl/subcarrier_mux.sv \
//     ../rtl/cp_insertion.sv ../rtl/ofdm_tx_top.sv \
//     ../rtl/channel_fir_sparse.sv ../rtl/lfsr64.sv ../rtl/awgn_generator.sv \
//     ../rtl/channel_profile_rom.sv ../rtl/channel_model_top.sv \
//     ../rtl/cp_removal.sv ../rtl/subcarrier_demux.sv \
//     ../rtl/channel_estimator.sv ../rtl/data_align_buffer.sv \
//     ../rtl/reciprocal_lut.sv ../rtl/equalizer.sv ../rtl/soft_demapper.sv \
//     ../rtl/frame_controller.sv ../rtl/ofdm_rx_top.sv \
//     ../rtl/ofdm_loopback_top.sv \
//     tb_ofdm_loopback.sv
// =============================================================================

`timescale 1ns / 1ps

module tb_ofdm_loopback;

    // =========================================================================
    // Parameters
    // =========================================================================
    localparam integer FFT_N  = 64;
    localparam integer CP_LEN = 16;
    localparam integer W_IQ   = 16;
    localparam integer TW     = 12;
    localparam integer LLR_W  = 6;
    localparam integer Z      = 27;
    localparam integer MB     = 12;
    localparam integer NB     = 24;
    localparam integer K      = 324;   // info bits per frame (MB * Z)
    localparam integer N_CW   = 648;   // codeword bits (NB * Z)

    localparam real CLK_HALF  = 5.0;   // 100 MHz clock (10 ns period)

    localparam integer TIMEOUT_CYCLES = 2_000_000;

    // =========================================================================
    // DUT signals
    // =========================================================================
    logic        clk;
    logic        rst_n;

    logic        start;
    logic        info_bit_in;
    logic        info_bit_valid;

    logic [3:0]  cfg_modulation;
    logic [3:0]  profile_sel;
    logic        load_profile;
    logic [15:0] noise_scale;
    logic        noise_enable;
    logic        channel_bypass;
    logic        eq_mode;
    logic [1:0]  cfg_estimator;
    logic [15:0] noise_var;

    logic [63:0] awgn_seed_i;
    logic [63:0] awgn_seed_q;

    logic [31:0] ber_count;
    logic [31:0] frame_count;
    logic        test_done;

    // =========================================================================
    // DUT instantiation
    // =========================================================================
    ofdm_loopback_top #(
        .FFT_N  (FFT_N),
        .CP_LEN (CP_LEN),
        .W_IQ   (W_IQ),
        .TW     (TW),
        .LLR_W  (LLR_W),
        .Z      (Z),
        .MB     (MB),
        .NB     (NB),
        .K      (K),
        .N_CW   (N_CW)
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .start          (start),
        .info_bit_in    (info_bit_in),
        .info_bit_valid (info_bit_valid),
        .cfg_modulation (cfg_modulation),
        .profile_sel    (profile_sel),
        .load_profile   (load_profile),
        .noise_scale    (noise_scale),
        .noise_enable   (noise_enable),
        .channel_bypass (channel_bypass),
        .eq_mode        (eq_mode),
        .cfg_estimator  (cfg_estimator),
        .noise_var      (noise_var),
        .awgn_seed_i    (awgn_seed_i),
        .awgn_seed_q    (awgn_seed_q),
        .ber_count      (ber_count),
        .frame_count    (frame_count),
        .test_done      (test_done)
    );

    // =========================================================================
    // Clock generation
    // =========================================================================
    initial clk = 0;
    always #(CLK_HALF) clk = ~clk;

    // =========================================================================
    // Test vector storage
    // =========================================================================
    // Info bits loaded from hex file (1 bit per line, stored as 1-bit words)
    logic [0:0] info_bits_tv [0:K-1];

    initial begin
        $readmemh("../../test_vectors/ofdm/ofdm_info_bits_flat_noiseless.hex", info_bits_tv);
    end

    // =========================================================================
    // Test infrastructure (module-level for iverilog compatibility)
    // =========================================================================
    integer pass_count;
    integer fail_count;
    integer total_tests;
    integer cycle_cnt;
    integer i;

    // =========================================================================
    // Helper tasks
    // =========================================================================

    // Apply synchronous reset for a number of cycles
    task apply_reset(input integer num_cycles);
        rst_n <= 1'b0;
        repeat (num_cycles) @(posedge clk);
        rst_n <= 1'b1;
        repeat (5) @(posedge clk);
    endtask

    // Configure DUT for noiseless flat-channel QPSK test
    task configure_noiseless_flat;
        cfg_modulation <= 4'd0;        // QPSK
        channel_bypass <= 1'b1;        // bypass FIR channel
        noise_enable   <= 1'b0;        // no AWGN
        noise_scale    <= 16'h0000;    // zero noise
        eq_mode        <= 1'b0;        // ZF equalizer
        cfg_estimator  <= 2'd0;        // LS estimator
        noise_var      <= 16'h0000;    // zero noise variance
        profile_sel    <= 4'd0;        // irrelevant (bypass)
        load_profile   <= 1'b0;
        awgn_seed_i    <= 64'hDEAD_BEEF_CAFE_BABE;
        awgn_seed_q    <= 64'h1234_5678_9ABC_DEF0;
        repeat (2) @(posedge clk);
    endtask

    // Pulse start for one clock cycle, then feed K info bits serially
    task run_frame_with_bits(input logic bit_values [0:K-1]);
        // Pulse start for exactly one cycle
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;

        // Allow FSM to transition to LB_LOAD
        @(posedge clk);

        // Feed K info bits one per clock via info_bit_in / info_bit_valid
        for (i = 0; i < K; i = i + 1) begin
            info_bit_in    <= bit_values[i];
            info_bit_valid <= 1'b1;
            @(posedge clk);
        end
        info_bit_in    <= 1'b0;
        info_bit_valid <= 1'b0;
    endtask

    // Wait for test_done assertion with a cycle-count timeout
    task wait_for_test_done(input integer max_cycles, output integer elapsed);
        elapsed = 0;
        while (!test_done && elapsed < max_cycles) begin
            @(posedge clk);
            elapsed = elapsed + 1;
        end
    endtask

    // =========================================================================
    // Main test sequence
    // =========================================================================
    initial begin
        $dumpfile("tb_ofdm_loopback.vcd");
        $dumpvars(0, tb_ofdm_loopback);

        pass_count  = 0;
        fail_count  = 0;
        total_tests = 0;

        // Initialize all inputs
        rst_n          = 1'b0;
        start          = 1'b0;
        info_bit_in    = 1'b0;
        info_bit_valid = 1'b0;
        cfg_modulation = 4'd0;
        profile_sel    = 4'd0;
        load_profile   = 1'b0;
        noise_scale    = 16'd0;
        noise_enable   = 1'b0;
        channel_bypass = 1'b1;
        eq_mode        = 1'b0;
        cfg_estimator  = 2'd0;
        noise_var      = 16'd0;
        awgn_seed_i    = 64'd0;
        awgn_seed_q    = 64'd0;

        // =================================================================
        // TEST 1: Noiseless flat channel — random info bits, expect BER=0
        // =================================================================
        $display("");
        $display("=== TEST 1: Noiseless flat channel (test vector info bits) ===");
        $display("  Config: QPSK, channel_bypass=1, noise_enable=0, ZF, LS");
        $display("  Loading %0d info bits from ofdm_info_bits_flat_noiseless.hex", K);

        apply_reset(10);
        configure_noiseless_flat;

        $display("  Starting loopback frame...");
        run_frame_with_bits(info_bits_tv);

        $display("  Info bits loaded, waiting for test_done (timeout = %0d cycles)...", TIMEOUT_CYCLES);
        wait_for_test_done(TIMEOUT_CYCLES, cycle_cnt);

        if (test_done) begin
            $display("  Frame completed in %0d cycles", cycle_cnt);
            $display("    ber_count   = %0d", ber_count);
            $display("    frame_count = %0d", frame_count);

            // Try to report decoder iterations via hierarchical reference
            // (may not work on all simulators; wrapped in a display)
            $display("    dec_iterations = %0d (hierarchical ref)",
                     dut.dec_iterations);
            $display("    dec_converged  = %0b", dut.dec_converged);

            if (ber_count == 32'd0) begin
                $display("  TEST 1: PASS (BER = 0)");
                pass_count = pass_count + 1;
            end else begin
                $display("  TEST 1: FAIL (BER = %0d / %0d)", ber_count, K);
                fail_count = fail_count + 1;
            end
        end else begin
            $display("  TEST 1: FAIL (timeout after %0d cycles)", TIMEOUT_CYCLES);
            $display("    DUT FSM state = %0d", dut.lb_state);
            fail_count = fail_count + 1;
        end
        total_tests = total_tests + 1;

        // Wait between tests
        repeat (50) @(posedge clk);

        // =================================================================
        // TEST 2: All-zeros test — expect BER=0
        // =================================================================
        $display("");
        $display("=== TEST 2: Noiseless flat channel (all-zero info bits) ===");
        $display("  Config: QPSK, channel_bypass=1, noise_enable=0, ZF, LS");
        $display("  Feeding %0d zero bits", K);

        apply_reset(10);
        configure_noiseless_flat;

        // Prepare all-zero bit array (reuse info_bits_tv storage by zeroing)
        begin
            // Create a local zero-bit feed using the run_frame_with_bits task
            // We need a module-level array for iverilog, so overwrite info_bits_tv
            // temporarily, then restore. Alternatively, use a second storage.
            // For simplicity, just feed zeros inline.
            // Pulse start
            start <= 1'b1;
            @(posedge clk);
            start <= 1'b0;
            @(posedge clk);

            // Feed K zero bits
            for (i = 0; i < K; i = i + 1) begin
                info_bit_in    <= 1'b0;
                info_bit_valid <= 1'b1;
                @(posedge clk);
            end
            info_bit_in    <= 1'b0;
            info_bit_valid <= 1'b0;
        end

        $display("  Info bits loaded, waiting for test_done (timeout = %0d cycles)...", TIMEOUT_CYCLES);
        wait_for_test_done(TIMEOUT_CYCLES, cycle_cnt);

        if (test_done) begin
            $display("  Frame completed in %0d cycles", cycle_cnt);
            $display("    ber_count   = %0d", ber_count);
            $display("    frame_count = %0d", frame_count);
            $display("    dec_iterations = %0d (hierarchical ref)",
                     dut.dec_iterations);
            $display("    dec_converged  = %0b", dut.dec_converged);

            if (ber_count == 32'd0) begin
                $display("  TEST 2: PASS (BER = 0)");
                pass_count = pass_count + 1;
            end else begin
                $display("  TEST 2: FAIL (BER = %0d / %0d)", ber_count, K);
                fail_count = fail_count + 1;
            end
        end else begin
            $display("  TEST 2: FAIL (timeout after %0d cycles)", TIMEOUT_CYCLES);
            $display("    DUT FSM state = %0d", dut.lb_state);
            fail_count = fail_count + 1;
        end
        total_tests = total_tests + 1;

        // =================================================================
        // Summary
        // =================================================================
        $display("");
        $display("============================================");
        $display("  RESULTS: %0d PASS, %0d FAIL (of %0d tests)",
                 pass_count, fail_count, total_tests);
        if (fail_count == 0)
            $display("  PASS: All %0d ofdm_loopback tests passed.", total_tests);
        else
            $display("  FAIL: %0d / %0d ofdm_loopback tests failed.",
                     fail_count, total_tests);
        $display("============================================");

        $finish;
    end

    // =========================================================================
    // Timeout watchdog: 50 ms absolute wall-clock timeout
    // =========================================================================
    initial begin
        #50_000_000;
        $display("");
        $display("ERROR: Global timeout reached (50 ms)!");
        $display("  DUT FSM state = %0d", dut.lb_state);
        $display("  ber_count     = %0d", ber_count);
        $display("  frame_count   = %0d", frame_count);
        $display("FAIL: Simulation did not complete within time limit.");
        $finish;
    end

endmodule
