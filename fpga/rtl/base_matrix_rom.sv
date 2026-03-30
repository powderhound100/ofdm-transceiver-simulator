// =============================================================================
// base_matrix_rom.sv — Shift value ROM for 802.11n rate-1/2 LDPC code
// =============================================================================
// Base matrix: 12 rows x 24 columns, Z=27
// Entry values 0..26 are shift amounts; -1 means no edge (stored as 9'h1FF).
//
// This is the 802.11n rate-1/2 code with Z=27.
//
// Latency: 1 cycle (registered ROM output)
// =============================================================================

module base_matrix_rom #(
    parameter int MB = 12,   // number of row blocks
    parameter int NB = 24    // number of column blocks
)(
    input  logic              clk,
    input  logic              rst_n,
    input  logic [6:0]        row_block,   // 0..MB-1
    input  logic [4:0]        col_block,   // 0..NB-1
    output logic [8:0]        shift_val,   // 0..Z-1 or 9'h1FF for no edge
    output logic              has_edge     // 1 if entry >= 0
);

    // No-edge sentinel
    localparam logic [8:0] NO_EDGE = 9'h1FF;

    // Base matrix storage: MB x NB
    // 802.11n rate-1/2, Z=27
    logic [8:0] bm [0:MB-1][0:NB-1];

    // Initialize base matrix
    initial begin
        // Row 0:  [0, -1, -1, -1, 0, 0, -1, -1, 0, -1, -1, 0, 1, 0, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1]
        bm[0][0]  = 9'd0;   bm[0][1]  = NO_EDGE; bm[0][2]  = NO_EDGE; bm[0][3]  = NO_EDGE;
        bm[0][4]  = 9'd0;   bm[0][5]  = 9'd0;    bm[0][6]  = NO_EDGE; bm[0][7]  = NO_EDGE;
        bm[0][8]  = 9'd0;   bm[0][9]  = NO_EDGE; bm[0][10] = NO_EDGE; bm[0][11] = 9'd0;
        bm[0][12] = 9'd1;   bm[0][13] = 9'd0;    bm[0][14] = NO_EDGE; bm[0][15] = NO_EDGE;
        bm[0][16] = NO_EDGE; bm[0][17] = NO_EDGE; bm[0][18] = NO_EDGE; bm[0][19] = NO_EDGE;
        bm[0][20] = NO_EDGE; bm[0][21] = NO_EDGE; bm[0][22] = NO_EDGE; bm[0][23] = NO_EDGE;

        // Row 1:  [22, 0, -1, -1, 17, -1, 0, 0, 12, -1, -1, -1, -1, 0, 0, -1, -1, -1, -1, -1, -1, -1, -1, -1]
        bm[1][0]  = 9'd22;  bm[1][1]  = 9'd0;    bm[1][2]  = NO_EDGE; bm[1][3]  = NO_EDGE;
        bm[1][4]  = 9'd17;  bm[1][5]  = NO_EDGE; bm[1][6]  = 9'd0;    bm[1][7]  = 9'd0;
        bm[1][8]  = 9'd12;  bm[1][9]  = NO_EDGE; bm[1][10] = NO_EDGE; bm[1][11] = NO_EDGE;
        bm[1][12] = NO_EDGE; bm[1][13] = 9'd0;   bm[1][14] = 9'd0;    bm[1][15] = NO_EDGE;
        bm[1][16] = NO_EDGE; bm[1][17] = NO_EDGE; bm[1][18] = NO_EDGE; bm[1][19] = NO_EDGE;
        bm[1][20] = NO_EDGE; bm[1][21] = NO_EDGE; bm[1][22] = NO_EDGE; bm[1][23] = NO_EDGE;

        // Row 2:  [6, -1, 0, -1, 10, -1, -1, -1, 24, -1, 0, -1, -1, -1, 0, 0, -1, -1, -1, -1, -1, -1, -1, -1]
        bm[2][0]  = 9'd6;   bm[2][1]  = NO_EDGE; bm[2][2]  = 9'd0;    bm[2][3]  = NO_EDGE;
        bm[2][4]  = 9'd10;  bm[2][5]  = NO_EDGE; bm[2][6]  = NO_EDGE; bm[2][7]  = NO_EDGE;
        bm[2][8]  = 9'd24;  bm[2][9]  = NO_EDGE; bm[2][10] = 9'd0;    bm[2][11] = NO_EDGE;
        bm[2][12] = NO_EDGE; bm[2][13] = NO_EDGE; bm[2][14] = 9'd0;   bm[2][15] = 9'd0;
        bm[2][16] = NO_EDGE; bm[2][17] = NO_EDGE; bm[2][18] = NO_EDGE; bm[2][19] = NO_EDGE;
        bm[2][20] = NO_EDGE; bm[2][21] = NO_EDGE; bm[2][22] = NO_EDGE; bm[2][23] = NO_EDGE;

        // Row 3:  [2, -1, -1, 0, 20, -1, -1, -1, 25, 0, -1, -1, -1, -1, -1, 0, 0, -1, -1, -1, -1, -1, -1, -1]
        bm[3][0]  = 9'd2;   bm[3][1]  = NO_EDGE; bm[3][2]  = NO_EDGE; bm[3][3]  = 9'd0;
        bm[3][4]  = 9'd20;  bm[3][5]  = NO_EDGE; bm[3][6]  = NO_EDGE; bm[3][7]  = NO_EDGE;
        bm[3][8]  = 9'd25;  bm[3][9]  = 9'd0;    bm[3][10] = NO_EDGE; bm[3][11] = NO_EDGE;
        bm[3][12] = NO_EDGE; bm[3][13] = NO_EDGE; bm[3][14] = NO_EDGE; bm[3][15] = 9'd0;
        bm[3][16] = 9'd0;   bm[3][17] = NO_EDGE; bm[3][18] = NO_EDGE; bm[3][19] = NO_EDGE;
        bm[3][20] = NO_EDGE; bm[3][21] = NO_EDGE; bm[3][22] = NO_EDGE; bm[3][23] = NO_EDGE;

        // Row 4:  [23, -1, -1, -1, 3, -1, -1, -1, 0, -1, 9, 11, -1, -1, -1, -1, 0, 0, -1, -1, -1, -1, -1, -1]
        bm[4][0]  = 9'd23;  bm[4][1]  = NO_EDGE; bm[4][2]  = NO_EDGE; bm[4][3]  = NO_EDGE;
        bm[4][4]  = 9'd3;   bm[4][5]  = NO_EDGE; bm[4][6]  = NO_EDGE; bm[4][7]  = NO_EDGE;
        bm[4][8]  = 9'd0;   bm[4][9]  = NO_EDGE; bm[4][10] = 9'd9;    bm[4][11] = 9'd11;
        bm[4][12] = NO_EDGE; bm[4][13] = NO_EDGE; bm[4][14] = NO_EDGE; bm[4][15] = NO_EDGE;
        bm[4][16] = 9'd0;   bm[4][17] = 9'd0;    bm[4][18] = NO_EDGE; bm[4][19] = NO_EDGE;
        bm[4][20] = NO_EDGE; bm[4][21] = NO_EDGE; bm[4][22] = NO_EDGE; bm[4][23] = NO_EDGE;

        // Row 5:  [24, -1, 23, 1, 17, -1, 3, -1, 10, -1, -1, -1, -1, -1, -1, -1, -1, 0, 0, -1, -1, -1, -1, -1]
        bm[5][0]  = 9'd24;  bm[5][1]  = NO_EDGE; bm[5][2]  = 9'd23;   bm[5][3]  = 9'd1;
        bm[5][4]  = 9'd17;  bm[5][5]  = NO_EDGE; bm[5][6]  = 9'd3;    bm[5][7]  = NO_EDGE;
        bm[5][8]  = 9'd10;  bm[5][9]  = NO_EDGE; bm[5][10] = NO_EDGE; bm[5][11] = NO_EDGE;
        bm[5][12] = NO_EDGE; bm[5][13] = NO_EDGE; bm[5][14] = NO_EDGE; bm[5][15] = NO_EDGE;
        bm[5][16] = NO_EDGE; bm[5][17] = 9'd0;   bm[5][18] = 9'd0;    bm[5][19] = NO_EDGE;
        bm[5][20] = NO_EDGE; bm[5][21] = NO_EDGE; bm[5][22] = NO_EDGE; bm[5][23] = NO_EDGE;

        // Row 6:  [25, -1, -1, -1, 8, -1, -1, -1, 7, 18, -1, -1, 0, -1, -1, -1, -1, -1, 0, 0, -1, -1, -1, -1]
        bm[6][0]  = 9'd25;  bm[6][1]  = NO_EDGE; bm[6][2]  = NO_EDGE; bm[6][3]  = NO_EDGE;
        bm[6][4]  = 9'd8;   bm[6][5]  = NO_EDGE; bm[6][6]  = NO_EDGE; bm[6][7]  = NO_EDGE;
        bm[6][8]  = 9'd7;   bm[6][9]  = 9'd18;   bm[6][10] = NO_EDGE; bm[6][11] = NO_EDGE;
        bm[6][12] = 9'd0;   bm[6][13] = NO_EDGE; bm[6][14] = NO_EDGE; bm[6][15] = NO_EDGE;
        bm[6][16] = NO_EDGE; bm[6][17] = NO_EDGE; bm[6][18] = 9'd0;   bm[6][19] = 9'd0;
        bm[6][20] = NO_EDGE; bm[6][21] = NO_EDGE; bm[6][22] = NO_EDGE; bm[6][23] = NO_EDGE;

        // Row 7:  [13, 24, -1, -1, 0, -1, 8, -1, 6, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, 0, 0, -1, -1, -1]
        bm[7][0]  = 9'd13;  bm[7][1]  = 9'd24;   bm[7][2]  = NO_EDGE; bm[7][3]  = NO_EDGE;
        bm[7][4]  = 9'd0;   bm[7][5]  = NO_EDGE; bm[7][6]  = 9'd8;    bm[7][7]  = NO_EDGE;
        bm[7][8]  = 9'd6;   bm[7][9]  = NO_EDGE; bm[7][10] = NO_EDGE; bm[7][11] = NO_EDGE;
        bm[7][12] = NO_EDGE; bm[7][13] = NO_EDGE; bm[7][14] = NO_EDGE; bm[7][15] = NO_EDGE;
        bm[7][16] = NO_EDGE; bm[7][17] = NO_EDGE; bm[7][18] = NO_EDGE; bm[7][19] = 9'd0;
        bm[7][20] = 9'd0;   bm[7][21] = NO_EDGE; bm[7][22] = NO_EDGE; bm[7][23] = NO_EDGE;

        // Row 8:  [7, 20, -1, 16, 22, 10, -1, -1, 23, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, 0, 0, -1, -1]
        bm[8][0]  = 9'd7;   bm[8][1]  = 9'd20;   bm[8][2]  = NO_EDGE; bm[8][3]  = 9'd16;
        bm[8][4]  = 9'd22;  bm[8][5]  = 9'd10;   bm[8][6]  = NO_EDGE; bm[8][7]  = NO_EDGE;
        bm[8][8]  = 9'd23;  bm[8][9]  = NO_EDGE; bm[8][10] = NO_EDGE; bm[8][11] = NO_EDGE;
        bm[8][12] = NO_EDGE; bm[8][13] = NO_EDGE; bm[8][14] = NO_EDGE; bm[8][15] = NO_EDGE;
        bm[8][16] = NO_EDGE; bm[8][17] = NO_EDGE; bm[8][18] = NO_EDGE; bm[8][19] = NO_EDGE;
        bm[8][20] = 9'd0;   bm[8][21] = 9'd0;    bm[8][22] = NO_EDGE; bm[8][23] = NO_EDGE;

        // Row 9:  [11, -1, -1, -1, 19, -1, -1, -1, 13, -1, 3, 17, -1, -1, -1, -1, -1, -1, -1, -1, -1, 0, 0, -1]
        bm[9][0]  = 9'd11;  bm[9][1]  = NO_EDGE; bm[9][2]  = NO_EDGE; bm[9][3]  = NO_EDGE;
        bm[9][4]  = 9'd19;  bm[9][5]  = NO_EDGE; bm[9][6]  = NO_EDGE; bm[9][7]  = NO_EDGE;
        bm[9][8]  = 9'd13;  bm[9][9]  = NO_EDGE; bm[9][10] = 9'd3;    bm[9][11] = 9'd17;
        bm[9][12] = NO_EDGE; bm[9][13] = NO_EDGE; bm[9][14] = NO_EDGE; bm[9][15] = NO_EDGE;
        bm[9][16] = NO_EDGE; bm[9][17] = NO_EDGE; bm[9][18] = NO_EDGE; bm[9][19] = NO_EDGE;
        bm[9][20] = NO_EDGE; bm[9][21] = 9'd0;   bm[9][22] = 9'd0;    bm[9][23] = NO_EDGE;

        // Row 10: [25, -1, 8, -1, 23, 18, -1, 14, 9, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, 0, 0]
        bm[10][0]  = 9'd25;  bm[10][1]  = NO_EDGE; bm[10][2]  = 9'd8;    bm[10][3]  = NO_EDGE;
        bm[10][4]  = 9'd23;  bm[10][5]  = 9'd18;   bm[10][6]  = NO_EDGE; bm[10][7]  = 9'd14;
        bm[10][8]  = 9'd9;   bm[10][9]  = NO_EDGE; bm[10][10] = NO_EDGE; bm[10][11] = NO_EDGE;
        bm[10][12] = NO_EDGE; bm[10][13] = NO_EDGE; bm[10][14] = NO_EDGE; bm[10][15] = NO_EDGE;
        bm[10][16] = NO_EDGE; bm[10][17] = NO_EDGE; bm[10][18] = NO_EDGE; bm[10][19] = NO_EDGE;
        bm[10][20] = NO_EDGE; bm[10][21] = NO_EDGE; bm[10][22] = 9'd0;   bm[10][23] = 9'd0;

        // Row 11: [3, -1, -1, -1, 16, -1, -1, 2, 25, 5, -1, -1, 1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, 0]
        bm[11][0]  = 9'd3;   bm[11][1]  = NO_EDGE; bm[11][2]  = NO_EDGE; bm[11][3]  = NO_EDGE;
        bm[11][4]  = 9'd16;  bm[11][5]  = NO_EDGE; bm[11][6]  = NO_EDGE; bm[11][7]  = 9'd2;
        bm[11][8]  = 9'd25;  bm[11][9]  = 9'd5;    bm[11][10] = NO_EDGE; bm[11][11] = NO_EDGE;
        bm[11][12] = 9'd1;   bm[11][13] = NO_EDGE; bm[11][14] = NO_EDGE; bm[11][15] = NO_EDGE;
        bm[11][16] = NO_EDGE; bm[11][17] = NO_EDGE; bm[11][18] = NO_EDGE; bm[11][19] = NO_EDGE;
        bm[11][20] = NO_EDGE; bm[11][21] = NO_EDGE; bm[11][22] = NO_EDGE; bm[11][23] = 9'd0;
    end

    // Registered ROM output
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shift_val <= NO_EDGE;
            has_edge  <= 1'b0;
        end else begin
            shift_val <= bm[row_block][col_block];
            has_edge  <= (bm[row_block][col_block] != NO_EDGE);
        end
    end

endmodule
