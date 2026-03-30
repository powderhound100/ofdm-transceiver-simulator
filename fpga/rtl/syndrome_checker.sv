// =============================================================================
// syndrome_checker.sv — Parity check (syndrome) verification
// =============================================================================
// For each row-block, accumulates XOR of cyclically-shifted hard_bits across
// all column blocks. After all columns of all rows are processed, checks if
// all accumulated parities are zero (all parity checks satisfied).
//
// Usage: the controller feeds column blocks for each row sequentially.
// =============================================================================

module syndrome_checker #(
    parameter int Z  = 27,   // lifting size
    parameter int MB = 12    // number of check-node row blocks
)(
    input  logic              clk,
    input  logic              rst_n,

    input  logic [Z-1:0]     hard_bits_block, // Z hard-decision bits for current variable block
    input  logic [8:0]        shift_val,       // barrel shift for this (row, col) block
    input  logic              has_edge,        // this (row, col) has an edge
    input  logic              first_col,       // first column of this row-block
    input  logic              last_col,        // last column of this row-block
    input  logic              last_row,        // this is the final row-block
    input  logic              in_valid,        // input data valid

    output logic              all_checks_pass, // all parity checks satisfied
    output logic              valid            // output is valid
);

    // Parity accumulators: one Z-bit word per row-block
    logic [Z-1:0] parity_acc [0:MB-1];
    logic [6:0]   row_cnt;

    // Shifted hard bits (combinational barrel shift for syndrome check)
    logic [Z-1:0] shifted_bits;

    always_comb begin
        for (int i = 0; i < Z; i++) begin
            shifted_bits[i] = hard_bits_block[(i + Z - (shift_val % Z)) % Z];
        end
    end

    // Combinational: check all parity accumulators
    // Computes what the final parity state will be after this cycle
    logic all_zero_comb;
    logic [Z-1:0] final_parity_arr [0:MB-1];

    always_comb begin
        all_zero_comb = 1'b1;
        for (int r = 0; r < MB; r++) begin
            if (in_valid && last_col && last_row) begin
                if (r[6:0] == row_cnt) begin
                    if (first_col)
                        final_parity_arr[r] = has_edge ? shifted_bits : {Z{1'b0}};
                    else
                        final_parity_arr[r] = has_edge ?
                            (parity_acc[r] ^ shifted_bits) : parity_acc[r];
                end else begin
                    final_parity_arr[r] = parity_acc[r];
                end
            end else begin
                final_parity_arr[r] = parity_acc[r];
            end
            if (final_parity_arr[r] != {Z{1'b0}})
                all_zero_comb = 1'b0;
        end
    end

    // Track which row we are processing
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row_cnt <= '0;
            valid   <= 1'b0;
            all_checks_pass <= 1'b0;
            for (int r = 0; r < MB; r++)
                parity_acc[r] <= '0;
        end else begin
            valid <= 1'b0;

            if (in_valid) begin
                if (first_col) begin
                    if (has_edge)
                        parity_acc[row_cnt] <= shifted_bits;
                    else
                        parity_acc[row_cnt] <= '0;
                end else if (has_edge) begin
                    parity_acc[row_cnt] <= parity_acc[row_cnt] ^ shifted_bits;
                end

                if (last_col) begin
                    if (last_row) begin
                        all_checks_pass <= all_zero_comb;
                        valid           <= 1'b1;
                        row_cnt         <= '0;
                    end else begin
                        row_cnt <= row_cnt + 1'b1;
                    end
                end
            end
        end
    end

endmodule
