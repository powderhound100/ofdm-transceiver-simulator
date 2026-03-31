// =============================================================================
// soft_demapper.sv — Soft QAM to LLR Demapper
// =============================================================================
// Supports QPSK and 16QAM with max-log-MAP approximation.
//
// QPSK (2 bits/symbol):
//   LLR[0] = clamp(scale * Re(y))   — bit b0 mapped to I axis
//   LLR[1] = clamp(scale * Im(y))   — bit b1 mapped to Q axis
//   scale = 2/noise_var (simplified), externally set via noise_var
//
// 16QAM (4 bits/symbol):
//   Gray-mapped 16QAM constellation: ±1, ±3 on each axis (normalized by 1/sqrt(10))
//   Max-log-MAP piecewise linear approximation:
//   For I-axis bits (b0, b1):
//     LLR(b0) = -4 * Re(y) / noise_var    (sign determines 0 vs 1 partition)
//     LLR(b1) = -(2*|Re(y)| - 2) / noise_var  (distance to ±2 decision boundary)
//   Same for Q-axis bits (b2, b3) using Im(y).
//
// Output: Serial LLR stream, bps LLRs per input symbol.
// Saturated to [-31, +31] (6-bit signed).
// =============================================================================
`timescale 1ns / 1ps

module soft_demapper (
    input  wire        clk,
    input  wire        rst_n,

    // Equalized symbol input
    input  wire [31:0] eq_data,      // {Q[15:0], I[15:0]}
    input  wire        eq_valid,

    // Configuration
    input  wire [3:0]  cfg_modulation,  // 0=QPSK, 1=16QAM
    input  wire [15:0] noise_var,       // Q8.8 noise variance

    // LLR output (serial, one per clock)
    output reg  signed [5:0]  llr_out,
    output reg                llr_valid,
    output reg  [3:0]         llr_bit_idx,    // which bit of current symbol
    output reg                llr_last_bit    // last LLR of current symbol
);

    // =========================================================================
    // Input decomposition — Q1.14 format
    // =========================================================================
    wire signed [15:0] y_re = $signed(eq_data[15:0]);
    wire signed [15:0] y_im = $signed(eq_data[31:16]);

    // =========================================================================
    // Noise variance reciprocal (simplified)
    // =========================================================================
    // noise_var is Q8.8. For LLR scaling we need 1/noise_var.
    // We approximate: scale = 2^14 / noise_var (gives reasonable LLR range).
    // Precompute a simple shift-based approximation.
    // For now, use noise_var directly as divisor via shift.
    //
    // QPSK LLR ≈ 2 * y_re / noise_var
    // In fixed-point: llr = (y_re << 1) / (noise_var << 6) = y_re >> (something)
    //
    // Simplified approach: use noise_var[15:8] as integer part for shift.
    // When noise_var = 0x0100 (=1.0 in Q8.8), LLR = y_re >> 7 (maps Q1.14 to ~6-bit range)
    //
    // More precise: LLR = (y_re * scale_factor) >> shift
    // With noise_var in Q8.8, approximate reciprocal as:
    // 1/noise_var ≈ (256 / noise_var[15:0]) in Q8.8 → but this needs a divider.
    //
    // Practical approach: use a configurable scale shift.
    // For noise_var = 0x0100 (σ²=1): y_re is Q1.14, we want ~6-bit LLR.
    //   LLR ≈ y_re >> 8 (maps ±16384 → ±64, then saturate to ±31)
    // For noise_var = 0x0200 (σ²=2): LLR ≈ y_re >> 9
    // General: LLR ≈ y_re >> (7 + log2(noise_var_int))
    //
    // We use: LLR = (y_re <<< 1) / noise_var_int, where noise_var_int = noise_var >> 8
    // Implemented as: (y_re <<< 9) / noise_var  (Q1.14 <<< 9 = Q1.23; /Q8.8 = Q-7.15 → saturate)
    // Better: just do y_re * inv_noise and truncate.

    // =========================================================================
    // State machine: latch input, then emit bps LLRs serially
    // =========================================================================
    localparam S_IDLE    = 2'd0;
    localparam S_COMPUTE = 2'd1;
    localparam S_OUTPUT  = 2'd2;

    reg [1:0]          state;
    reg signed [15:0]  lat_re, lat_im;  // latched Re/Im
    reg [3:0]          bit_cnt;         // current bit being output
    reg [3:0]          bps;             // bits per symbol (2 for QPSK, 4 for 16QAM)

    // Precomputed LLR values for all bit positions (computed combinationally)
    reg signed [5:0] llr_vals [0:3];    // up to 4 LLRs per symbol

    // ---- LLR computation ----
    // noise_var in Q8.8. We want: llr = K * y / noise_var
    // For QPSK, K=2 (Euclidean distance scaling).
    // Compute: raw = (y <<< 1) — multiply by 2 — then divide by noise_var.
    //
    // Division approximation: raw * recip_nv >> shift
    // recip_nv = 256 * 256 / noise_var (if noise_var != 0)
    // This gives recip_nv in ~16-bit range.
    //
    // Simpler: (y >>> 8) gives ~8-bit value. Multiply by 2 for QPSK.
    // For σ²=1 (noise_var=0x100): LLR ≈ y >> 8, range ±64, saturate ±31. Good.
    //
    // Implementation: right-shift y_re by noise_shift where noise_shift
    // adapts based on noise_var magnitude.

    // Compute shift amount from noise_var: shift = log2(noise_var) - 1
    // noise_var Q8.8: value 0x0100 = 256 → shift=8-1=7? No, 256>>8=1.0
    // We want: floor(log2(noise_var))
    reg [3:0] noise_shift;
    always @(*) begin
        casez (noise_var)
            16'b1???????????????: noise_shift = 4'd15;
            16'b01??????????????: noise_shift = 4'd14;
            16'b001?????????????: noise_shift = 4'd13;
            16'b0001????????????: noise_shift = 4'd12;
            16'b00001???????????: noise_shift = 4'd11;
            16'b000001??????????: noise_shift = 4'd10;
            16'b0000001?????????: noise_shift = 4'd9;
            16'b00000001????????: noise_shift = 4'd8;
            16'b000000001???????: noise_shift = 4'd7;
            16'b0000000001??????: noise_shift = 4'd6;
            16'b00000000001?????: noise_shift = 4'd5;
            16'b000000000001????: noise_shift = 4'd4;
            16'b0000000000001???: noise_shift = 4'd3;
            16'b00000000000001??: noise_shift = 4'd2;
            16'b000000000000001?: noise_shift = 4'd1;
            default:              noise_shift = 4'd0;
        endcase
    end

    // Saturation function: clamp to [-31, +31]
    function signed [5:0] saturate_llr;
        input signed [15:0] val;
        begin
            if (val > 16'sd31)
                saturate_llr = 6'sd31;
            else if (val < -16'sd31)
                saturate_llr = -6'sd31;
            else
                saturate_llr = val[5:0];
        end
    endfunction

    // Raw LLR values (computed when symbol is latched)
    wire signed [15:0] scaled_re = lat_re >>> noise_shift;
    wire signed [15:0] scaled_im = lat_im >>> noise_shift;

    // For 16QAM: absolute values needed for bit 1,3 (inner/outer partition)
    wire signed [15:0] abs_re = lat_re[15] ? -lat_re : lat_re;
    wire signed [15:0] abs_im = lat_im[15] ? -lat_im : lat_im;

    // 16QAM decision threshold: normalized constellation at ±1, ±3 (scale = 1/sqrt(10))
    // With Q1.14 representation, the threshold between inner and outer is at 2/sqrt(10)*2^14 ≈ 10362
    // Simplified: threshold ≈ |y| - 2*d where d is the constellation spacing
    // For max-log-MAP: LLR(b1) ≈ -(|Re| - 2*d) * scale
    // d = 2/sqrt(10)*2^14 ≈ 10362.  2*d ≈ 20724.
    // Approximate 2*d as 2^14 + 2^12 = 20480 (close enough)
    localparam signed [15:0] THRESHOLD_16QAM = 16'sd10362;

    wire signed [15:0] inner_dist_re = abs_re - THRESHOLD_16QAM;
    wire signed [15:0] inner_dist_im = abs_im - THRESHOLD_16QAM;

    wire signed [15:0] scaled_inner_re = inner_dist_re >>> noise_shift;
    wire signed [15:0] scaled_inner_im = inner_dist_im >>> noise_shift;

    // =========================================================================
    // Main FSM
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            lat_re       <= 16'd0;
            lat_im       <= 16'd0;
            bit_cnt      <= 4'd0;
            bps          <= 4'd2;
            llr_out      <= 6'd0;
            llr_valid    <= 1'b0;
            llr_bit_idx  <= 4'd0;
            llr_last_bit <= 1'b0;
        end else begin
            llr_valid    <= 1'b0;
            llr_last_bit <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (eq_valid) begin
                        lat_re <= y_re;
                        lat_im <= y_im;
                        bit_cnt <= 4'd0;
                        bps <= (cfg_modulation == 4'd0) ? 4'd2 : 4'd4;
                        state <= S_OUTPUT;
                    end
                end

                S_OUTPUT: begin
                    llr_valid   <= 1'b1;
                    llr_bit_idx <= bit_cnt;

                    case (cfg_modulation)
                        4'd0: begin // QPSK
                            case (bit_cnt)
                                4'd0: llr_out <= saturate_llr(scaled_re);
                                4'd1: llr_out <= saturate_llr(scaled_im);
                                default: llr_out <= 6'd0;
                            endcase
                        end

                        4'd1: begin // 16QAM
                            case (bit_cnt)
                                4'd0: llr_out <= saturate_llr(scaled_re);         // MSB, I-axis sign
                                4'd1: llr_out <= saturate_llr(-scaled_inner_re);  // I-axis inner/outer
                                4'd2: llr_out <= saturate_llr(scaled_im);         // MSB, Q-axis sign
                                4'd3: llr_out <= saturate_llr(-scaled_inner_im);  // Q-axis inner/outer
                                default: llr_out <= 6'd0;
                            endcase
                        end

                        default: begin // Default to QPSK
                            case (bit_cnt)
                                4'd0: llr_out <= saturate_llr(scaled_re);
                                4'd1: llr_out <= saturate_llr(scaled_im);
                                default: llr_out <= 6'd0;
                            endcase
                        end
                    endcase

                    if (bit_cnt == bps - 4'd1) begin
                        llr_last_bit <= 1'b1;
                        state <= S_IDLE;
                    end else begin
                        bit_cnt <= bit_cnt + 4'd1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
