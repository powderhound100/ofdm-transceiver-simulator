// =============================================================================
// qam_mapper.sv — QAM Symbol Mapper (QPSK / 16-QAM / 64-QAM)
// =============================================================================
// Maps groups of bits to complex IQ symbols in Q1.14 fixed-point format.
//
// Modulation modes (cfg_modulation):
//   0 = QPSK   : 2 bits/symbol, constellation = {+/-1+/-j1}/sqrt(2)
//   1 = 16-QAM : 4 bits/symbol, constellation = {+/-1,+/-3}^2 / sqrt(10)
//   2 = 64-QAM : 6 bits/symbol, constellation = {+/-1,+/-3,+/-5,+/-7}^2 / sqrt(42)
//
// Q1.14 values (16384 = 1.0):
//   QPSK:   +/-0.7071 -> +/-11585 (0x2D41)
//   16-QAM: {-3,-1,+1,+3}/sqrt(10) -> {-15541, -5180, +5180, +15541}
//   64-QAM: {-7,-5,-3,-1,+1,+3,+5,+7}/sqrt(42) -> {-17699,-12642,-7585,-2528,+2528,+7585,+12642,+17699}
//
// Gray coding: MSB selects sign, remaining bits select magnitude via Gray map.
//
// Interface:
//   Collects bits_per_symbol bits, then outputs one complex symbol.
//   Pipeline: BPS clocks to collect + 1 clock to output.
// =============================================================================
`timescale 1ns / 1ps

module qam_mapper (
    input  wire        clk,
    input  wire        rst_n,

    // Input: serial bit stream
    input  wire        bit_in,
    input  wire        bit_valid,

    // Configuration
    input  wire [3:0]  cfg_modulation,  // 0=QPSK, 1=16QAM, 2=64QAM

    // Output: complex symbol {Q[15:0], I[15:0]} in Q1.14
    output reg  [31:0] sym_out,
    output reg         sym_valid
);

    // =========================================================================
    // Bits-per-symbol lookup
    // =========================================================================
    reg [2:0] bits_per_sym;

    always @(*) begin
        case (cfg_modulation)
            4'd0:    bits_per_sym = 3'd2;  // QPSK
            4'd1:    bits_per_sym = 3'd4;  // 16-QAM
            4'd2:    bits_per_sym = 3'd6;  // 64-QAM
            default: bits_per_sym = 3'd2;  // default QPSK
        endcase
    end

    // =========================================================================
    // Bit accumulator — shift register collecting bits MSB first
    // =========================================================================
    reg [5:0] bit_sr;     // shift register (up to 6 bits for 64-QAM)
    reg [2:0] bit_cnt;    // number of bits collected so far

    // =========================================================================
    // QPSK constellation LUT (Gray-coded, normalized by 1/sqrt(2))
    // Index: {b1, b0} where b1 = I sign, b0 = Q sign
    //   00: +I, +Q   01: +I, -Q   10: -I, +Q   11: -I, -Q
    // Value: +/- 11585 (0x2D41 in Q1.14 = 0.7071)
    // =========================================================================
    localparam signed [15:0] QPSK_POS =  16'sd11585;  // +1/sqrt(2)
    localparam signed [15:0] QPSK_NEG = -16'sd11585;  // -1/sqrt(2)

    // =========================================================================
    // 16-QAM constellation levels (Gray-coded, normalized by 1/sqrt(10))
    // 2-bit Gray index -> level: 00->-3, 01->-1, 11->+1, 10->+3
    // Q1.14 values: level / sqrt(10) * 16384
    // =========================================================================
    localparam signed [15:0] QAM16_N3 = -16'sd15541;  // -3/sqrt(10)
    localparam signed [15:0] QAM16_N1 = -16'sd5180;   // -1/sqrt(10)
    localparam signed [15:0] QAM16_P1 =  16'sd5180;   // +1/sqrt(10)
    localparam signed [15:0] QAM16_P3 =  16'sd15541;  // +3/sqrt(10)

    function signed [15:0] qam16_level;
        input [1:0] gray_bits;
        begin
            case (gray_bits)
                2'b00: qam16_level = QAM16_N3;
                2'b01: qam16_level = QAM16_N1;
                2'b11: qam16_level = QAM16_P1;
                2'b10: qam16_level = QAM16_P3;
            endcase
        end
    endfunction

    // =========================================================================
    // 64-QAM constellation levels (Gray-coded, normalized by 1/sqrt(42))
    // 3-bit Gray index -> level: 000->-7, 001->-5, 011->-3, 010->-1,
    //                             110->+1, 111->+3, 101->+5, 100->+7
    // Q1.14 values: level / sqrt(42) * 16384
    // =========================================================================
    localparam signed [15:0] QAM64_N7 = -16'sd17699;  // -7/sqrt(42)
    localparam signed [15:0] QAM64_N5 = -16'sd12642;  // -5/sqrt(42)
    localparam signed [15:0] QAM64_N3 = -16'sd7585;   // -3/sqrt(42)
    localparam signed [15:0] QAM64_N1 = -16'sd2528;   // -1/sqrt(42)
    localparam signed [15:0] QAM64_P1 =  16'sd2528;   // +1/sqrt(42)
    localparam signed [15:0] QAM64_P3 =  16'sd7585;   // +3/sqrt(42)
    localparam signed [15:0] QAM64_P5 =  16'sd12642;  // +5/sqrt(42)
    localparam signed [15:0] QAM64_P7 =  16'sd17699;  // +7/sqrt(42)

    function signed [15:0] qam64_level;
        input [2:0] gray_bits;
        begin
            case (gray_bits)
                3'b000: qam64_level = QAM64_N7;
                3'b001: qam64_level = QAM64_N5;
                3'b011: qam64_level = QAM64_N3;
                3'b010: qam64_level = QAM64_N1;
                3'b110: qam64_level = QAM64_P1;
                3'b111: qam64_level = QAM64_P3;
                3'b101: qam64_level = QAM64_P5;
                3'b100: qam64_level = QAM64_P7;
            endcase
        end
    endfunction

    // =========================================================================
    // Mapping logic: convert accumulated bits to IQ symbol
    // =========================================================================
    reg signed [15:0] map_i, map_q;

    always @(*) begin
        map_i = 16'sd0;
        map_q = 16'sd0;

        case (cfg_modulation)
            // -----------------------------------------------------------------
            // QPSK: bit_sr[1:0] = {I_bit, Q_bit}
            // bit 1 -> I component, bit 0 -> Q component
            // 0 -> positive, 1 -> negative
            // -----------------------------------------------------------------
            4'd0: begin
                map_i = bit_sr[1] ? QPSK_NEG : QPSK_POS;
                map_q = bit_sr[0] ? QPSK_NEG : QPSK_POS;
            end

            // -----------------------------------------------------------------
            // 16-QAM: bit_sr[3:0] = {I1, I0, Q1, Q0}
            // I mapped from bits [3:2], Q mapped from bits [1:0]
            // -----------------------------------------------------------------
            4'd1: begin
                map_i = qam16_level(bit_sr[3:2]);
                map_q = qam16_level(bit_sr[1:0]);
            end

            // -----------------------------------------------------------------
            // 64-QAM: bit_sr[5:0] = {I2, I1, I0, Q2, Q1, Q0}
            // I mapped from bits [5:3], Q mapped from bits [2:0]
            // -----------------------------------------------------------------
            4'd2: begin
                map_i = qam64_level(bit_sr[5:3]);
                map_q = qam64_level(bit_sr[2:0]);
            end

            default: begin
                map_i = bit_sr[1] ? QPSK_NEG : QPSK_POS;
                map_q = bit_sr[0] ? QPSK_NEG : QPSK_POS;
            end
        endcase
    end

    // =========================================================================
    // Main sequential logic: collect bits, output symbol
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bit_sr    <= 6'd0;
            bit_cnt   <= 3'd0;
            sym_out   <= 32'd0;
            sym_valid <= 1'b0;
        end else begin
            sym_valid <= 1'b0;

            if (bit_valid) begin
                // Shift in new bit (MSB first)
                bit_sr  <= {bit_sr[4:0], bit_in};
                bit_cnt <= bit_cnt + 3'd1;

                // Check if we have collected enough bits
                if (bit_cnt == bits_per_sym - 3'd1) begin
                    // All bits collected — output symbol next cycle
                    // Note: map_i/map_q use the *current* bit_sr which hasn't
                    // been updated yet in this cycle. We need to use the
                    // value that includes the new bit.
                    bit_cnt <= 3'd0;
                end
            end

            // Output symbol when bit count resets (previous cycle completed collection)
            // Use a registered approach: detect when we just completed a symbol
            if (bit_valid && (bit_cnt == bits_per_sym - 3'd1)) begin
                // Use combinational map outputs which reflect the shift reg
                // with the final bit shifted in
                case (cfg_modulation)
                    4'd0: begin // QPSK: 2 bits {bit_sr[0], bit_in}
                        sym_out <= {
                            (bit_in    ? QPSK_NEG : QPSK_POS),
                            (bit_sr[0] ? QPSK_NEG : QPSK_POS)
                        };
                    end
                    4'd1: begin // 16-QAM: 4 bits {bit_sr[2:0], bit_in}
                        sym_out <= {
                            qam16_level({bit_sr[0], bit_in}),
                            qam16_level(bit_sr[2:1])
                        };
                    end
                    4'd2: begin // 64-QAM: 6 bits {bit_sr[4:0], bit_in}
                        sym_out <= {
                            qam64_level({bit_sr[1:0], bit_in}),
                            qam64_level(bit_sr[4:2])
                        };
                    end
                    default: begin
                        sym_out <= {
                            (bit_in    ? QPSK_NEG : QPSK_POS),
                            (bit_sr[0] ? QPSK_NEG : QPSK_POS)
                        };
                    end
                endcase
                sym_valid <= 1'b1;
            end
        end
    end

endmodule
