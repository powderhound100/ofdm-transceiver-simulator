// =============================================================================
// cp_insertion.sv — Cyclic Prefix Insertion
// =============================================================================
// Buffers 64 time-domain IFFT output samples, then outputs:
//   1. Cyclic prefix: last CP_LEN=16 samples (indices 48..63)
//   2. Full OFDM symbol: all 64 samples (indices 0..63)
// Total output per symbol: 16 + 64 = 80 samples
//
// FSM: BUFFER (collect 64 samples) -> OUTPUT_CP (output 16 CP samples)
//      -> OUTPUT_DATA (output 64 data samples)
//
// AXI-Stream interfaces with backpressure support.
// m_tlast asserted on the last sample (sample 79 = data sample 63).
// =============================================================================
`timescale 1ns / 1ps

module cp_insertion #(
    parameter integer FFT_N  = 64,
    parameter integer CP_LEN = 16
)(
    input  wire        clk,
    input  wire        rst_n,

    // AXI-Stream slave — IFFT output samples
    input  wire [31:0] s_tdata,   // {Q[15:0], I[15:0]}
    input  wire        s_tvalid,
    output wire        s_tready,

    // AXI-Stream master — TX IQ samples with CP
    output reg  [31:0] m_tdata,
    output reg         m_tvalid,
    input  wire        m_tready,
    output reg         m_tlast
);

    // =========================================================================
    // Internal buffer: 64 x 32-bit
    // =========================================================================
    reg [31:0] buf_mem [0:FFT_N-1];

    // =========================================================================
    // FSM states
    // =========================================================================
    localparam [1:0] ST_BUFFER      = 2'd0;  // collect 64 IFFT samples
    localparam [1:0] ST_OUTPUT_CP   = 2'd1;  // output CP (last 16 samples)
    localparam [1:0] ST_OUTPUT_DATA = 2'd2;  // output full 64 samples

    reg [1:0] state;
    reg [6:0] cnt;  // counter: 0..63 for buffer, 0..15 for CP, 0..63 for data

    // =========================================================================
    // s_tready: accept input only during BUFFER state
    // =========================================================================
    assign s_tready = (state == ST_BUFFER);

    // =========================================================================
    // Main FSM
    // =========================================================================
    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= ST_BUFFER;
            cnt     <= 7'd0;
            m_tdata  <= 32'd0;
            m_tvalid <= 1'b0;
            m_tlast  <= 1'b0;
            for (i = 0; i < FFT_N; i = i + 1)
                buf_mem[i] <= 32'd0;
        end else begin
            // Clear m_tvalid/m_tlast only when downstream accepts (handshake)
            if (m_tvalid && m_tready) begin
                m_tvalid <= 1'b0;
                m_tlast  <= 1'b0;
            end

            case (state)
                // =============================================================
                // BUFFER: collect FFT_N=64 samples from IFFT output
                // =============================================================
                ST_BUFFER: begin
                    if (s_tvalid) begin
                        buf_mem[cnt[5:0]] <= s_tdata;

                        if (cnt == FFT_N - 1) begin
                            // All samples buffered, start CP output
                            state <= ST_OUTPUT_CP;
                            cnt   <= 7'd0;
                        end else begin
                            cnt <= cnt + 7'd1;
                        end
                    end
                end

                // =============================================================
                // OUTPUT_CP: output last CP_LEN samples (indices 48..63)
                // These form the cyclic prefix
                // =============================================================
                ST_OUTPUT_CP: begin
                    if (!m_tvalid || m_tready) begin
                        m_tdata  <= buf_mem[FFT_N - CP_LEN + cnt[3:0]];
                        m_tvalid <= 1'b1;
                        m_tlast  <= 1'b0;

                        if (cnt == CP_LEN - 1) begin
                            state <= ST_OUTPUT_DATA;
                            cnt   <= 7'd0;
                        end else begin
                            cnt <= cnt + 7'd1;
                        end
                    end
                end

                // =============================================================
                // OUTPUT_DATA: output all 64 samples (indices 0..63)
                // =============================================================
                ST_OUTPUT_DATA: begin
                    if (!m_tvalid || m_tready) begin
                        m_tdata  <= buf_mem[cnt[5:0]];
                        m_tvalid <= 1'b1;

                        if (cnt == FFT_N - 1) begin
                            m_tlast <= 1'b1;
                            state   <= ST_BUFFER;
                            cnt     <= 7'd0;
                        end else begin
                            m_tlast <= 1'b0;
                            cnt <= cnt + 7'd1;
                        end
                    end
                end

                default: begin
                    state <= ST_BUFFER;
                    cnt   <= 7'd0;
                end
            endcase
        end
    end

endmodule
