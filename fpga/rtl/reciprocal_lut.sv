// =============================================================================
// reciprocal_lut.sv — Reciprocal Look-Up Table
// =============================================================================
// 256-entry LUT: maps 8-bit magnitude-squared index to 16-bit reciprocal.
//
// Input:  unsigned 16-bit |H|^2
// Output: 16-bit Q0.15 approximation of 1/|H|^2
//
// Normalization: The 16-bit input is normalized to an 8-bit index by
// finding the MSB position and taking the top 8 significant bits.
// The output is then de-normalized by shifting accordingly.
//
// Table: for i=1..255: round(2^15 / i), entry 0 = 0x7FFF (max, avoid div-by-zero)
// 1-cycle latency (registered output).
// =============================================================================
`timescale 1ns / 1ps

module reciprocal_lut (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [15:0] mag_sq_in,   // |H|^2 unsigned
    input  wire        in_valid,

    output reg  [15:0] recip_out,   // Q0.15 reciprocal
    output reg         out_valid
);

    // =========================================================================
    // LUT storage (256 entries)
    // Table[i] = round(32768 / i) for i=1..255, Table[0] = 32767
    // =========================================================================
    reg [15:0] lut [0:255];

    integer k;
    initial begin
        lut[0] = 16'd32767;  // clamp for zero input
        for (k = 1; k < 256; k = k + 1) begin
            lut[k] = (32768 + k/2) / k;  // rounded integer division
        end
    end

    // =========================================================================
    // Input normalization — extract 8 MSBs from 16-bit value
    // =========================================================================
    // Find position of highest set bit, extract top 8 bits starting there,
    // and record the shift amount for de-normalization.

    reg [7:0]  lut_index;
    reg [3:0]  shift_amt;   // how many bits we shifted right to get the index
    reg        zero_input;

    always @(*) begin
        zero_input = (mag_sq_in == 16'd0);

        if (mag_sq_in[15:8] != 8'd0) begin
            // Top byte is nonzero: use it as index, shift = 8
            lut_index = mag_sq_in[15:8];
            shift_amt = 4'd8;
        end else begin
            // Top byte is zero: use bottom byte, shift = 0
            lut_index = mag_sq_in[7:0];
            shift_amt = 4'd0;
        end
    end

    // =========================================================================
    // LUT read + de-normalization (registered)
    // =========================================================================
    // LUT gives us approx 32768 / index.
    // Actual value is mag_sq_in = index << shift_amt (approximately).
    // So 1/mag_sq_in ≈ (32768 / index) >> shift_amt.
    // But we want result in Q0.15, so: recip = lut[index] >> shift_amt

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            recip_out <= 16'd0;
            out_valid <= 1'b0;
        end else begin
            out_valid <= in_valid;
            if (in_valid) begin
                if (zero_input) begin
                    recip_out <= 16'd32767;  // max value for zero input
                end else begin
                    recip_out <= lut[lut_index] >> shift_amt;
                end
            end
        end
    end

endmodule
