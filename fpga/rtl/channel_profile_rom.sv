// =============================================================================
// channel_profile_rom.sv — Channel model profile storage ROM
// =============================================================================
// Stores 10 predefined multipath channel profiles with up to 8 taps each.
// Each tap entry contains: delay_index[7:0], coeff_re[15:0], coeff_im[15:0].
// Coefficients are Q1.14 fixed-point (1 sign, 1 integer, 14 fractional bits).
// Energy-normalized: sum(|coeff|^2) = 1.0 per profile.
//
// Profiles:
//   0: flat          — single tap, unity gain
//   1: two_tap       — 2-tap with 3 dB spacing
//   2: tu6           — 6-tap Typical Urban (COST 207 variant)
//   3: cost207_ra    — 4-tap COST 207 Rural Area
//   4: cost207_ht    — 6-tap COST 207 Hilly Terrain
//   5: brazil_a      — 3-tap Brazil channel model A
//   6: brazil_b      — 5-tap Brazil channel model B
//   7: brazil_c      — 6-tap Brazil channel model C
//   8: brazil_d      — 6-tap Brazil channel model D
//   9: brazil_e      — 6-tap Brazil channel model E
//
// Operation: Assert load_en for one cycle. The ROM outputs taps sequentially,
// one per clock, with tap_valid high. load_done pulses when all taps are sent.
//
// Coefficient derivation:
//   amplitude = 10^(power_dB / 20)
//   Normalize: coeff = amplitude / sqrt(sum(amplitude^2))
//   Q1.14: round(coeff * 2^14) stored as 16-bit signed
//   All profiles have real-only coefficients (coeff_im = 0).
// =============================================================================

`timescale 1ns / 1ps

module channel_profile_rom (
    input  logic        clk,
    input  logic [3:0]  profile_sel,    // 0-9
    input  logic        load_en,        // start loading

    output logic [2:0]  num_taps,       // number of active taps for selected profile
    output logic [7:0]  tap_delay,      // delay index for current tap
    output logic signed [15:0] tap_re,  // Q1.14 real coefficient
    output logic signed [15:0] tap_im,  // Q1.14 imaginary coefficient
    output logic [2:0]  tap_idx,        // current tap being output (0-based)
    output logic        tap_valid,      // tap data valid this cycle
    output logic        load_done       // all taps have been output
);

    // -------------------------------------------------------------------------
    // Profile storage: 10 profiles x 8 taps max
    // Packed as: {delay[7:0], coeff_re[15:0], coeff_im[15:0]} = 40 bits
    // -------------------------------------------------------------------------
    localparam int NUM_PROFILES = 10;
    localparam int MAX_TAPS     = 8;

    // Storage arrays — initialized in an always_comb block to avoid
    // iverilog issues with array literals
    logic [2:0]  profile_num_taps [0:NUM_PROFILES-1];
    logic [7:0]  profile_delay    [0:NUM_PROFILES-1][0:MAX_TAPS-1];
    logic signed [15:0] profile_re [0:NUM_PROFILES-1][0:MAX_TAPS-1];
    logic signed [15:0] profile_im [0:NUM_PROFILES-1][0:MAX_TAPS-1];

    // -------------------------------------------------------------------------
    // ROM initialization — combinational lookup
    // -------------------------------------------------------------------------
    // All coefficients are real-only (im = 0) since these are deterministic
    // power-delay profiles without random phase components.
    //
    // Q1.14 values computed from:
    //   amplitude_linear = 10^(power_dB / 20)
    //   coeff = amplitude_linear / sqrt(sum(amplitude_linear^2))
    //   q114_value = round(coeff * 16384)
    // -------------------------------------------------------------------------
    integer p, t;
    always_comb begin
        // Default: zero everything
        for (p = 0; p < NUM_PROFILES; p = p + 1) begin
            profile_num_taps[p] = 3'd0;
            for (t = 0; t < MAX_TAPS; t = t + 1) begin
                profile_delay[p][t] = 8'd0;
                profile_re[p][t]    = 16'sd0;
                profile_im[p][t]    = 16'sd0;
            end
        end

        // -----------------------------------------------------------------
        // Profile 0: flat — 1 tap
        // delays=[0], powers_db=[0.0]
        // -----------------------------------------------------------------
        profile_num_taps[0] = 3'd1;
        profile_delay[0][0] = 8'd0;   profile_re[0][0] = 16'sd16384;  // 1.0000

        // -----------------------------------------------------------------
        // Profile 1: two_tap — 2 taps
        // delays=[0,5], powers_db=[0.0, -3.0]
        // -----------------------------------------------------------------
        profile_num_taps[1] = 3'd2;
        profile_delay[1][0] = 8'd0;   profile_re[1][0] = 16'sd13372;  // 0.8162
        profile_delay[1][1] = 8'd5;   profile_re[1][1] = 16'sd9467;   // 0.5778

        // -----------------------------------------------------------------
        // Profile 2: tu6 — 6 taps (Typical Urban)
        // delays=[0,1,3,5,8,12], powers_db=[-3,0,-2,-6,-8,-10]
        // -----------------------------------------------------------------
        profile_num_taps[2] = 3'd6;
        profile_delay[2][0] = 8'd0;   profile_re[2][0] = 16'sd7136;   // 0.4356
        profile_delay[2][1] = 8'd1;   profile_re[2][1] = 16'sd10080;  // 0.6152
        profile_delay[2][2] = 8'd3;   profile_re[2][2] = 16'sd8007;   // 0.4887
        profile_delay[2][3] = 8'd5;   profile_re[2][3] = 16'sd5052;   // 0.3084
        profile_delay[2][4] = 8'd8;   profile_re[2][4] = 16'sd4013;   // 0.2449
        profile_delay[2][5] = 8'd12;  profile_re[2][5] = 16'sd3188;   // 0.1946

        // -----------------------------------------------------------------
        // Profile 3: cost207_ra — 4 taps (Rural Area)
        // delays=[0,1,2,3], powers_db=[0,-2,-10,-20]
        // -----------------------------------------------------------------
        profile_num_taps[3] = 3'd4;
        profile_delay[3][0] = 8'd0;   profile_re[3][0] = 16'sd12417;  // 0.7579
        profile_delay[3][1] = 8'd1;   profile_re[3][1] = 16'sd9863;   // 0.6020
        profile_delay[3][2] = 8'd2;   profile_re[3][2] = 16'sd3927;   // 0.2397
        profile_delay[3][3] = 8'd3;   profile_re[3][3] = 16'sd1242;   // 0.0758

        // -----------------------------------------------------------------
        // Profile 4: cost207_ht — 6 taps (Hilly Terrain)
        // delays=[0,2,4,7,11,17], powers_db=[0,-2,-4,-7,-6,-12]
        // -----------------------------------------------------------------
        profile_num_taps[4] = 3'd6;
        profile_delay[4][0] = 8'd0;   profile_re[4][0] = 16'sd10274;  // 0.6271
        profile_delay[4][1] = 8'd2;   profile_re[4][1] = 16'sd8161;   // 0.4981
        profile_delay[4][2] = 8'd4;   profile_re[4][2] = 16'sd6483;   // 0.3957
        profile_delay[4][3] = 8'd7;   profile_re[4][3] = 16'sd4589;   // 0.2801
        profile_delay[4][4] = 8'd11;  profile_re[4][4] = 16'sd5149;   // 0.3143
        profile_delay[4][5] = 8'd17;  profile_re[4][5] = 16'sd2581;   // 0.1575

        // -----------------------------------------------------------------
        // Profile 5: brazil_a — 3 taps
        // delays=[0,3,13], powers_db=[0,-15,-20]
        // -----------------------------------------------------------------
        profile_num_taps[5] = 3'd3;
        profile_delay[5][0] = 8'd0;   profile_re[5][0] = 16'sd16053;  // 0.9798
        profile_delay[5][1] = 8'd3;   profile_re[5][1] = 16'sd2855;   // 0.1742
        profile_delay[5][2] = 8'd13;  profile_re[5][2] = 16'sd1605;   // 0.0980

        // -----------------------------------------------------------------
        // Profile 6: brazil_b — 5 taps
        // delays=[0,1,3,11,57], powers_db=[0,-12,-4,-7,-15]
        // -----------------------------------------------------------------
        profile_num_taps[6] = 3'd5;
        profile_delay[6][0] = 8'd0;   profile_re[6][0] = 16'sd12594;  // 0.7687
        profile_delay[6][1] = 8'd1;   profile_re[6][1] = 16'sd3164;   // 0.1931
        profile_delay[6][2] = 8'd3;   profile_re[6][2] = 16'sd7946;   // 0.4850
        profile_delay[6][3] = 8'd11;  profile_re[6][3] = 16'sd5626;   // 0.3434
        profile_delay[6][4] = 8'd57;  profile_re[6][4] = 16'sd2240;   // 0.1367

        // -----------------------------------------------------------------
        // Profile 7: brazil_c — 6 taps
        // delays=[0,1,2,5,11,17], powers_db=[0,-5,-2,-6,-8,-10]
        // -----------------------------------------------------------------
        profile_num_taps[7] = 3'd6;
        profile_delay[7][0] = 8'd0;   profile_re[7][0] = 16'sd10453;  // 0.6380
        profile_delay[7][1] = 8'd1;   profile_re[7][1] = 16'sd5878;   // 0.3588
        profile_delay[7][2] = 8'd2;   profile_re[7][2] = 16'sd8303;   // 0.5068
        profile_delay[7][3] = 8'd5;   profile_re[7][3] = 16'sd5239;   // 0.3198
        profile_delay[7][4] = 8'd11;  profile_re[7][4] = 16'sd4161;   // 0.2540
        profile_delay[7][5] = 8'd17;  profile_re[7][5] = 16'sd3305;   // 0.2017

        // -----------------------------------------------------------------
        // Profile 8: brazil_d — 6 taps
        // delays=[0,3,5,13,50,120], powers_db=[0,-10,-3,-4,-7,-15]
        // -----------------------------------------------------------------
        profile_num_taps[8] = 3'd6;
        profile_delay[8][0] = 8'd0;   profile_re[8][0] = 16'sd10970;  // 0.6696
        profile_delay[8][1] = 8'd3;   profile_re[8][1] = 16'sd3469;   // 0.2117
        profile_delay[8][2] = 8'd5;   profile_re[8][2] = 16'sd7766;   // 0.4740
        profile_delay[8][3] = 8'd13;  profile_re[8][3] = 16'sd6922;   // 0.4225
        profile_delay[8][4] = 8'd50;  profile_re[8][4] = 16'sd4900;   // 0.2991
        profile_delay[8][5] = 8'd120; profile_re[8][5] = 16'sd1951;   // 0.1191

        // -----------------------------------------------------------------
        // Profile 9: brazil_e — 6 taps
        // delays=[0,1,3,10,25,138], powers_db=[0,-5,-2,-6,-8,-10]
        // -----------------------------------------------------------------
        profile_num_taps[9] = 3'd6;
        profile_delay[9][0] = 8'd0;   profile_re[9][0] = 16'sd10453;  // 0.6380
        profile_delay[9][1] = 8'd1;   profile_re[9][1] = 16'sd5878;   // 0.3588
        profile_delay[9][2] = 8'd3;   profile_re[9][2] = 16'sd8303;   // 0.5068
        profile_delay[9][3] = 8'd10;  profile_re[9][3] = 16'sd5239;   // 0.3198
        profile_delay[9][4] = 8'd25;  profile_re[9][4] = 16'sd4161;   // 0.2540
        profile_delay[9][5] = 8'd138; profile_re[9][5] = 16'sd3305;   // 0.2017
    end

    // -------------------------------------------------------------------------
    // Profile loading FSM
    // -------------------------------------------------------------------------
    // When load_en is pulsed, outputs taps one per clock for the selected
    // profile. tap_valid is high for each valid tap. load_done pulses when
    // the last tap has been output.
    // -------------------------------------------------------------------------
    localparam [1:0] LD_IDLE   = 2'd0;
    localparam [1:0] LD_LOAD   = 2'd1;
    localparam [1:0] LD_DONE   = 2'd2;

    logic [1:0] ld_state;
    logic [3:0] ld_profile;     // latched profile selection
    logic [2:0] ld_tap_cnt;     // current tap counter
    logic [2:0] ld_num_taps;    // number of taps for selected profile

    // Note: no rst_n port — ROM is purely combinational; FSM resets to IDLE
    // via default assignment and power-on value.
    logic rst_n_placeholder;  // unused, avoids lint warnings on missing reset
    initial begin
        ld_state   = LD_IDLE;
        ld_profile = 4'd0;
        ld_tap_cnt = 3'd0;
        ld_num_taps = 3'd0;
        tap_valid  = 1'b0;
        load_done  = 1'b0;
        tap_delay  = 8'd0;
        tap_re     = 16'sd0;
        tap_im     = 16'sd0;
        tap_idx    = 3'd0;
        num_taps   = 3'd0;
    end

    always_ff @(posedge clk) begin
        // Default outputs
        tap_valid <= 1'b0;
        load_done <= 1'b0;

        case (ld_state)
            LD_IDLE: begin
                if (load_en) begin
                    ld_profile  <= profile_sel;
                    ld_tap_cnt  <= 3'd0;
                    ld_num_taps <= profile_num_taps[profile_sel];
                    ld_state    <= LD_LOAD;
                end
            end

            LD_LOAD: begin
                // Output current tap
                tap_delay <= profile_delay[ld_profile][ld_tap_cnt];
                tap_re    <= profile_re[ld_profile][ld_tap_cnt];
                tap_im    <= profile_im[ld_profile][ld_tap_cnt];
                tap_idx   <= ld_tap_cnt;
                tap_valid <= 1'b1;
                num_taps  <= ld_num_taps;

                if (ld_tap_cnt == ld_num_taps - 3'd1) begin
                    ld_state <= LD_DONE;
                end else begin
                    ld_tap_cnt <= ld_tap_cnt + 3'd1;
                end
            end

            LD_DONE: begin
                load_done <= 1'b1;
                ld_state  <= LD_IDLE;
            end

            default: ld_state <= LD_IDLE;
        endcase
    end

endmodule
