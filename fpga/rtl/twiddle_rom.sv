// =============================================================================
// twiddle_rom.sv — FFT Twiddle Factor ROM for N=64
// =============================================================================
// Stores W_N^k = exp(-j*2*pi*k/N) for k = 0..N/2-1 (32 entries).
// Format: Q1.(TW-2) signed, where TW=12 by default.
//
// Scale factor = 2^(TW-2) = 2^10 = 1024.
// tw_re[k] = round(cos(2*pi*k/64) * 1024)
// tw_im[k] = round(-sin(2*pi*k/64) * 1024)
//
// Combinational read with optional registered output.
// =============================================================================
`timescale 1ns / 1ps

module twiddle_rom #(
    parameter integer FFT_N = 64,
    parameter integer TW    = 12
)(
    input  wire              clk,
    input  wire [4:0]        addr,     // k = 0..31
    output reg  signed [TW-1:0] tw_re,
    output reg  signed [TW-1:0] tw_im
);

    // =========================================================================
    // Precomputed twiddle factors for N=64, TW=12
    // =========================================================================
    // Scale = 2^(TW-2) = 1024
    // W_64^k = cos(2*pi*k/64) - j*sin(2*pi*k/64)
    // tw_re = round(cos(2*pi*k/64) * 1024)
    // tw_im = round(-sin(2*pi*k/64) * 1024)
    //
    // k=0:  cos=1.0000  sin=0.0000 -> re= 1024, im=    0
    // k=1:  cos=0.9952  sin=0.0980 -> re= 1019, im= -100
    // k=2:  cos=0.9808  sin=0.1951 -> re= 1004, im= -200
    // k=3:  cos=0.9569  sin=0.2903 -> re=  980, im= -297
    // k=4:  cos=0.9239  sin=0.3827 -> re=  946, im= -392
    // k=5:  cos=0.8819  sin=0.4714 -> re=  903, im= -483
    // k=6:  cos=0.8315  sin=0.5556 -> re=  851, im= -569
    // k=7:  cos=0.7730  sin=0.6344 -> re=  792, im= -650
    // k=8:  cos=0.7071  sin=0.7071 -> re=  724, im= -724
    // k=9:  cos=0.6344  sin=0.7730 -> re=  650, im= -792
    // k=10: cos=0.5556  sin=0.8315 -> re=  569, im= -851
    // k=11: cos=0.4714  sin=0.8819 -> re=  483, im= -903
    // k=12: cos=0.3827  sin=0.9239 -> re=  392, im= -946
    // k=13: cos=0.2903  sin=0.9569 -> re=  297, im= -980
    // k=14: cos=0.1951  sin=0.9808 -> re=  200, im=-1004
    // k=15: cos=0.0980  sin=0.9952 -> re=  100, im=-1019
    // k=16: cos=0.0000  sin=1.0000 -> re=    0, im=-1024
    // k=17: cos=-0.0980 sin=0.9952 -> re= -100, im=-1019
    // k=18: cos=-0.1951 sin=0.9808 -> re= -200, im=-1004
    // k=19: cos=-0.2903 sin=0.9569 -> re= -297, im= -980
    // k=20: cos=-0.3827 sin=0.9239 -> re= -392, im= -946
    // k=21: cos=-0.4714 sin=0.8819 -> re= -483, im= -903
    // k=22: cos=-0.5556 sin=0.8315 -> re= -569, im= -851
    // k=23: cos=-0.6344 sin=0.7730 -> re= -650, im= -792
    // k=24: cos=-0.7071 sin=0.7071 -> re= -724, im= -724
    // k=25: cos=-0.7730 sin=0.6344 -> re= -792, im= -650
    // k=26: cos=-0.8315 sin=0.5556 -> re= -851, im= -569
    // k=27: cos=-0.8819 sin=0.4714 -> re= -903, im= -483
    // k=28: cos=-0.9239 sin=0.3827 -> re= -946, im= -392
    // k=29: cos=-0.9569 sin=0.2903 -> re= -980, im= -297
    // k=30: cos=-0.9808 sin=0.1951 -> re=-1004, im= -200
    // k=31: cos=-0.9952 sin=0.0980 -> re=-1019, im= -100

    // Registered output for 1-cycle latency
    always @(posedge clk) begin
        case (addr)
            5'd0:  begin tw_re <= 12'sd1024;  tw_im <=  12'sd0;     end
            5'd1:  begin tw_re <= 12'sd1019;  tw_im <= -12'sd100;   end
            5'd2:  begin tw_re <= 12'sd1004;  tw_im <= -12'sd200;   end
            5'd3:  begin tw_re <= 12'sd980;   tw_im <= -12'sd297;   end
            5'd4:  begin tw_re <= 12'sd946;   tw_im <= -12'sd392;   end
            5'd5:  begin tw_re <= 12'sd903;   tw_im <= -12'sd483;   end
            5'd6:  begin tw_re <= 12'sd851;   tw_im <= -12'sd569;   end
            5'd7:  begin tw_re <= 12'sd792;   tw_im <= -12'sd650;   end
            5'd8:  begin tw_re <= 12'sd724;   tw_im <= -12'sd724;   end
            5'd9:  begin tw_re <= 12'sd650;   tw_im <= -12'sd792;   end
            5'd10: begin tw_re <= 12'sd569;   tw_im <= -12'sd851;   end
            5'd11: begin tw_re <= 12'sd483;   tw_im <= -12'sd903;   end
            5'd12: begin tw_re <= 12'sd392;   tw_im <= -12'sd946;   end
            5'd13: begin tw_re <= 12'sd297;   tw_im <= -12'sd980;   end
            5'd14: begin tw_re <= 12'sd200;   tw_im <= -12'sd1004;  end
            5'd15: begin tw_re <= 12'sd100;   tw_im <= -12'sd1019;  end
            5'd16: begin tw_re <= 12'sd0;     tw_im <= -12'sd1024;  end
            5'd17: begin tw_re <= -12'sd100;  tw_im <= -12'sd1019;  end
            5'd18: begin tw_re <= -12'sd200;  tw_im <= -12'sd1004;  end
            5'd19: begin tw_re <= -12'sd297;  tw_im <= -12'sd980;   end
            5'd20: begin tw_re <= -12'sd392;  tw_im <= -12'sd946;   end
            5'd21: begin tw_re <= -12'sd483;  tw_im <= -12'sd903;   end
            5'd22: begin tw_re <= -12'sd569;  tw_im <= -12'sd851;   end
            5'd23: begin tw_re <= -12'sd650;  tw_im <= -12'sd792;   end
            5'd24: begin tw_re <= -12'sd724;  tw_im <= -12'sd724;   end
            5'd25: begin tw_re <= -12'sd792;  tw_im <= -12'sd650;   end
            5'd26: begin tw_re <= -12'sd851;  tw_im <= -12'sd569;   end
            5'd27: begin tw_re <= -12'sd903;  tw_im <= -12'sd483;   end
            5'd28: begin tw_re <= -12'sd946;  tw_im <= -12'sd392;   end
            5'd29: begin tw_re <= -12'sd980;  tw_im <= -12'sd297;   end
            5'd30: begin tw_re <= -12'sd1004; tw_im <= -12'sd200;   end
            5'd31: begin tw_re <= -12'sd1019; tw_im <= -12'sd100;   end
            default: begin tw_re <= 12'sd0;   tw_im <= 12'sd0;      end
        endcase
    end

endmodule
