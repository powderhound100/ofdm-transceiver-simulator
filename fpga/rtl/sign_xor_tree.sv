// =============================================================================
// sign_xor_tree.sv — Sign product computation for CNU
// =============================================================================
// Computes XOR of signs_in[0 : degree-1].
// The sign product tells the CNU whether the outgoing c2v should be negated.
//
// Latency: 1 cycle (combinational XOR tree + output register)
// =============================================================================

module sign_xor_tree #(
    parameter int WIDTH = 20   // max check node degree
)(
    input  logic              clk,
    input  logic              rst_n,
    input  logic [WIDTH-1:0]  signs_in,   // sign bits (1 = negative)
    input  logic [4:0]        degree,     // actual degree (use signs_in[0:degree-1])
    output logic              xor_out     // XOR of active sign bits
);

    // Combinational: masked XOR
    logic xor_comb;
    logic [WIDTH-1:0] masked;

    always_comb begin
        masked = '0;
        for (int i = 0; i < WIDTH; i++) begin
            if (i < degree)
                masked[i] = signs_in[i];
            else
                masked[i] = 1'b0;
        end
        xor_comb = ^masked;  // reduction XOR of masked bits
    end

    // Registered output
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            xor_out <= 1'b0;
        else
            xor_out <= xor_comb;
    end

endmodule
