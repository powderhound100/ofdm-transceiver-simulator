// =============================================================================
// check_node_unit.sv — Check Node Unit (CNU) using min-sum / min2 architecture
// =============================================================================
// Processes one row-block at a time. For each row-block the controller feeds
// column blocks one at a time with first_col / last_col strobes.
//
// Accumulates sign_product, min1, min2, argmin1 across all column blocks.
// On last_col: replays the column blocks (reads back stored v2c signs) and
// produces c2v messages using the min2 formula:
//
//   c2v[j] = alpha * ext_sign_j * (j == argmin1 ? min2 : min1)
//
// Alpha = 0.75 = 1 - 1/4 => x - (x >>> 2) (arithmetic right shift, no DSP)
//
// Latency: degree + 2 pipeline cycles per row-block
// =============================================================================

module check_node_unit #(
    parameter int Z         = 27,   // lifting size
    parameter int W         = 6,    // element bit-width (signed)
    parameter int MAX_DEG   = 20    // max check node degree
)(
    input  logic              clk,
    input  logic              rst_n,

    // Streaming interface — one column block per cycle
    input  logic [W*Z-1:0]   v2c_in,        // Z v2c messages for current column block
    input  logic [8:0]        shift_val,     // barrel shift amount for this column block
    input  logic              first_col,     // reset accumulators
    input  logic              last_col,      // trigger c2v output
    input  logic              in_valid,      // column data is valid
    input  logic [4:0]        col_idx,       // column index within this row (0-based)

    // Output
    output logic [W*Z-1:0]   c2v_out,       // Z c2v messages
    output logic              c2v_valid      // c2v_out is valid
);

    // =========================================================================
    // Internal types
    // =========================================================================
    localparam int MAG_BITS = W - 1;  // 5 magnitude bits

    // Per-element sign and magnitude (after barrel shift)
    logic [W*Z-1:0] shifted_data;
    logic            shifted_valid;
    logic            shifted_first_col;
    logic            shifted_last_col;
    logic [4:0]      shifted_col_idx;

    // Barrel shifter instance
    // We need the shifted result with 2-cycle latency, matching barrel_shifter
    barrel_shifter #(.Z(Z), .W(W)) u_bsh (
        .clk      (clk),
        .rst_n    (rst_n),
        .data_in  (v2c_in),
        .shift_val(shift_val),
        .data_out (shifted_data)
    );

    // Pipeline delay for control signals to match barrel shifter latency (2 cycles)
    logic valid_d1, valid_d2;
    logic first_d1, first_d2;
    logic last_d1,  last_d2;
    logic [4:0] cidx_d1, cidx_d2;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            {valid_d1, valid_d2} <= '0;
            {first_d1, first_d2} <= '0;
            {last_d1, last_d2}   <= '0;
            {cidx_d1, cidx_d2}   <= '0;
        end else begin
            valid_d1 <= in_valid;  valid_d2 <= valid_d1;
            first_d1 <= first_col; first_d2 <= first_d1;
            last_d1  <= last_col;  last_d2  <= last_d1;
            cidx_d1  <= col_idx;   cidx_d2  <= cidx_d1;
        end
    end

    assign shifted_valid     = valid_d2;
    assign shifted_first_col = first_d2;
    assign shifted_last_col  = last_d2;
    assign shifted_col_idx   = cidx_d2;

    // =========================================================================
    // Accumulate sign_product and min1/min2/argmin1 across columns
    // =========================================================================
    // We process Z elements in parallel. For each element position within the
    // Z-block, we track: accumulated sign product, min1, min2, argmin of min1.

    // Accumulators (per Z-element)
    logic [Z-1:0]          acc_sign_prod;   // sign product accumulator
    logic [MAG_BITS-1:0]   acc_min1 [0:Z-1];
    logic [MAG_BITS-1:0]   acc_min2 [0:Z-1];
    logic [4:0]            acc_argmin1 [0:Z-1];

    // Store signs per column for c2v replay
    logic [Z-1:0]          stored_signs [0:MAX_DEG-1];  // signs[col][z_idx]

    // Degree counter
    logic [4:0]            degree_cnt;

    // Extract sign/mag from shifted data for each Z element
    logic [Z-1:0]          cur_signs;
    logic [MAG_BITS-1:0]   cur_mags [0:Z-1];

    always_comb begin
        for (int z = 0; z < Z; z++) begin
            cur_signs[z] = shifted_data[z*W + W - 1];  // sign bit (MSB)
            if (shifted_data[z*W + W - 1])              // if negative
                cur_mags[z] = ~shifted_data[z*W +: MAG_BITS] + 1'b1;
            else
                cur_mags[z] = shifted_data[z*W +: MAG_BITS];
        end
    end

    // Accumulation logic
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_sign_prod <= '0;
            degree_cnt    <= '0;
            for (int z = 0; z < Z; z++) begin
                acc_min1[z]    <= '1;
                acc_min2[z]    <= '1;
                acc_argmin1[z] <= '0;
            end
        end else if (shifted_valid) begin
            if (shifted_first_col) begin
                // Reset accumulators, load first column
                degree_cnt    <= 5'd1;
                acc_sign_prod <= cur_signs;
                for (int z = 0; z < Z; z++) begin
                    acc_min1[z]    <= cur_mags[z];
                    acc_min2[z]    <= {MAG_BITS{1'b1}};
                    acc_argmin1[z] <= 5'd0;
                end
                stored_signs[0] <= cur_signs;
            end else begin
                // Accumulate
                degree_cnt    <= degree_cnt + 1'b1;
                acc_sign_prod <= acc_sign_prod ^ cur_signs;
                stored_signs[shifted_col_idx] <= cur_signs;

                for (int z = 0; z < Z; z++) begin
                    if (cur_mags[z] < acc_min1[z]) begin
                        acc_min2[z]    <= acc_min1[z];
                        acc_min1[z]    <= cur_mags[z];
                        acc_argmin1[z] <= shifted_col_idx;
                    end else if (cur_mags[z] < acc_min2[z]) begin
                        acc_min2[z]    <= cur_mags[z];
                    end
                end
            end
        end
    end

    // =========================================================================
    // C2V output generation on last_col
    // =========================================================================
    // After last_col is processed (one cycle after shifted_last_col),
    // we compute c2v for each column that was accumulated.
    // We replay stored signs and produce c2v sequentially.

    typedef enum logic [1:0] {
        S_IDLE,
        S_ACCUMULATE,
        S_OUTPUT
    } state_t;

    state_t state, state_next;
    logic [4:0] out_col_cnt;
    logic [4:0] total_degree;

    // State machine
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            out_col_cnt  <= '0;
            total_degree <= '0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (shifted_valid && shifted_first_col) begin
                        state <= S_ACCUMULATE;
                    end
                end

                S_ACCUMULATE: begin
                    if (shifted_valid && shifted_last_col) begin
                        state        <= S_OUTPUT;
                        out_col_cnt  <= '0;
                        total_degree <= degree_cnt + 1'b1;  // includes the last col being processed now
                    end else if (!shifted_valid) begin
                        state <= S_IDLE;
                    end
                end

                S_OUTPUT: begin
                    if (out_col_cnt == total_degree - 1) begin
                        state <= S_IDLE;
                    end else begin
                        out_col_cnt <= out_col_cnt + 1'b1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // C2V computation
    // For column j:  c2v[z] = alpha * ext_sign * (j==argmin1[z] ? min2[z] : min1[z])
    // ext_sign = sign_product XOR sign[j][z]  (remove this edge's contribution)
    // alpha * x = x - (x >>> 2) = 0.75 * x

    // Intermediate wires for c2v computation
    logic [MAG_BITS-1:0] sel_mag   [0:Z-1];
    logic                ext_sign  [0:Z-1];
    logic [MAG_BITS-1:0] scaled_mag[0:Z-1];
    logic signed [W-1:0] c2v_val   [0:Z-1];

    always_comb begin
        c2v_out   = '0;
        c2v_valid = 1'b0;

        for (int z = 0; z < Z; z++) begin
            // Select min1 or min2
            sel_mag[z] = (out_col_cnt == acc_argmin1[z]) ? acc_min2[z] : acc_min1[z];

            // Alpha scaling: 0.75x = x - (x >> 2)
            scaled_mag[z] = sel_mag[z] - (sel_mag[z] >> 2);

            // Extrinsic sign: sign_product XOR this edge's sign
            ext_sign[z] = acc_sign_prod[z] ^ stored_signs[out_col_cnt][z];

            // Convert to signed value
            if (ext_sign[z])
                c2v_val[z] = -{1'b0, scaled_mag[z]};
            else
                c2v_val[z] = {1'b0, scaled_mag[z]};
        end

        if (state == S_OUTPUT) begin
            c2v_valid = 1'b1;
            for (int z = 0; z < Z; z++)
                c2v_out[z*W +: W] = c2v_val[z];
        end
    end

endmodule
