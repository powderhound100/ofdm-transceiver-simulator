// =============================================================================
// channel_estimator.sv — LS-Improved Channel Estimator (Re/Im Interpolation)
// =============================================================================
// Performs channel estimation using LS at pilot positions followed by
// linear interpolation of Re and Im components separately.
//
// Pilot positions in the 52 used-carrier space (bins 6..57):
//   Pilot bins: 6, 18, 30, 42  → positions 0, 12, 24, 36 within [6..57]
//
// Since TX_PILOT = 1+j0, H_pilot = RX_pilot (LS estimate).
//
// Interpolation segments:
//   Segment 0: positions 1..11  (between pilot[0] @ pos 0 and pilot[1] @ pos 12)
//   Segment 1: positions 13..23 (between pilot[1] @ pos 12 and pilot[2] @ pos 24)
//   Segment 2: positions 25..35 (between pilot[2] @ pos 24 and pilot[3] @ pos 36)
//
// For data carriers before first pilot (none in this mapping) or after last
// pilot (positions 37..51): extrapolate using nearest segment slope.
//
// Data carriers within used range excluding pilots = 48 carriers.
// Output: 48 channel estimates per symbol, streamed.
//
// cfg_estimator: 0=LS (reserved), 1=LS-Improved (Re/Im interp), 2=LMMSE (reserved)
// =============================================================================
`timescale 1ns / 1ps

module channel_estimator (
    input  wire        clk,
    input  wire        rst_n,

    // Pilot input (4 per OFDM symbol)
    input  wire [31:0] pilot_data,   // {Q[15:0], I[15:0]}
    input  wire        pilot_valid,
    input  wire        pilot_last,   // asserted on 4th pilot

    // Channel estimate output (48 per symbol)
    output reg  [31:0] h_est_data,   // {Q[15:0], I[15:0]}
    output reg         h_est_valid,
    output reg         h_est_last,   // last estimate of symbol

    // Configuration
    input  wire [1:0]  cfg_estimator // 1 = LS-Improved (only mode implemented)
);

    // =========================================================================
    // Pilot storage — collect 4 pilots per symbol
    // =========================================================================
    reg signed [15:0] pilot_re [0:3];
    reg signed [15:0] pilot_im [0:3];
    reg [1:0]         pilot_idx;
    reg               pilots_ready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pilot_idx    <= 2'd0;
            pilots_ready <= 1'b0;
        end else begin
            pilots_ready <= 1'b0;
            if (pilot_valid) begin
                pilot_re[pilot_idx] <= $signed(pilot_data[15:0]);
                pilot_im[pilot_idx] <= $signed(pilot_data[31:16]);
                if (pilot_last) begin
                    pilot_idx    <= 2'd0;
                    pilots_ready <= 1'b1;
                end else begin
                    pilot_idx <= pilot_idx + 2'd1;
                end
            end
        end
    end

    // =========================================================================
    // Interpolation FSM
    // =========================================================================
    // Used-carrier positions (0..51 mapping bins 6..57):
    //   Pilots at positions: 0, 12, 24, 36
    //   Data at all other positions in 0..51 (48 total)
    //
    // We iterate through positions 0..51, outputting H_est for non-pilot positions.
    // For positions that ARE pilots, we skip them (the data demux doesn't send
    // pilot bins on the data path).
    //
    // Linear interpolation between adjacent pilots:
    //   For position p between pilot_a (at pos_a) and pilot_b (at pos_b):
    //   H_re(p) = pilot_a_re + (pilot_b_re - pilot_a_re) * (p - pos_a) / (pos_b - pos_a)
    //   H_im(p) = pilot_a_im + (pilot_b_im - pilot_a_im) * (p - pos_a) / (pos_b - pos_a)
    //
    // Inter-pilot spacing = 12, so division by 12.
    // We precompute delta/12 using multiply by reciprocal: * 5461 >> 16 ≈ /12
    //
    // For extrapolation beyond last pilot (positions 37..51):
    //   Use slope from segment 2 (pilots 2→3).

    localparam IDLE    = 2'd0;
    localparam INTERP  = 2'd1;
    localparam DONE    = 2'd2;

    reg [1:0]  state;
    reg [5:0]  pos;        // current position in used-carrier space (0..51)
    reg [5:0]  data_idx;   // counts data outputs (0..47)

    // Determine which segment we're in and the interpolation fraction
    // Segment boundaries: [0,12), [12,24), [24,36), [36,51]
    // pilot_left index: 0 for [0..11], 1 for [12..23], 2 for [24..35], 3 for [36..51]
    reg [1:0]  seg;
    reg [3:0]  frac;       // fractional position within segment (0..11 normally, 0..15 for extrap)

    wire is_pilot_pos = (pos == 6'd0) || (pos == 6'd12) || (pos == 6'd24) || (pos == 6'd36);

    // Interpolation arithmetic
    // delta = pilot[seg+1] - pilot[seg] (or pilot[3] - pilot[2] for extrapolation)
    reg signed [15:0] left_re, left_im;
    reg signed [16:0] delta_re, delta_im;  // 17-bit for difference

    // Interpolated value = left + delta * frac / 12
    // We compute: left + (delta * frac * 5461) >>> 16
    // But simpler: (delta * frac) / 12 directly with multiply+shift
    // Use: result = left + ((delta * frac) * 2731) >>> 15  (2731/32768 ≈ 1/12)
    // Better: just do the divide with multiply by reciprocal.
    // 1/12 ≈ 2731/32768 = 0.0833... (error < 0.01%)

    reg signed [31:0] scaled_re, scaled_im;  // delta * frac
    wire signed [31:0] interp_re_w;
    wire signed [31:0] interp_im_w;

    // (delta * frac) is at most 17-bit * 4-bit = 21 bits
    // Multiply by 2731 (12 bits) → 33 bits, then >> 15
    wire signed [31:0] numer_re = scaled_re * $signed(16'sd2731);
    wire signed [31:0] numer_im = scaled_im * $signed(16'sd2731);

    // Shift right by 15 with rounding
    wire signed [15:0] step_re = (numer_re + 32'sd16384) >>> 15;
    wire signed [15:0] step_im = (numer_im + 32'sd16384) >>> 15;

    assign interp_re_w = $signed({16'd0, left_re}) + $signed({{16{step_re[15]}}, step_re});
    assign interp_im_w = $signed({16'd0, left_im}) + $signed({{16{step_im[15]}}, step_im});

    wire signed [15:0] h_re_out = left_re + step_re;
    wire signed [15:0] h_im_out = left_im + step_im;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= IDLE;
            pos        <= 6'd0;
            data_idx   <= 6'd0;
            h_est_data <= 32'd0;
            h_est_valid <= 1'b0;
            h_est_last <= 1'b0;
            seg        <= 2'd0;
            frac       <= 4'd0;
            left_re    <= 16'd0;
            left_im    <= 16'd0;
            delta_re   <= 17'd0;
            delta_im   <= 17'd0;
            scaled_re  <= 32'd0;
            scaled_im  <= 32'd0;
        end else begin
            h_est_valid <= 1'b0;
            h_est_last  <= 1'b0;

            case (state)
                IDLE: begin
                    if (pilots_ready) begin
                        state    <= INTERP;
                        pos      <= 6'd0;
                        data_idx <= 6'd0;
                    end
                end

                INTERP: begin
                    // Determine segment and fraction for current position
                    if (pos <= 6'd11) begin
                        seg  <= 2'd0;
                        frac <= pos[3:0];
                        left_re <= pilot_re[0];
                        left_im <= pilot_im[0];
                        delta_re <= $signed({pilot_re[1][15], pilot_re[1]}) - $signed({pilot_re[0][15], pilot_re[0]});
                        delta_im <= $signed({pilot_im[1][15], pilot_im[1]}) - $signed({pilot_im[0][15], pilot_im[0]});
                    end else if (pos <= 6'd23) begin
                        seg  <= 2'd1;
                        frac <= pos[3:0] - 4'd12;
                        left_re <= pilot_re[1];
                        left_im <= pilot_im[1];
                        delta_re <= $signed({pilot_re[2][15], pilot_re[2]}) - $signed({pilot_re[1][15], pilot_re[1]});
                        delta_im <= $signed({pilot_im[2][15], pilot_im[2]}) - $signed({pilot_im[1][15], pilot_im[1]});
                    end else if (pos <= 6'd35) begin
                        seg  <= 2'd2;
                        frac <= pos[3:0] - 4'd8;  // pos-24, pos[3:0] wraps: 24→8,25→9,...,35→3
                        left_re <= pilot_re[2];
                        left_im <= pilot_im[2];
                        delta_re <= $signed({pilot_re[3][15], pilot_re[3]}) - $signed({pilot_re[2][15], pilot_re[2]});
                        delta_im <= $signed({pilot_im[3][15], pilot_im[3]}) - $signed({pilot_im[2][15], pilot_im[2]});
                    end else begin
                        // Extrapolation: use slope from segment 2, extend beyond pilot[3]
                        seg  <= 2'd3;
                        frac <= pos[3:0] - 4'd4;  // pos-36
                        left_re <= pilot_re[3];
                        left_im <= pilot_im[3];
                        delta_re <= $signed({pilot_re[3][15], pilot_re[3]}) - $signed({pilot_re[2][15], pilot_re[2]});
                        delta_im <= $signed({pilot_im[3][15], pilot_im[3]}) - $signed({pilot_im[2][15], pilot_im[2]});
                    end

                    // Compute scaled product (will be used next cycle)
                    scaled_re <= delta_re * $signed({1'b0, frac});
                    scaled_im <= delta_im * $signed({1'b0, frac});

                    // Skip pilot positions (they don't appear on data path)
                    if (is_pilot_pos) begin
                        // Don't output anything, just advance position
                        if (pos == 6'd51) begin
                            state <= IDLE;
                        end else begin
                            pos <= pos + 6'd1;
                        end
                    end else begin
                        // Output interpolated channel estimate
                        h_est_data  <= {h_im_out, h_re_out};
                        h_est_valid <= 1'b1;
                        data_idx    <= data_idx + 6'd1;

                        if (data_idx == 6'd47) begin
                            h_est_last <= 1'b1;
                            state      <= IDLE;
                        end else begin
                            pos <= pos + 6'd1;
                        end
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
