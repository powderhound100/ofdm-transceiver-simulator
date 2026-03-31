// =============================================================================
// cp_removal.sv — Cyclic Prefix Removal
// =============================================================================
// Discards the first CP_LEN samples of each OFDM symbol, then passes the
// next FFT_N samples with AXI-Stream handshaking.
//
// State machine: DISCARD_CP -> PASS_DATA -> DISCARD_CP -> ...
// Asserts m_tlast on the last FFT sample (sample FFT_N-1).
// =============================================================================
`timescale 1ns / 1ps

module cp_removal #(
    parameter integer FFT_N  = 64,
    parameter integer CP_LEN = 16
)(
    input  wire        clk,
    input  wire        rst_n,

    // AXI-Stream slave — IQ samples in
    input  wire [31:0] s_tdata,   // {Q[15:0], I[15:0]}
    input  wire        s_tvalid,
    output wire        s_tready,

    // AXI-Stream master — IQ samples out (CP removed)
    output wire [31:0] m_tdata,
    output wire        m_tvalid,
    input  wire        m_tready,
    output wire        m_tlast
);

    // =========================================================================
    // State machine
    // =========================================================================
    localparam STATE_DISCARD = 1'b0;
    localparam STATE_PASS    = 1'b1;

    reg        state;
    reg [6:0]  cnt;  // counts up to max(CP_LEN, FFT_N) - 1

    // In DISCARD state we always accept input (sink samples).
    // In PASS state we accept input only when downstream is ready.
    wire discard_handshake = (state == STATE_DISCARD) && s_tvalid;
    wire pass_handshake    = (state == STATE_PASS)    && s_tvalid && m_tready;

    assign s_tready = (state == STATE_DISCARD) ? 1'b1 : m_tready;

    // Output is valid only in PASS state when we have valid input
    assign m_tvalid = (state == STATE_PASS) && s_tvalid;
    assign m_tdata  = s_tdata;
    assign m_tlast  = (state == STATE_PASS) && s_tvalid && (cnt == FFT_N - 1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= STATE_DISCARD;
            cnt   <= 7'd0;
        end else begin
            case (state)
                STATE_DISCARD: begin
                    if (s_tvalid) begin
                        if (cnt == CP_LEN - 1) begin
                            state <= STATE_PASS;
                            cnt   <= 7'd0;
                        end else begin
                            cnt <= cnt + 7'd1;
                        end
                    end
                end

                STATE_PASS: begin
                    if (s_tvalid && m_tready) begin
                        if (cnt == FFT_N - 1) begin
                            state <= STATE_DISCARD;
                            cnt   <= 7'd0;
                        end else begin
                            cnt <= cnt + 7'd1;
                        end
                    end
                end

                default: begin
                    state <= STATE_DISCARD;
                    cnt   <= 7'd0;
                end
            endcase
        end
    end

endmodule
