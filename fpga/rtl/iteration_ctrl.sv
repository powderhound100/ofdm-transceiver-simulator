// =============================================================================
// iteration_ctrl.sv — FSM controller for LDPC decoder iteration loop
// =============================================================================
// Controls: CNU pass -> VNU pass -> syndrome check -> repeat
//
// State machine:
//   IDLE -> (start) -> CNU_PHASE -> VNU_PHASE -> SYNDROME_PHASE
//     -> if syndrome_pass: DONE (converged=1)
//     -> if iter_count == max_iter-1: DONE (converged=0)
//     -> else: CNU_PHASE (next iteration)
//
// During CNU_PHASE: sweeps row_block 0..MB-1, for each row sweeps col_block
//   0..NB-1, skipping columns with no edge (shift_val == 9'h1FF).
//   Each column uses a FETCH -> WAIT -> PROCESS pipeline to handle
//   1-cycle ROM read latency.
//
// During VNU_PHASE: sweeps col_block 0..NB-1, for each col sweeps row_block
//   0..MB-1, skipping rows with no edge.  Same FETCH -> WAIT -> PROCESS
//   pipeline.
//
// During SYNDROME_PHASE: sweeps row_block 0..MB-1, for each row sweeps
//   col_block 0..NB-1, feeding hard-decision bits through the syndrome
//   checker using first_col/last_col/last_row signals.
// =============================================================================

module iteration_ctrl #(
    parameter int MB       = 12,   // number of check-node row blocks
    parameter int NB       = 24,   // number of variable-node column blocks
    parameter int MAX_ITER = 20    // maximum iterations
)(
    input  logic              clk,
    input  logic              rst_n,

    input  logic              start,          // begin decoding
    input  logic              syndrome_pass,  // from syndrome_checker
    input  logic              has_edge,       // from base_matrix_rom (current entry valid)

    output logic [5:0]        iter_count,     // current iteration (0..MAX_ITER-1)
    output logic              cnu_enable,     // CNU phase active
    output logic              vnu_enable,     // VNU phase active
    output logic              syndrome_enable,// syndrome check phase active
    output logic              done,           // decoding complete
    output logic              converged,      // true if syndrome_pass caused termination
    output logic [6:0]        current_row,    // current row-block being processed
    output logic [4:0]        current_col,    // current column-block
    output logic              first_col,      // first valid column for this row
    output logic              last_col,       // last valid column for this row
    output logic              first_row,      // first valid row for this column (VNU)
    output logic              last_row        // last valid row for this column (VNU)
);

    // =========================================================================
    // State definitions (5-bit encoding to accommodate all states)
    // =========================================================================
    typedef enum logic [4:0] {
        S_IDLE          = 5'd0,
        // CNU phase: FETCH sets ROM addr, WAIT absorbs ROM latency, PROCESS reads result
        S_CNU_FETCH     = 5'd1,
        S_CNU_WAIT      = 5'd2,
        S_CNU_PROCESS   = 5'd3,
        S_CNU_NEXT_ROW  = 5'd4,
        // VNU phase: same FETCH -> WAIT -> PROCESS pipeline
        S_VNU_FETCH     = 5'd5,
        S_VNU_WAIT      = 5'd6,
        S_VNU_PROCESS   = 5'd7,
        S_VNU_NEXT_COL  = 5'd8,
        // Syndrome phase: sweep rows x cols like CNU, feeding syndrome checker
        S_SYN_FETCH     = 5'd9,
        S_SYN_WAIT      = 5'd10,
        S_SYN_PROCESS   = 5'd11,
        S_SYN_NEXT_ROW  = 5'd12,
        S_SYN_CHECK     = 5'd13,   // check syndrome_pass after full sweep
        S_DONE          = 5'd14
    } state_t;

    state_t state;

    // Internal counters
    logic [6:0] row_cnt;
    logic [4:0] col_cnt;
    logic [5:0] iter_cnt;

    // Edge tracking for first/last detection
    logic       seen_first_edge;

    // Outputs
    assign iter_count = iter_cnt;
    assign current_row = row_cnt;
    assign current_col = col_cnt;

    // Phase enables — active only during PROCESS states when ROM data is valid
    assign cnu_enable      = (state == S_CNU_PROCESS);
    assign vnu_enable      = (state == S_VNU_PROCESS);
    assign syndrome_enable = (state == S_SYN_PROCESS);
    assign done            = (state == S_DONE);

    // =========================================================================
    // Main FSM
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= S_IDLE;
            row_cnt         <= '0;
            col_cnt         <= '0;
            iter_cnt        <= '0;
            converged       <= 1'b0;
            first_col       <= 1'b0;
            last_col        <= 1'b0;
            first_row       <= 1'b0;
            last_row        <= 1'b0;
            seen_first_edge <= 1'b0;
        end else begin
            // Default deassertions
            first_col <= 1'b0;
            last_col  <= 1'b0;
            first_row <= 1'b0;
            last_row  <= 1'b0;

            case (state)
                // ---------------------------------------------------------
                S_IDLE: begin
                    if (start) begin
                        state    <= S_CNU_FETCH;
                        row_cnt  <= '0;
                        col_cnt  <= '0;
                        iter_cnt <= '0;
                        converged <= 1'b0;
                        seen_first_edge <= 1'b0;
                    end
                end

                // ---------------------------------------------------------
                // CNU phase: sweep rows, for each row sweep columns
                // FETCH -> WAIT -> PROCESS pipeline per column
                // ---------------------------------------------------------
                S_CNU_FETCH: begin
                    // ROM address {row_cnt, col_cnt} is presented this cycle.
                    // Wait one cycle for ROM output to become valid.
                    state <= S_CNU_WAIT;
                end

                S_CNU_WAIT: begin
                    // ROM output (has_edge, shift_val) is now valid.
                    state <= S_CNU_PROCESS;
                end

                S_CNU_PROCESS: begin
                    // has_edge is valid for current {row_cnt, col_cnt}
                    if (has_edge) begin
                        if (!seen_first_edge) begin
                            first_col <= 1'b1;
                            seen_first_edge <= 1'b1;
                        end
                    end

                    // Check if this is the last column
                    if (col_cnt == NB - 1) begin
                        // End of columns for this row
                        if (has_edge)
                            last_col <= 1'b1;
                        state <= S_CNU_NEXT_ROW;
                    end else begin
                        // More columns to process — go back to FETCH
                        col_cnt <= col_cnt + 1'b1;
                        state   <= S_CNU_FETCH;
                    end
                end

                S_CNU_NEXT_ROW: begin
                    seen_first_edge <= 1'b0;
                    if (row_cnt == MB - 1) begin
                        // Done with CNU phase, move to VNU
                        state   <= S_VNU_FETCH;
                        row_cnt <= '0;
                        col_cnt <= '0;
                    end else begin
                        row_cnt <= row_cnt + 1'b1;
                        col_cnt <= '0;
                        state   <= S_CNU_FETCH;
                    end
                end

                // ---------------------------------------------------------
                // VNU phase: sweep columns, for each column sweep rows
                // FETCH -> WAIT -> PROCESS pipeline per row
                // ---------------------------------------------------------
                S_VNU_FETCH: begin
                    // ROM address {row_cnt, col_cnt} is presented this cycle.
                    state <= S_VNU_WAIT;
                end

                S_VNU_WAIT: begin
                    // ROM output is now valid.
                    state <= S_VNU_PROCESS;
                end

                S_VNU_PROCESS: begin
                    if (has_edge) begin
                        if (!seen_first_edge) begin
                            first_row <= 1'b1;
                            seen_first_edge <= 1'b1;
                        end
                    end

                    if (row_cnt == MB - 1) begin
                        if (has_edge)
                            last_row <= 1'b1;
                        state <= S_VNU_NEXT_COL;
                    end else begin
                        // More rows to process — go back to FETCH
                        row_cnt <= row_cnt + 1'b1;
                        state   <= S_VNU_FETCH;
                    end
                end

                S_VNU_NEXT_COL: begin
                    seen_first_edge <= 1'b0;
                    if (col_cnt == NB - 1) begin
                        // Done with VNU phase, move to syndrome check
                        state   <= S_SYN_FETCH;
                        row_cnt <= '0;
                        col_cnt <= '0;
                    end else begin
                        col_cnt <= col_cnt + 1'b1;
                        row_cnt <= '0;
                        state   <= S_VNU_FETCH;
                    end
                end

                // ---------------------------------------------------------
                // Syndrome phase: sweep rows x cols like CNU, feeding the
                // syndrome checker through first_col/last_col/last_row
                // FETCH -> WAIT -> PROCESS pipeline per column
                // ---------------------------------------------------------
                S_SYN_FETCH: begin
                    // ROM address {row_cnt, col_cnt} is presented this cycle.
                    state <= S_SYN_WAIT;
                end

                S_SYN_WAIT: begin
                    // ROM output is now valid.
                    state <= S_SYN_PROCESS;
                end

                S_SYN_PROCESS: begin
                    // Drive first_col for the syndrome checker
                    if (has_edge) begin
                        if (!seen_first_edge) begin
                            first_col <= 1'b1;
                            seen_first_edge <= 1'b1;
                        end
                    end

                    // Check if this is the last column
                    if (col_cnt == NB - 1) begin
                        // last_col: end of this row's column sweep
                        if (has_edge)
                            last_col <= 1'b1;
                        // last_row: final row AND final column
                        if (has_edge && row_cnt == MB - 1)
                            last_row <= 1'b1;
                        state <= S_SYN_NEXT_ROW;
                    end else begin
                        // More columns — go back to FETCH
                        col_cnt <= col_cnt + 1'b1;
                        state   <= S_SYN_FETCH;
                    end
                end

                S_SYN_NEXT_ROW: begin
                    seen_first_edge <= 1'b0;
                    if (row_cnt == MB - 1) begin
                        // All rows processed, check syndrome result
                        state <= S_SYN_CHECK;
                    end else begin
                        row_cnt <= row_cnt + 1'b1;
                        col_cnt <= '0;
                        state   <= S_SYN_FETCH;
                    end
                end

                S_SYN_CHECK: begin
                    // syndrome_checker produces valid + all_checks_pass
                    // one cycle after last_row & last_col were asserted in S_SYN_PROCESS.
                    // syndrome_pass = syndrome_valid & all_checks_pass (driven in ldpc_top).
                    if (syndrome_pass) begin
                        converged <= 1'b1;
                        state     <= S_DONE;
                    end else if (iter_cnt == MAX_ITER - 1) begin
                        converged <= 1'b0;
                        state     <= S_DONE;
                    end else begin
                        iter_cnt <= iter_cnt + 1'b1;
                        row_cnt  <= '0;
                        col_cnt  <= '0;
                        seen_first_edge <= 1'b0;
                        state    <= S_CNU_FETCH;
                    end
                end

                // ---------------------------------------------------------
                S_DONE: begin
                    // Stay here until externally reset or new start
                    if (start) begin
                        state    <= S_CNU_FETCH;
                        row_cnt  <= '0;
                        col_cnt  <= '0;
                        iter_cnt <= '0;
                        converged <= 1'b0;
                        seen_first_edge <= 1'b0;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
