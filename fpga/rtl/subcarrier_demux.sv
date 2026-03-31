// =============================================================================
// subcarrier_demux.sv — Pilot/Data/Guard-band Extraction
// =============================================================================
// Routes FFT output bins to appropriate destinations:
//   - Guard bands: bins [0..5] and [58..63] → discarded
//   - Pilot subcarriers: bins {6, 18, 30, 42} → pilot output
//   - Data subcarriers: bins [6..57] excluding pilots → data output (48 carriers)
//
// Input: 64 complex values per OFDM symbol, streamed with valid.
// Output: Separate pilot and data streams.
// =============================================================================
`timescale 1ns / 1ps

module subcarrier_demux #(
    parameter integer FFT_N = 64
)(
    input  wire        clk,
    input  wire        rst_n,

    // Input from FFT (64 bins per symbol)
    input  wire [31:0] fft_data,     // {Q[15:0], I[15:0]}
    input  wire        fft_valid,
    input  wire        fft_last,     // last bin of symbol (bin 63)

    // Pilot output (4 per symbol)
    output reg  [31:0] pilot_data,
    output reg         pilot_valid,
    output reg         pilot_last,   // asserted on 4th pilot

    // Data output (48 per symbol)
    output reg  [31:0] data_out,
    output reg         data_valid,
    output reg         data_last     // asserted on last data subcarrier
);

    // =========================================================================
    // Bin counter: tracks which FFT bin (0..63)
    // =========================================================================
    reg [5:0] bin_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bin_cnt <= 6'd0;
        end else if (fft_valid) begin
            if (bin_cnt == 6'd63)
                bin_cnt <= 6'd0;
            else
                bin_cnt <= bin_cnt + 6'd1;
        end
    end

    // =========================================================================
    // Classification logic
    // =========================================================================
    // Pilot positions
    wire is_pilot = (bin_cnt == 6'd6)  || (bin_cnt == 6'd18) ||
                    (bin_cnt == 6'd30) || (bin_cnt == 6'd42);

    // Guard bands
    wire is_guard = (bin_cnt <= 6'd5) || (bin_cnt >= 6'd58);

    // Data: used range [6..57] minus pilots
    wire is_data = !is_guard && !is_pilot;

    // Pilot count within symbol
    reg [1:0] pilot_cnt;

    // Data count within symbol (0..47)
    reg [5:0] data_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pilot_cnt <= 2'd0;
            data_cnt  <= 6'd0;
        end else if (fft_valid) begin
            if (is_pilot) begin
                if (pilot_cnt == 2'd3)
                    pilot_cnt <= 2'd0;
                else
                    pilot_cnt <= pilot_cnt + 2'd1;
            end

            if (is_data) begin
                if (data_cnt == 6'd47)
                    data_cnt <= 6'd0;
                else
                    data_cnt <= data_cnt + 6'd1;
            end

            // Reset counters at end of symbol
            if (bin_cnt == 6'd63) begin
                pilot_cnt <= 2'd0;
                data_cnt  <= 6'd0;
            end
        end
    end

    // =========================================================================
    // Output registration
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pilot_data  <= 32'd0;
            pilot_valid <= 1'b0;
            pilot_last  <= 1'b0;
            data_out    <= 32'd0;
            data_valid  <= 1'b0;
            data_last   <= 1'b0;
        end else begin
            // Default: deassert valids
            pilot_valid <= 1'b0;
            pilot_last  <= 1'b0;
            data_valid  <= 1'b0;
            data_last   <= 1'b0;

            if (fft_valid) begin
                if (is_pilot) begin
                    pilot_data  <= fft_data;
                    pilot_valid <= 1'b1;
                    pilot_last  <= (pilot_cnt == 2'd3);
                end

                if (is_data) begin
                    data_out   <= fft_data;
                    data_valid <= 1'b1;
                    data_last  <= (data_cnt == 6'd47);
                end
            end
        end
    end

endmodule
