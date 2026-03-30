// =============================================================================
// variable_node_unit.sv — Variable Node Unit (VNU)
// =============================================================================
// Accumulates c2v messages for each variable node, then computes:
//   posterior    = channel_llr + sum(c2v)
//   v2c_out      = posterior - c2v_in   (extrinsic message)
//
// All arithmetic saturates to [-31, +31] (6-bit signed, magnitude max 31).
//
// Latency: 1 cycle
// =============================================================================

module variable_node_unit #(
    parameter int Z = 27,   // lifting size
    parameter int W = 6     // element bit-width (signed)
)(
    input  logic              clk,
    input  logic              rst_n,

    input  logic [W*Z-1:0]   channel_llr,    // Z channel LLR values for this variable block
    input  logic [W*Z-1:0]   c2v_in,         // Z c2v messages from one check node
    input  logic              first_check,    // reset accumulator (first c2v for this variable block)
    input  logic              in_valid,       // input valid

    output logic [W*Z-1:0]   v2c_out,        // Z extrinsic v2c = posterior - c2v_in
    output logic [W*Z-1:0]   posterior_out,   // Z posterior values (for hard decision)
    output logic              valid
);

    localparam int SAT_MAX =  31;
    localparam int SAT_MIN = -31;

    // Accumulator for sum of c2v messages (wider to avoid overflow)
    logic signed [W+3:0] acc [0:Z-1];

    // Pipeline registers for inputs
    logic [W*Z-1:0] c2v_in_r;
    logic [W*Z-1:0] channel_llr_r;
    logic            first_check_r;
    logic            valid_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_r       <= 1'b0;
            first_check_r <= 1'b0;
            c2v_in_r      <= '0;
            channel_llr_r <= '0;
        end else begin
            valid_r       <= in_valid;
            first_check_r <= first_check;
            c2v_in_r      <= c2v_in;
            channel_llr_r <= channel_llr;
        end
    end

    // Combinational: compute new_acc, posterior, v2c for each Z element
    logic signed [W+3:0] new_acc_comb  [0:Z-1];
    logic signed [W+3:0] posterior_comb[0:Z-1];
    logic signed [W+3:0] v2c_comb      [0:Z-1];
    logic signed [W-1:0] ch_llr_arr    [0:Z-1];
    logic signed [W-1:0] c2v_val_arr   [0:Z-1];

    always_comb begin
        for (int z = 0; z < Z; z++) begin
            ch_llr_arr[z]  = channel_llr_r[z*W +: W];
            c2v_val_arr[z] = c2v_in_r[z*W +: W];

            if (first_check_r)
                new_acc_comb[z] = {{4{c2v_val_arr[z][W-1]}}, c2v_val_arr[z]};
            else
                new_acc_comb[z] = acc[z] + {{4{c2v_val_arr[z][W-1]}}, c2v_val_arr[z]};

            posterior_comb[z] = {{4{ch_llr_arr[z][W-1]}}, ch_llr_arr[z]} + new_acc_comb[z];
            v2c_comb[z]       = posterior_comb[z] - {{4{c2v_val_arr[z][W-1]}}, c2v_val_arr[z]};
        end
    end

    // Saturate to W-bit signed range [-31, +31]
    function automatic logic signed [W-1:0] saturate(input logic signed [W+3:0] val);
        if (val > SAT_MAX)
            return 6'sd31;
        else if (val < SAT_MIN)
            return -6'sd31;
        else
            return val[W-1:0];
    endfunction

    // Registered outputs
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int z = 0; z < Z; z++)
                acc[z] <= '0;
            v2c_out       <= '0;
            posterior_out  <= '0;
            valid          <= 1'b0;
        end else begin
            valid <= valid_r;
            if (valid_r) begin
                for (int z = 0; z < Z; z++) begin
                    acc[z] <= new_acc_comb[z];
                    posterior_out[z*W +: W] <= saturate(posterior_comb[z]);
                    v2c_out[z*W +: W]      <= saturate(v2c_comb[z]);
                end
            end
        end
    end

endmodule
