`timescale 1ns / 1ps
// =============================================================================
// cfo_corrector.sv — NCO + Complex Derotator for CFO Correction
// =============================================================================
// Numerically Controlled Oscillator generates exp(-j*phase) via
// cos/sin lookup, then complex multiply to correct carrier offset:
//   r_corrected[n] = r[n] * exp(-j * 2*pi * cfo * n)
//
// Phase accumulator: phase[n] = phase[n-1] + phase_inc
// where phase_inc = cfo_est (Q1.14 fractional CFO)
// =============================================================================

module cfo_corrector #(
    parameter int IQ_W    = 16,
    parameter int PHASE_W = 16  // Phase accumulator width
)(
    input  logic                    clk,
    input  logic                    rst_n,

    // CFO estimate input (load once per frame)
    input  logic signed [15:0]      cfo_est,    // Q1.14
    input  logic                    cfo_load,   // Pulse to load new CFO

    // Input IQ samples
    input  logic signed [IQ_W-1:0] s_re,
    input  logic signed [IQ_W-1:0] s_im,
    input  logic                    s_valid,

    // Corrected output
    output logic signed [IQ_W-1:0] m_re,
    output logic signed [IQ_W-1:0] m_im,
    output logic                    m_valid
);

    // Phase accumulator
    logic signed [PHASE_W-1:0] phase_acc;
    logic signed [15:0]        phase_inc;

    // NCO cos/sin outputs (Q1.14)
    logic signed [IQ_W-1:0] nco_cos, nco_sin;

    // Phase accumulation
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase_acc <= 0;
            phase_inc <= 0;
        end else begin
            if (cfo_load) begin
                phase_inc <= cfo_est;
                phase_acc <= 0;
            end else if (s_valid) begin
                phase_acc <= phase_acc + phase_inc;
            end
        end
    end

    // Cos/Sin lookup (simplified: use upper bits of phase as index)
    // Full circle = 2^PHASE_W steps, use upper 6 bits for 64-entry table
    logic [5:0] phase_idx;
    assign phase_idx = phase_acc[PHASE_W-1:PHASE_W-6];

    // Cos/Sin ROM (64 entries, Q1.14)
    // cos(2*pi*k/64) and -sin(2*pi*k/64) for k=0..63
    // (negative sin because we want exp(-j*phase))
    always_comb begin
        case (phase_idx)
            6'd0:  begin nco_cos = 16384;  nco_sin = 0;      end
            6'd1:  begin nco_cos = 16305;  nco_sin = -1608;  end
            6'd2:  begin nco_cos = 16069;  nco_sin = -3196;  end
            6'd3:  begin nco_cos = 15679;  nco_sin = -4756;  end
            6'd4:  begin nco_cos = 15137;  nco_sin = -6270;  end
            6'd5:  begin nco_cos = 14449;  nco_sin = -7723;  end
            6'd6:  begin nco_cos = 13623;  nco_sin = -9102;  end
            6'd7:  begin nco_cos = 12665;  nco_sin = -10394; end
            6'd8:  begin nco_cos = 11585;  nco_sin = -11585; end
            6'd9:  begin nco_cos = 10394;  nco_sin = -12665; end
            6'd10: begin nco_cos = 9102;   nco_sin = -13623; end
            6'd11: begin nco_cos = 7723;   nco_sin = -14449; end
            6'd12: begin nco_cos = 6270;   nco_sin = -15137; end
            6'd13: begin nco_cos = 4756;   nco_sin = -15679; end
            6'd14: begin nco_cos = 3196;   nco_sin = -16069; end
            6'd15: begin nco_cos = 1608;   nco_sin = -16305; end
            6'd16: begin nco_cos = 0;      nco_sin = -16384; end
            6'd17: begin nco_cos = -1608;  nco_sin = -16305; end
            6'd18: begin nco_cos = -3196;  nco_sin = -16069; end
            6'd19: begin nco_cos = -4756;  nco_sin = -15679; end
            6'd20: begin nco_cos = -6270;  nco_sin = -15137; end
            6'd21: begin nco_cos = -7723;  nco_sin = -14449; end
            6'd22: begin nco_cos = -9102;  nco_sin = -13623; end
            6'd23: begin nco_cos = -10394; nco_sin = -12665; end
            6'd24: begin nco_cos = -11585; nco_sin = -11585; end
            6'd25: begin nco_cos = -12665; nco_sin = -10394; end
            6'd26: begin nco_cos = -13623; nco_sin = -9102;  end
            6'd27: begin nco_cos = -14449; nco_sin = -7723;  end
            6'd28: begin nco_cos = -15137; nco_sin = -6270;  end
            6'd29: begin nco_cos = -15679; nco_sin = -4756;  end
            6'd30: begin nco_cos = -16069; nco_sin = -3196;  end
            6'd31: begin nco_cos = -16305; nco_sin = -1608;  end
            6'd32: begin nco_cos = -16384; nco_sin = 0;      end
            6'd33: begin nco_cos = -16305; nco_sin = 1608;   end
            6'd34: begin nco_cos = -16069; nco_sin = 3196;   end
            6'd35: begin nco_cos = -15679; nco_sin = 4756;   end
            6'd36: begin nco_cos = -15137; nco_sin = 6270;   end
            6'd37: begin nco_cos = -14449; nco_sin = 7723;   end
            6'd38: begin nco_cos = -13623; nco_sin = 9102;   end
            6'd39: begin nco_cos = -12665; nco_sin = 10394;  end
            6'd40: begin nco_cos = -11585; nco_sin = 11585;  end
            6'd41: begin nco_cos = -10394; nco_sin = 12665;  end
            6'd42: begin nco_cos = -9102;  nco_sin = 13623;  end
            6'd43: begin nco_cos = -7723;  nco_sin = 14449;  end
            6'd44: begin nco_cos = -6270;  nco_sin = 15137;  end
            6'd45: begin nco_cos = -4756;  nco_sin = 15679;  end
            6'd46: begin nco_cos = -3196;  nco_sin = 16069;  end
            6'd47: begin nco_cos = -1608;  nco_sin = 16305;  end
            6'd48: begin nco_cos = 0;      nco_sin = 16384;  end
            6'd49: begin nco_cos = 1608;   nco_sin = 16305;  end
            6'd50: begin nco_cos = 3196;   nco_sin = 16069;  end
            6'd51: begin nco_cos = 4756;   nco_sin = 15679;  end
            6'd52: begin nco_cos = 6270;   nco_sin = 15137;  end
            6'd53: begin nco_cos = 7723;   nco_sin = 14449;  end
            6'd54: begin nco_cos = 9102;   nco_sin = 13623;  end
            6'd55: begin nco_cos = 10394;  nco_sin = 12665;  end
            6'd56: begin nco_cos = 11585;  nco_sin = 11585;  end
            6'd57: begin nco_cos = 12665;  nco_sin = 10394;  end
            6'd58: begin nco_cos = 13623;  nco_sin = 9102;   end
            6'd59: begin nco_cos = 14449;  nco_sin = 7723;   end
            6'd60: begin nco_cos = 15137;  nco_sin = 6270;   end
            6'd61: begin nco_cos = 15679;  nco_sin = 4756;   end
            6'd62: begin nco_cos = 16069;  nco_sin = 3196;   end
            6'd63: begin nco_cos = 16305;  nco_sin = 1608;   end
        endcase
    end

    // Complex multiply: out = input * exp(-j*phase)
    // out_re = s_re * cos + s_im * sin  (sin is already negated)
    // out_im = s_im * cos - s_re * sin
    // Actually: exp(-j*t) = cos(t) - j*sin(t)
    // (a+jb)(cos-jsin) = (a*cos + b*sin) + j(b*cos - a*sin)
    logic signed [2*IQ_W-1:0] mult_re, mult_im;
    logic p1_valid_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mult_re    <= 0;
            mult_im    <= 0;
            p1_valid_r <= 0;
        end else begin
            p1_valid_r <= s_valid;
            if (s_valid) begin
                // nco_sin already stores -sin, so:
                // out_re = s_re * nco_cos - s_im * nco_sin (which is s_re*cos + s_im*sin)
                // out_im = s_im * nco_cos + s_re * nco_sin (which is s_im*cos - s_re*sin)
                mult_re <= s_re * nco_cos - s_im * nco_sin;
                mult_im <= s_im * nco_cos + s_re * nco_sin;
            end
        end
    end

    // Output with truncation (Q1.14 * Q1.14 = Q2.28, >> 14 = Q2.14, saturate to Q1.14)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_re    <= 0;
            m_im    <= 0;
            m_valid <= 0;
        end else begin
            m_valid <= p1_valid_r;
            if (p1_valid_r) begin
                // Truncate with saturation
                logic signed [IQ_W+1:0] trunc_re, trunc_im;
                trunc_re = mult_re >>> 14;
                trunc_im = mult_im >>> 14;

                // Saturate
                if (trunc_re > 16383)       m_re <= 16383;
                else if (trunc_re < -16383) m_re <= -16383;
                else                        m_re <= trunc_re[IQ_W-1:0];

                if (trunc_im > 16383)       m_im <= 16383;
                else if (trunc_im < -16383) m_im <= -16383;
                else                        m_im <= trunc_im[IQ_W-1:0];
            end
        end
    end

endmodule
