// =============================================================================
// subcarrier_mux.sv — OFDM Subcarrier Multiplexer (Pilot/Data/Guard Insertion)
// =============================================================================
// Places 48 data symbols + 4 pilot symbols into a 64-bin frequency-domain vector.
// Inverse of subcarrier_demux.
//
// Bin allocation (802.11a/n style):
//   Bins  0-5  : lower guard band (zero)
//   Bin   6    : pilot
//   Bins  7-17 : data (11 bins)
//   Bin  18    : pilot
//   Bins 19-29 : data (11 bins)
//   Bin  30    : pilot
//   Bins 31-42 : data (includes DC-ish; 12 bins — but bin 32 = DC if centered)
//   Bin  42    : pilot
//   Bins 43-57 : data (15 bins)
//   Bins 58-63 : upper guard band (zero)
//
// Note: Following the spec, we place:
//   Pilots at indices [6, 18, 30, 42]
//   Data at 48 subcarriers in [6..57] excluding pilots
//   DC (bin 0) and guard bands (0-5, 58-63) are zero
//
// Pilot value: BPSK +1.0 + j0.0 -> Q1.14: I = 16384, Q = 0
//
// Interface:
//   Input:  48 data symbols per OFDM symbol (consumed sequentially)
//   Output: 64 frequency bins per OFDM symbol (produced sequentially)
// =============================================================================
`timescale 1ns / 1ps

module subcarrier_mux #(
    parameter integer FFT_N = 64
)(
    input  wire        clk,
    input  wire        rst_n,

    // Input data symbols (48 per OFDM symbol)
    input  wire [31:0] data_in,     // {Q[15:0], I[15:0]} Q1.14
    input  wire        data_valid,

    // Output frequency bins (64 per OFDM symbol)
    output reg  [31:0] bin_out,     // {Q[15:0], I[15:0]} Q1.14
    output reg         bin_valid,
    output reg         bin_last,    // asserted on bin index 63
    output reg         bin_first    // asserted on bin index 0
);

    // =========================================================================
    // Constants
    // =========================================================================
    // Pilot value: BPSK +1.0 + j0.0 in Q1.14
    // I = 16384 = 0x4000, Q = 0
    localparam [31:0] PILOT_VAL = {16'd0, 16'h4000};  // {Q, I}
    localparam [31:0] ZERO_VAL  = 32'd0;

    // =========================================================================
    // Bin classification
    // =========================================================================
    // Determine bin type for each of the 64 output bins
    // Returns: 0 = guard/DC (zero), 1 = pilot, 2 = data
    function [1:0] bin_type;
        input [5:0] bin_idx;
        begin
            if (bin_idx <= 6'd5 || bin_idx >= 6'd58)
                bin_type = 2'd0;  // guard band -> zero
            else if (bin_idx == 6'd6 || bin_idx == 6'd18 ||
                     bin_idx == 6'd30 || bin_idx == 6'd42)
                bin_type = 2'd1;  // pilot
            else
                bin_type = 2'd2;  // data
        end
    endfunction

    // =========================================================================
    // State machine
    // =========================================================================
    // We buffer 48 data symbols first, then output 64 bins
    localparam [1:0] ST_LOAD = 2'd0;  // collect 48 data symbols
    localparam [1:0] ST_OUT  = 2'd1;  // output 64 bins

    reg [1:0]  state;
    reg [5:0]  load_cnt;      // 0..47 data symbol counter
    reg [5:0]  out_cnt;       // 0..63 bin output counter
    reg [5:0]  data_rd_idx;   // read index into data buffer

    // Data buffer: 48 complex symbols
    reg [31:0] data_buf [0:47];

    // =========================================================================
    // Main FSM
    // =========================================================================
    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= ST_LOAD;
            load_cnt   <= 6'd0;
            out_cnt    <= 6'd0;
            data_rd_idx <= 6'd0;
            bin_out    <= 32'd0;
            bin_valid  <= 1'b0;
            bin_last   <= 1'b0;
            bin_first  <= 1'b0;
            for (i = 0; i < 48; i = i + 1)
                data_buf[i] <= 32'd0;
        end else begin
            // Defaults
            bin_valid <= 1'b0;
            bin_last  <= 1'b0;
            bin_first <= 1'b0;

            case (state)
                // =============================================================
                // LOAD: collect 48 data symbols from input
                // =============================================================
                ST_LOAD: begin
                    if (data_valid) begin
                        data_buf[load_cnt] <= data_in;

                        if (load_cnt == 6'd47) begin
                            load_cnt    <= 6'd0;
                            state       <= ST_OUT;
                            out_cnt     <= 6'd0;
                            data_rd_idx <= 6'd0;
                        end else begin
                            load_cnt <= load_cnt + 6'd1;
                        end
                    end
                end

                // =============================================================
                // OUTPUT: stream 64 bins (guard=zero, pilot=BPSK, data=buffered)
                // =============================================================
                ST_OUT: begin
                    bin_valid <= 1'b1;

                    if (out_cnt == 6'd0)
                        bin_first <= 1'b1;
                    if (out_cnt == 6'd63)
                        bin_last <= 1'b1;

                    case (bin_type(out_cnt))
                        2'd0: begin
                            // Guard band or DC: output zero
                            bin_out <= ZERO_VAL;
                        end
                        2'd1: begin
                            // Pilot: output BPSK +1
                            bin_out <= PILOT_VAL;
                        end
                        2'd2: begin
                            // Data: output from buffer
                            bin_out     <= data_buf[data_rd_idx];
                            data_rd_idx <= data_rd_idx + 6'd1;
                        end
                        default: begin
                            bin_out <= ZERO_VAL;
                        end
                    endcase

                    if (out_cnt == 6'd63) begin
                        state   <= ST_LOAD;
                        out_cnt <= 6'd0;
                    end else begin
                        out_cnt <= out_cnt + 6'd1;
                    end
                end

                default: state <= ST_LOAD;
            endcase
        end
    end

endmodule
