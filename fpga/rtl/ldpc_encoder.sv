// =============================================================================
// ldpc_encoder.sv — LDPC Encoder for 802.11n rate-1/2 (Z=27)
// =============================================================================
// GF(2) systematic encoding: codeword = [info_bits | parity_bits]
// K=324 information bits -> N=648 codeword bits (12 info blocks, 12 parity blocks)
//
// Algorithm — quasi-cyclic XOR accumulation:
//   For each parity block p (0..11):
//     For each info block j (0..11):
//       if base_matrix[p][j] >= 0:
//         parity_block[p] ^= cyclic_shift(info_block[j], base_matrix[p][j])
//
// Uses the existing base_matrix_rom for shift values.
//
// AXI-Stream interface:
//   Slave:  1-bit info bits in
//   Master: 1-bit coded bits out (systematic: info then parity)
//
// FSM: IDLE -> LOAD_INFO (324 clk) -> ENCODE (~12*12+margin clk) -> OUTPUT (648 clk)
// =============================================================================
`timescale 1ns / 1ps

module ldpc_encoder #(
    parameter integer Z  = 27,
    parameter integer MB = 12,
    parameter integer NB = 24
)(
    input  wire        clk,
    input  wire        rst_n,

    // AXI-Stream slave — info bits in (1 bit per transfer)
    input  wire        s_tdata,
    input  wire        s_tvalid,
    output wire        s_tready,
    input  wire        s_tlast,

    // AXI-Stream master — coded bits out (1 bit per transfer)
    output wire        m_tdata,
    output wire        m_tvalid,
    input  wire        m_tready,
    output wire        m_tlast,

    // Status
    output wire        busy
);

    // =========================================================================
    // Local parameters
    // =========================================================================
    localparam integer K = MB * Z;   // 324 info bits
    localparam integer N = NB * Z;   // 648 codeword bits
    localparam integer INFO_BLOCKS = 12;   // info column blocks (0..11)
    localparam integer PARITY_BLOCKS = 12; // parity column blocks (12..23)

    // =========================================================================
    // FSM states
    // =========================================================================
    localparam [2:0] ST_IDLE      = 3'd0;
    localparam [2:0] ST_LOAD_INFO = 3'd1;
    localparam [2:0] ST_ENCODE    = 3'd2;
    localparam [2:0] ST_OUTPUT    = 3'd3;

    reg [2:0] state;

    // =========================================================================
    // Internal storage
    // =========================================================================
    // Info bits: 12 blocks of Z=27 bits each = 324 bits
    reg [Z-1:0] info_block [0:INFO_BLOCKS-1];

    // Parity bits: 12 blocks of Z=27 bits each = 324 bits
    reg [Z-1:0] parity_block [0:PARITY_BLOCKS-1];

    // =========================================================================
    // Base matrix ROM interface
    // =========================================================================
    reg  [6:0] rom_row;
    reg  [4:0] rom_col;
    wire [8:0] rom_shift_val;
    wire        rom_has_edge;

    base_matrix_rom #(
        .MB(MB),
        .NB(NB)
    ) u_bm_rom (
        .clk       (clk),
        .rst_n     (rst_n),
        .row_block (rom_row),
        .col_block (rom_col),
        .shift_val (rom_shift_val),
        .has_edge  (rom_has_edge)
    );

    // =========================================================================
    // Counters
    // =========================================================================
    reg [9:0] bit_cnt;          // counts 0..647 for load/output
    reg [3:0] enc_row;          // parity block index 0..11
    reg [3:0] enc_col;          // info block index 0..11
    reg [1:0] enc_pipe;         // pipeline delay for ROM read (1-cycle latency)

    // Cyclic shift of a Z-bit vector by 'amount' positions
    // shift_val positions to the right (circular)
    // Implemented as a combinational function
    function [Z-1:0] cyclic_shift;
        input [Z-1:0] data;
        input [8:0]   amount;
        reg [4:0] sh;
        integer i;
        begin
            sh = amount[4:0]; // amount < Z=27, fits in 5 bits
            for (i = 0; i < Z; i = i + 1) begin
                cyclic_shift[i] = data[(i + Z - sh) % Z];
            end
        end
    endfunction

    // Pipeline registers for encode stage
    reg        enc_rom_valid;   // ROM output is valid for current (row,col)
    reg [3:0]  enc_row_d1;     // delayed row for when ROM data arrives
    reg [3:0]  enc_col_d1;     // delayed col
    reg        enc_active;     // we are actively encoding

    // =========================================================================
    // s_tready: accept info bits only in LOAD_INFO state
    // =========================================================================
    assign s_tready = (state == ST_LOAD_INFO) || (state == ST_IDLE);

    // =========================================================================
    // Output signals
    // =========================================================================
    reg        out_valid;
    reg        out_data;
    reg        out_last;

    assign m_tdata  = out_data;
    assign m_tvalid = out_valid;
    assign m_tlast  = out_last;
    assign busy     = (state != ST_IDLE);

    // =========================================================================
    // Main FSM
    // =========================================================================
    integer idx;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= ST_IDLE;
            bit_cnt       <= 10'd0;
            enc_row       <= 4'd0;
            enc_col       <= 4'd0;
            enc_pipe      <= 2'd0;
            enc_rom_valid <= 1'b0;
            enc_row_d1    <= 4'd0;
            enc_col_d1    <= 4'd0;
            enc_active    <= 1'b0;
            rom_row       <= 7'd0;
            rom_col       <= 5'd0;
            out_valid     <= 1'b0;
            out_data      <= 1'b0;
            out_last      <= 1'b0;
            for (idx = 0; idx < INFO_BLOCKS; idx = idx + 1)
                info_block[idx] <= {Z{1'b0}};
            for (idx = 0; idx < PARITY_BLOCKS; idx = idx + 1)
                parity_block[idx] <= {Z{1'b0}};
        end else begin
            // Defaults
            out_valid     <= 1'b0;
            out_last      <= 1'b0;
            enc_rom_valid <= 1'b0;

            case (state)
                // =============================================================
                // IDLE: wait for first info bit
                // =============================================================
                ST_IDLE: begin
                    if (s_tvalid) begin
                        state   <= ST_LOAD_INFO;
                        bit_cnt <= 10'd0;
                        // Store first bit
                        info_block[0][0] <= s_tdata;
                        bit_cnt <= 10'd1;
                        // Clear parity blocks
                        for (idx = 0; idx < PARITY_BLOCKS; idx = idx + 1)
                            parity_block[idx] <= {Z{1'b0}};
                    end
                end

                // =============================================================
                // LOAD_INFO: collect 324 info bits serially
                // =============================================================
                ST_LOAD_INFO: begin
                    if (s_tvalid) begin
                        // Determine block and bit position
                        // bit_cnt / Z = block index, bit_cnt % Z = bit within block
                        info_block[bit_cnt / Z][bit_cnt % Z] <= s_tdata;

                        if (bit_cnt == K - 1 || s_tlast) begin
                            // All info bits loaded, start encoding
                            state    <= ST_ENCODE;
                            enc_row  <= 4'd0;
                            enc_col  <= 4'd0;
                            enc_pipe <= 2'd0;
                            // Issue first ROM read: row=0, col=0 (info column 0)
                            rom_row  <= 7'd0;
                            rom_col  <= 5'd0;
                            enc_active <= 1'b1;
                        end else begin
                            bit_cnt <= bit_cnt + 10'd1;
                        end
                    end
                end

                // =============================================================
                // ENCODE: compute parity via quasi-cyclic XOR accumulation
                // For each (row, col) pair in [0..11] x [0..11]:
                //   Issue ROM read, wait 1 cycle, then XOR shifted info block
                // =============================================================
                ST_ENCODE: begin
                    if (enc_active) begin
                        // Pipeline stage: ROM has 1-cycle latency
                        // Cycle 0: issue address (already done)
                        // Cycle 1: ROM output valid, perform XOR

                        if (enc_pipe == 2'd0) begin
                            // Address was issued last cycle or at transition
                            // Wait for ROM data
                            enc_pipe   <= 2'd1;
                            enc_row_d1 <= enc_row;
                            enc_col_d1 <= enc_col;
                        end else if (enc_pipe == 2'd1) begin
                            // ROM data is now valid
                            if (rom_has_edge) begin
                                parity_block[enc_row_d1] <=
                                    parity_block[enc_row_d1] ^
                                    cyclic_shift(info_block[enc_col_d1], rom_shift_val);
                            end

                            // Advance to next (row, col) and issue next ROM read
                            if (enc_col == INFO_BLOCKS - 1) begin
                                // Done with all columns for this row
                                if (enc_row == PARITY_BLOCKS - 1) begin
                                    // All rows done — encoding complete
                                    enc_active <= 1'b0;
                                    state      <= ST_OUTPUT;
                                    bit_cnt    <= 10'd0;
                                end else begin
                                    enc_row <= enc_row + 4'd1;
                                    enc_col <= 4'd0;
                                    rom_row <= {3'd0, enc_row} + 7'd1;
                                    rom_col <= 5'd0;
                                    enc_pipe <= 2'd0;
                                end
                            end else begin
                                enc_col <= enc_col + 4'd1;
                                rom_row <= {3'd0, enc_row};
                                rom_col <= {1'd0, enc_col} + 5'd1;
                                enc_pipe <= 2'd0;
                            end
                        end
                    end
                end

                // =============================================================
                // OUTPUT: stream 648 coded bits (324 info + 324 parity)
                // =============================================================
                ST_OUTPUT: begin
                    if (m_tready || !out_valid) begin
                        out_valid <= 1'b1;

                        if (bit_cnt < K) begin
                            // Output info bits (systematic)
                            out_data <= info_block[bit_cnt / Z][bit_cnt % Z];
                        end else begin
                            // Output parity bits
                            out_data <= parity_block[(bit_cnt - K) / Z][(bit_cnt - K) % Z];
                        end

                        if (bit_cnt == N - 1) begin
                            out_last <= 1'b1;
                            state    <= ST_IDLE;
                            bit_cnt  <= 10'd0;
                        end else begin
                            bit_cnt <= bit_cnt + 10'd1;
                        end
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
