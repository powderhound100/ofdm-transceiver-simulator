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
//
// During VNU_PHASE: sweeps col_block 0..NB-1, for each col sweeps row_block
//   0..MB-1, skipping rows with no edge.
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
    // State definitions
    // =========================================================================
    typedef enum logic [3:0] {
        S_IDLE          = 4'd0,
        S_CNU_FETCH     = 4'd1,   // ROM fetch latency
        S_CNU_PROCESS   = 4'd2,   // process column blocks for current row
        S_CNU_NEXT_ROW  = 4'd3,   // advance to next row
        S_VNU_FETCH     = 4'd4,
        S_VNU_PROCESS   = 4'd5,
        S_VNU_NEXT_COL  = 4'd6,
        S_SYNDROME      = 4'd7,
        S_SYNDROME_WAIT = 4'd8,
        S_DONE          = 4'd9
    } state_t;

    state_t state;

    // Internal counters
    logic [6:0] row_cnt;
    logic [4:0] col_cnt;
    logic [5:0] iter_cnt;

    // Edge tracking for first/last detection
    logic       seen_first_edge;
    logic [4:0] last_edge_col;   // for CNU: last column with an edge in this row
    logic [6:0] last_edge_row;   // for VNU: last row with an edge in this column

    // Precomputed: we need to know last edge col for each row and last edge row for each col
    // We'll detect first/last dynamically by scanning

    // Outputs
    assign iter_count = iter_cnt;
    assign current_row = row_cnt;
    assign current_col = col_cnt;

    // Phase enables
    assign cnu_enable      = (state == S_CNU_PROCESS);
    assign vnu_enable      = (state == S_VNU_PROCESS);
    assign syndrome_enable = (state == S_SYNDROME) || (state == S_SYNDROME_WAIT);
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
            last_edge_col   <= '0;
            last_edge_row   <= '0;
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
                // ---------------------------------------------------------
                S_CNU_FETCH: begin
                    // Wait 1 cycle for ROM to produce shift_val/has_edge
                    state <= S_CNU_PROCESS;
                end

                // TODO(high): has_edge from base_matrix_rom has 1-cycle latency.
                // Current design reads has_edge in S_CNU_PROCESS but the ROM
                // address was set when entering S_CNU_FETCH. From the second
                // column onward, the col_cnt increment in S_CNU_PROCESS means
                // has_edge reflects the PREVIOUS column, not the current one.
                // Fix: add a fetch-wait cycle for each column, or pipeline
                // has_edge to align with the column being processed.
                S_CNU_PROCESS: begin
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
                        col_cnt <= col_cnt + 1'b1;
                        // Stay in S_CNU_PROCESS (ROM has 1-cycle latency,
                        // we read ahead since ROM was clocked last cycle)
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
                // ---------------------------------------------------------
                S_VNU_FETCH: begin
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
                        row_cnt <= row_cnt + 1'b1;
                    end
                end

                S_VNU_NEXT_COL: begin
                    seen_first_edge <= 1'b0;
                    if (col_cnt == NB - 1) begin
                        // Done with VNU phase, move to syndrome check
                        state   <= S_SYNDROME;
                        row_cnt <= '0;
                        col_cnt <= '0;
                    end else begin
                        col_cnt <= col_cnt + 1'b1;
                        row_cnt <= '0;
                        state   <= S_VNU_FETCH;
                    end
                end

                // ---------------------------------------------------------
                // Syndrome check phase
                // ---------------------------------------------------------
                // TODO(high): The syndrome checker needs column-by-column hard
                // bits fed via first_col/last_col/last_row strobes, but this
                // state does not drive any column scanning. The checker never
                // receives data and syndrome_pass is undefined.
                // Fix: sweep all row-blocks x col-blocks here (like CNU phase)
                // feeding the syndrome checker, OR compute syndrome incrementally
                // during VNU and just read the result here.
                S_SYNDROME: begin
                    // Allow syndrome checker some cycles to evaluate
                    state <= S_SYNDROME_WAIT;
                end

                S_SYNDROME_WAIT: begin
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
