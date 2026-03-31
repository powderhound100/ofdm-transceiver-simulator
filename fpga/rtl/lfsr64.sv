// =============================================================================
// lfsr64.sv — 64-bit Galois LFSR for pseudo-random number generation
// =============================================================================
// Polynomial: x^64 + x^63 + x^61 + x^60 + 1
// Taps at bit positions 63, 62, 60, 59 (Galois feedback form).
//
// Outputs the lower 16 bits of the 64-bit state as a uniform random number
// each clock cycle. rand_valid is asserted one cycle after reset release or
// seed load, and remains high thereafter.
//
// Interface:
//   clk       — system clock
//   rst_n     — active-low synchronous reset
//   seed_load — pulse to load seed_val into the LFSR state
//   seed_val  — 64-bit seed value (must be non-zero)
//   rand_out  — 16-bit pseudo-random output (lower 16 bits of state)
//   rand_valid — high when rand_out is valid
// =============================================================================

`timescale 1ns / 1ps

module lfsr64 (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        seed_load,
    input  logic [63:0] seed_val,
    output logic [15:0] rand_out,
    output logic        rand_valid
);

    // -------------------------------------------------------------------------
    // Galois LFSR state register
    // -------------------------------------------------------------------------
    // Polynomial: x^64 + x^63 + x^61 + x^60 + 1
    // In Galois form, the feedback bit (MSB) is XORed into tap positions.
    // Taps at bits 63, 62, 60, 59 correspond to the polynomial terms.
    // Feedback mask: bit positions where feedback XOR is applied.
    // -------------------------------------------------------------------------
    localparam [63:0] FEEDBACK_MASK = 64'hD800_0000_0000_0000;
    // Bits 63,62,60,59 set = 0xD800...
    // x^63 -> bit 62, x^61 -> bit 60, x^60 -> bit 59, constant -> bit 63 (MSB shift)

    logic [63:0] state;
    logic        valid_r;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            // Default non-zero seed on reset
            state   <= 64'hDEAD_BEEF_CAFE_BABE;
            valid_r <= 1'b0;
        end else if (seed_load) begin
            // Load user-supplied seed; guard against all-zero
            state   <= (seed_val == 64'd0) ? 64'hDEAD_BEEF_CAFE_BABE : seed_val;
            valid_r <= 1'b0;
        end else begin
            // Galois LFSR shift: shift right by 1, XOR feedback if LSB is 1
            if (state[0]) begin
                state <= (state >> 1) ^ FEEDBACK_MASK;
            end else begin
                state <= state >> 1;
            end
            valid_r <= 1'b1;
        end
    end

    // -------------------------------------------------------------------------
    // Output: lower 16 bits of state
    // -------------------------------------------------------------------------
    assign rand_out  = state[15:0];
    assign rand_valid = valid_r;

endmodule
