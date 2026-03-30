// =============================================================================
// min2_finder.sv — Find min1, min2, and argmin1
// =============================================================================
// Given a packed vector of unsigned magnitudes, finds:
//   min1_val  : smallest magnitude among mags_in[0:degree-1]
//   min2_val  : second smallest magnitude
//   argmin1   : index of the smallest magnitude
//
// Pipelined comparator tree. Latency: 2 cycles.
// =============================================================================

module min2_finder #(
    parameter int WIDTH    = 20,  // max check node degree
    parameter int MAG_BITS = 5    // magnitude bits (unsigned, 0..31)
)(
    input  logic                       clk,
    input  logic                       rst_n,
    input  logic [MAG_BITS*WIDTH-1:0]  mags_in,    // packed magnitudes
    input  logic [4:0]                 degree,      // actual valid inputs
    input  logic                       in_valid,    // input valid strobe
    output logic [MAG_BITS-1:0]        min1_val,    // smallest magnitude
    output logic [MAG_BITS-1:0]        min2_val,    // second smallest
    output logic [4:0]                 argmin1,     // index of min1
    output logic                       valid        // output valid strobe
);

    // =========================================================================
    // Stage 1: scan first half of inputs (0..WIDTH/2-1), find partial min1/min2
    // =========================================================================
    localparam int HALF = WIDTH / 2;

    // Unpack mags for convenience (combinational)
    logic [MAG_BITS-1:0] mag [0:WIDTH-1];
    always_comb begin
        for (int i = 0; i < WIDTH; i++) begin
            mag[i] = mags_in[i*MAG_BITS +: MAG_BITS];
        end
    end

    // Stage 1 combinational: scan first half
    logic [MAG_BITS-1:0] s1_min1_comb, s1_min2_comb;
    logic [4:0]          s1_argmin1_comb;

    always_comb begin
        s1_min1_comb    = {MAG_BITS{1'b1}};
        s1_min2_comb    = {MAG_BITS{1'b1}};
        s1_argmin1_comb = '0;

        for (int i = 0; i < HALF; i++) begin
            if (i[4:0] < degree) begin
                if (mag[i] < s1_min1_comb) begin
                    s1_min2_comb    = s1_min1_comb;
                    s1_min1_comb    = mag[i];
                    s1_argmin1_comb = i[4:0];
                end else if (mag[i] < s1_min2_comb) begin
                    s1_min2_comb = mag[i];
                end
            end
        end
    end

    // Stage 1 pipeline registers
    logic [MAG_BITS-1:0] s1_min1, s1_min2;
    logic [4:0]          s1_argmin1;
    logic [4:0]          s1_degree;
    logic                s1_valid;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_min1    <= '1;
            s1_min2    <= '1;
            s1_argmin1 <= '0;
            s1_degree  <= '0;
            s1_valid   <= 1'b0;
        end else begin
            s1_valid   <= in_valid;
            s1_min1    <= s1_min1_comb;
            s1_min2    <= s1_min2_comb;
            s1_argmin1 <= s1_argmin1_comb;
            s1_degree  <= degree;
        end
    end

    // Mags pipeline for second half access in stage 2
    logic [MAG_BITS*WIDTH-1:0] mags_pipe;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            mags_pipe <= '0;
        else
            mags_pipe <= mags_in;
    end

    logic [MAG_BITS-1:0] mag_p [0:WIDTH-1];
    always_comb begin
        for (int i = 0; i < WIDTH; i++)
            mag_p[i] = mags_pipe[i*MAG_BITS +: MAG_BITS];
    end

    // =========================================================================
    // Stage 2: scan second half (HALF..WIDTH-1), merge with stage 1 results
    // =========================================================================
    logic [MAG_BITS-1:0] s2_min1_comb, s2_min2_comb;
    logic [4:0]          s2_argmin1_comb;

    always_comb begin
        s2_min1_comb    = s1_min1;
        s2_min2_comb    = s1_min2;
        s2_argmin1_comb = s1_argmin1;

        for (int i = HALF; i < WIDTH; i++) begin
            if (i[4:0] < s1_degree) begin
                if (mag_p[i] < s2_min1_comb) begin
                    s2_min2_comb    = s2_min1_comb;
                    s2_min1_comb    = mag_p[i];
                    s2_argmin1_comb = i[4:0];
                end else if (mag_p[i] < s2_min2_comb) begin
                    s2_min2_comb = mag_p[i];
                end
            end
        end
    end

    // Stage 2 output registers
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            min1_val <= '0;
            min2_val <= '0;
            argmin1  <= '0;
            valid    <= 1'b0;
        end else begin
            valid    <= s1_valid;
            min1_val <= s2_min1_comb;
            min2_val <= s2_min2_comb;
            argmin1  <= s2_argmin1_comb;
        end
    end

endmodule
