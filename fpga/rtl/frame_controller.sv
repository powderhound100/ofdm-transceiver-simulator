// =============================================================================
// frame_controller.sv — Multi-Symbol LLR Accumulator / Frame Buffer
// =============================================================================
// Collects LLRs across multiple OFDM symbols until a full LDPC codeword
// (CODEWORD_LEN=648 LLRs) is assembled. Then streams the codeword to the
// LDPC decoder via AXI-Stream.
//
// QPSK: 2 bits/sym × 48 data carriers = 96 LLRs/symbol → 7 symbols for 648
// (last symbol contributes 648 - 6*96 = 72 LLRs)
//
// Double-buffered: one BRAM buffer is being filled while the other is being
// read out, allowing continuous reception without gaps.
// =============================================================================
`timescale 1ns / 1ps

module frame_controller #(
    parameter integer CODEWORD_LEN = 648,
    parameter integer LLR_W        = 6
)(
    input  wire                    clk,
    input  wire                    rst_n,

    // LLR input from soft_demapper
    input  wire signed [LLR_W-1:0] llr_in,
    input  wire                    llr_valid,

    // AXI-Stream master — LLR frame to LDPC decoder
    output reg  [LLR_W-1:0]       m_tdata,
    output reg                     m_tvalid,
    output reg                     m_tlast,
    input  wire                    m_tready,

    // Status
    output reg                     frame_ready   // a full frame is buffered
);

    // =========================================================================
    // Address width for 648-deep buffer
    // =========================================================================
    localparam integer ADDR_W = $clog2(CODEWORD_LEN);  // 10 bits for 648

    // =========================================================================
    // Double-buffered BRAM: two 648 × LLR_W memories
    // =========================================================================
    reg [LLR_W-1:0] buf0 [0:CODEWORD_LEN-1];
    reg [LLR_W-1:0] buf1 [0:CODEWORD_LEN-1];

    // =========================================================================
    // Write side: fill one buffer
    // =========================================================================
    reg              wr_buf_sel;    // 0 = writing to buf0, 1 = writing to buf1
    reg [ADDR_W-1:0] wr_addr;
    reg              wr_frame_done; // pulse when a frame is complete

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_buf_sel   <= 1'b0;
            wr_addr      <= {ADDR_W{1'b0}};
            wr_frame_done <= 1'b0;
        end else begin
            wr_frame_done <= 1'b0;

            if (llr_valid) begin
                // Write LLR to current buffer
                if (wr_buf_sel == 1'b0)
                    buf0[wr_addr] <= llr_in;
                else
                    buf1[wr_addr] <= llr_in;

                if (wr_addr == CODEWORD_LEN - 1) begin
                    // Frame complete — switch buffers
                    wr_addr       <= {ADDR_W{1'b0}};
                    wr_buf_sel    <= ~wr_buf_sel;
                    wr_frame_done <= 1'b1;
                end else begin
                    wr_addr <= wr_addr + 1;
                end
            end
        end
    end

    // =========================================================================
    // Read side: stream completed buffer to LDPC decoder
    // =========================================================================
    localparam RD_IDLE   = 2'd0;
    localparam RD_STREAM = 2'd1;
    localparam RD_WAIT   = 2'd2;

    reg [1:0]         rd_state;
    reg               rd_buf_sel;    // which buffer to read from
    reg [ADDR_W-1:0]  rd_addr;
    reg               frames_pending; // a frame is ready to be read

    // Track pending frames
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frames_pending <= 1'b0;
        end else begin
            if (wr_frame_done)
                frames_pending <= 1'b1;
            else if (rd_state == RD_STREAM && rd_addr == CODEWORD_LEN - 1 && m_tready)
                frames_pending <= 1'b0;
        end
    end

    // Read state machine
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_state    <= RD_IDLE;
            rd_buf_sel  <= 1'b1;  // opposite of initial wr_buf_sel
            rd_addr     <= {ADDR_W{1'b0}};
            m_tdata     <= {LLR_W{1'b0}};
            m_tvalid    <= 1'b0;
            m_tlast     <= 1'b0;
            frame_ready <= 1'b0;
        end else begin
            case (rd_state)
                RD_IDLE: begin
                    m_tvalid    <= 1'b0;
                    m_tlast     <= 1'b0;
                    frame_ready <= 1'b0;

                    if (frames_pending) begin
                        // A completed frame is available
                        rd_buf_sel  <= ~wr_buf_sel;  // read the buffer that just finished
                        rd_addr     <= {ADDR_W{1'b0}};
                        rd_state    <= RD_STREAM;
                        frame_ready <= 1'b1;
                    end
                end

                RD_STREAM: begin
                    // Present data from buffer
                    if (rd_buf_sel == 1'b0)
                        m_tdata <= buf0[rd_addr];
                    else
                        m_tdata <= buf1[rd_addr];

                    m_tvalid <= 1'b1;
                    m_tlast  <= (rd_addr == CODEWORD_LEN - 1);

                    if (m_tready) begin
                        if (rd_addr == CODEWORD_LEN - 1) begin
                            rd_state <= RD_IDLE;
                            m_tvalid <= 1'b0;
                            m_tlast  <= 1'b0;
                        end else begin
                            rd_addr <= rd_addr + 1;
                        end
                    end
                end

                default: rd_state <= RD_IDLE;
            endcase
        end
    end

endmodule
