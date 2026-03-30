// =============================================================================
// ldpc_top.sv — Top-level LDPC decoder integration
// =============================================================================
// Instantiates all sub-modules and wires them together.
// AXI-Stream-like interface for LLR input and decoded bit output.
//
// FSM: IDLE -> LOAD_LLR -> ITERATE -> OUTPUT -> IDLE
//
// Parameters match the 802.11n rate-1/2 code with Z=27.
// =============================================================================

module ldpc_top #(
    parameter int Z        = 27,    // lifting size
    parameter int W        = 6,     // element bit-width (signed 2's complement)
    parameter int MB       = 12,    // number of row blocks (check nodes / Z)
    parameter int NB       = 24,    // number of column blocks (variable nodes / Z)
    parameter int MAX_ITER = 20,    // maximum decoding iterations
    parameter int MAX_DEG  = 20     // maximum check node degree
)(
    input  logic              clk,
    input  logic              rst_n,

    // AXI-Stream slave — LLR input
    input  logic [W-1:0]     s_tdata,
    input  logic              s_tvalid,
    output logic              s_tready,
    input  logic              s_tlast,

    // AXI-Stream master — decoded bit output
    output logic              m_tdata,
    output logic              m_tvalid,
    input  logic              m_tready,
    output logic              m_tlast,

    // Status
    output logic              busy,
    output logic              decode_done,
    output logic              decode_converged,
    output logic [5:0]        decode_iterations
);

    // =========================================================================
    // Local parameters
    // =========================================================================
    localparam int N = NB * Z;   // total variable nodes (648)
    localparam int M = MB * Z;   // total check nodes (324)

    // =========================================================================
    // Top-level FSM
    // =========================================================================
    typedef enum logic [2:0] {
        TOP_IDLE     = 3'd0,
        TOP_LOAD_LLR = 3'd1,
        TOP_ITERATE  = 3'd2,
        TOP_OUTPUT   = 3'd3,
        TOP_DONE     = 3'd4
    } top_state_t;

    top_state_t top_state;

    // =========================================================================
    // LLR input buffer
    // =========================================================================
    logic [W-1:0]           llr_wr_data;
    logic [$clog2(N)-1:0]   llr_wr_addr;
    logic                    llr_wr_en;
    logic [4:0]              llr_rd_col_block;
    logic [W*Z-1:0]         llr_rd_data;
    logic                    llr_frame_ready;

    llr_input_buffer #(
        .N  (N),
        .Z  (Z),
        .W  (W),
        .NB (NB)
    ) u_llr_buf (
        .clk          (clk),
        .rst_n        (rst_n),
        .wr_data      (llr_wr_data),
        .wr_addr      (llr_wr_addr),
        .wr_en        (llr_wr_en),
        .rd_col_block (llr_rd_col_block),
        .rd_data      (llr_rd_data),
        .frame_ready  (llr_frame_ready)
    );

    // =========================================================================
    // Base matrix ROM
    // =========================================================================
    logic [6:0]  rom_row;
    logic [4:0]  rom_col;
    logic [8:0]  rom_shift_val;
    logic        rom_has_edge;

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
    // Iteration controller
    // =========================================================================
    logic        ctrl_start;
    logic        ctrl_syndrome_pass;
    logic [5:0]  ctrl_iter_count;
    logic        ctrl_cnu_enable;
    logic        ctrl_vnu_enable;
    logic        ctrl_syndrome_enable;
    logic        ctrl_done;
    logic        ctrl_converged;
    logic [6:0]  ctrl_current_row;
    logic [4:0]  ctrl_current_col;
    logic        ctrl_first_col;
    logic        ctrl_last_col;
    logic        ctrl_first_row;
    logic        ctrl_last_row;

    iteration_ctrl #(
        .MB       (MB),
        .NB       (NB),
        .MAX_ITER (MAX_ITER)
    ) u_iter_ctrl (
        .clk            (clk),
        .rst_n          (rst_n),
        .start          (ctrl_start),
        .syndrome_pass  (ctrl_syndrome_pass),
        .has_edge       (rom_has_edge),
        .iter_count     (ctrl_iter_count),
        .cnu_enable     (ctrl_cnu_enable),
        .vnu_enable     (ctrl_vnu_enable),
        .syndrome_enable(ctrl_syndrome_enable),
        .done           (ctrl_done),
        .converged      (ctrl_converged),
        .current_row    (ctrl_current_row),
        .current_col    (ctrl_current_col),
        .first_col      (ctrl_first_col),
        .last_col       (ctrl_last_col),
        .first_row      (ctrl_first_row),
        .last_row       (ctrl_last_row)
    );

    // =========================================================================
    // Check Node Unit
    // =========================================================================
    logic [W*Z-1:0] cnu_v2c_in;
    logic [W*Z-1:0] cnu_c2v_out;
    logic            cnu_c2v_valid;

    check_node_unit #(
        .Z       (Z),
        .W       (W),
        .MAX_DEG (MAX_DEG)
    ) u_cnu (
        .clk       (clk),
        .rst_n     (rst_n),
        .v2c_in    (cnu_v2c_in),
        .shift_val (rom_shift_val),
        .first_col (ctrl_first_col),
        .last_col  (ctrl_last_col),
        .in_valid  (ctrl_cnu_enable & rom_has_edge),
        .col_idx   (ctrl_current_col),
        .c2v_out   (cnu_c2v_out),
        .c2v_valid (cnu_c2v_valid)
    );

    // =========================================================================
    // Variable Node Unit
    // =========================================================================
    logic [W*Z-1:0] vnu_c2v_in;
    logic [W*Z-1:0] vnu_v2c_out;
    logic [W*Z-1:0] vnu_posterior_out;
    logic            vnu_valid;

    variable_node_unit #(
        .Z(Z),
        .W(W)
    ) u_vnu (
        .clk          (clk),
        .rst_n        (rst_n),
        .channel_llr  (llr_rd_data),
        .c2v_in       (vnu_c2v_in),
        .first_check  (ctrl_first_row),
        .in_valid     (ctrl_vnu_enable & rom_has_edge),
        .v2c_out      (vnu_v2c_out),
        .posterior_out(vnu_posterior_out),
        .valid        (vnu_valid)
    );

    // =========================================================================
    // V2C message RAM (stores v2c messages for CNU to read)
    // Organized: NB column blocks, each stores the v2c messages
    // For simplicity we use a flat RAM addressed by (col_block * Z + z_idx)
    // Actually we need edge-based storage. Simplified: we store per VN block.
    // =========================================================================
    // TODO(high): v2c/c2v memories are sized per-node (N and M entries) but a
    // flooding decoder needs per-edge storage (num_edges >> N,M). For the 802.11n
    // code, there are 2376 edges vs 648+324 nodes. Current design loses multi-edge
    // messages when multiple check nodes connect to the same variable node.
    // Fix: size by total edges, or restructure as (row_block x col_block x Z).
    // Also: use registered reads (not combinational) so synthesis infers BRAM.
    // V2C storage: NB blocks of Z elements, each W bits
    logic [W-1:0] v2c_mem [0:N-1];

    // Write v2c from VNU output
    logic [4:0] vnu_wr_col;
    logic       vnu_wr_en;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < N; i++)
                v2c_mem[i] <= '0;
        end else if (vnu_wr_en) begin
            for (int z = 0; z < Z; z++)
                v2c_mem[vnu_wr_col * Z + z] <= vnu_v2c_out[z*W +: W];
        end
    end

    // Read v2c for CNU: pack Z elements
    always_comb begin
        for (int z = 0; z < Z; z++)
            cnu_v2c_in[z*W +: W] = v2c_mem[ctrl_current_col * Z + z];
    end

    // =========================================================================
    // C2V message RAM (stores c2v messages for VNU to read)
    // For simplicity, flat storage indexed by edge.
    // We use (row_block * Z + z_idx) addressing.
    // =========================================================================
    logic [W-1:0] c2v_mem [0:M-1];

    logic [6:0] cnu_wr_row;
    logic       cnu_wr_en;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < M; i++)
                c2v_mem[i] <= '0;
        end else if (cnu_wr_en) begin
            for (int z = 0; z < Z; z++)
                c2v_mem[cnu_wr_row * Z + z] <= cnu_c2v_out[z*W +: W];
        end
    end

    // Read c2v for VNU: pack Z elements
    always_comb begin
        for (int z = 0; z < Z; z++)
            vnu_c2v_in[z*W +: W] = c2v_mem[ctrl_current_row * Z + z];
    end

    // =========================================================================
    // Syndrome checker
    // =========================================================================
    logic [Z-1:0] syndrome_hard_bits;
    logic         syndrome_all_pass;
    logic         syndrome_valid;

    // Hard decision from posterior: bit = (posterior < 0) ? 1 : 0
    // We use the latest posterior from VNU
    // Store posterior for syndrome check
    logic [W-1:0] posterior_mem [0:N-1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < N; i++)
                posterior_mem[i] <= '0;
        end else if (vnu_valid) begin
            for (int z = 0; z < Z; z++)
                posterior_mem[ctrl_current_col * Z + z] <= vnu_posterior_out[z*W +: W];
        end
    end

    // Pack hard bits for syndrome checker: sign bit = hard decision
    always_comb begin
        for (int z = 0; z < Z; z++) begin
            syndrome_hard_bits[z] = posterior_mem[ctrl_current_col * Z + z][W-1];
        end
    end

    syndrome_checker #(
        .Z  (Z),
        .MB (MB)
    ) u_syndrome (
        .clk             (clk),
        .rst_n           (rst_n),
        .hard_bits_block (syndrome_hard_bits),
        .shift_val       (rom_shift_val),
        .has_edge        (rom_has_edge),
        .first_col       (ctrl_first_col),
        .last_col        (ctrl_last_col),
        .last_row        (ctrl_last_row),
        .in_valid        (ctrl_syndrome_enable),
        .all_checks_pass (syndrome_all_pass),
        .valid           (syndrome_valid)
    );

    assign ctrl_syndrome_pass = syndrome_all_pass & syndrome_valid;

    // =========================================================================
    // Output buffer
    // =========================================================================
    logic [Z-1:0]           out_decoded_block;
    logic [4:0]             out_col_addr;
    logic                   out_write_en;
    logic                   out_frame_done;
    logic [$clog2(N)-1:0]   out_rd_addr;
    logic                   out_rd_data;
    logic                   out_output_valid;

    output_buffer #(
        .N  (N),
        .Z  (Z),
        .NB (NB)
    ) u_out_buf (
        .clk          (clk),
        .rst_n        (rst_n),
        .decoded_block(out_decoded_block),
        .col_addr     (out_col_addr),
        .write_en     (out_write_en),
        .frame_done   (out_frame_done),
        .rd_addr      (out_rd_addr),
        .rd_data      (out_rd_data),
        .output_valid (out_output_valid)
    );

    // =========================================================================
    // ROM address mux — controller drives row/col
    // =========================================================================
    assign rom_row = ctrl_current_row;
    assign rom_col = ctrl_current_col;

    // LLR read address from controller
    assign llr_rd_col_block = ctrl_current_col;

    // =========================================================================
    // Top-level FSM
    // =========================================================================
    logic [$clog2(N)-1:0] llr_load_addr;
    logic [$clog2(N)-1:0] output_addr;
    logic [4:0]           output_col;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            top_state       <= TOP_IDLE;
            llr_load_addr   <= '0;
            output_addr     <= '0;
            output_col      <= '0;
            ctrl_start      <= 1'b0;
            llr_wr_en       <= 1'b0;
            out_write_en    <= 1'b0;
            out_frame_done  <= 1'b0;
            vnu_wr_en       <= 1'b0;
            vnu_wr_col      <= '0;
            cnu_wr_en       <= 1'b0;
            cnu_wr_row      <= '0;
        end else begin
            // Defaults
            ctrl_start     <= 1'b0;
            llr_wr_en      <= 1'b0;
            out_write_en   <= 1'b0;
            out_frame_done <= 1'b0;
            vnu_wr_en      <= 1'b0;
            cnu_wr_en      <= 1'b0;

            case (top_state)
                TOP_IDLE: begin
                    if (s_tvalid) begin
                        top_state     <= TOP_LOAD_LLR;
                        llr_load_addr <= '0;
                    end
                end

                TOP_LOAD_LLR: begin
                    if (s_tvalid) begin
                        llr_wr_data <= s_tdata;
                        llr_wr_addr <= llr_load_addr;
                        llr_wr_en   <= 1'b1;

                        if (s_tlast || llr_load_addr == N - 1) begin
                            top_state  <= TOP_ITERATE;
                            ctrl_start <= 1'b1;
                        end else begin
                            llr_load_addr <= llr_load_addr + 1'b1;
                        end
                    end
                end

                TOP_ITERATE: begin
                    // Forward CNU outputs to c2v memory
                    if (cnu_c2v_valid) begin
                        cnu_wr_en  <= 1'b1;
                        cnu_wr_row <= ctrl_current_row;
                    end

                    // Forward VNU outputs to v2c memory
                    if (vnu_valid) begin
                        vnu_wr_en  <= 1'b1;
                        vnu_wr_col <= ctrl_current_col;
                    end

                    if (ctrl_done) begin
                        top_state   <= TOP_OUTPUT;
                        output_col  <= '0;
                        output_addr <= '0;
                    end
                end

                TOP_OUTPUT: begin
                    // Write decoded bits from posterior to output buffer
                    // Hard decision: sign bit of posterior
                    for (int z = 0; z < Z; z++) begin
                        out_decoded_block[z] <= posterior_mem[output_col * Z + z][W-1];
                    end
                    out_col_addr <= output_col;
                    out_write_en <= 1'b1;

                    if (output_col == NB - 1) begin
                        out_frame_done <= 1'b1;
                        top_state      <= TOP_DONE;
                    end else begin
                        output_col <= output_col + 1'b1;
                    end
                end

                TOP_DONE: begin
                    // Output bits via AXI-Stream master
                    if (m_tready && out_output_valid) begin
                        output_addr <= output_addr + 1'b1;
                        if (output_addr == N - 1) begin
                            top_state   <= TOP_IDLE;
                            output_addr <= '0;
                        end
                    end
                end

                default: top_state <= TOP_IDLE;
            endcase
        end
    end

    // =========================================================================
    // AXI-Stream signals
    // =========================================================================
    assign s_tready = (top_state == TOP_LOAD_LLR) || (top_state == TOP_IDLE);
    assign busy     = (top_state != TOP_IDLE);

    assign out_rd_addr = output_addr;
    assign m_tdata     = out_rd_data;
    assign m_tvalid    = (top_state == TOP_DONE) && out_output_valid;
    assign m_tlast     = (top_state == TOP_DONE) && (output_addr == N - 1);

    assign decode_done       = ctrl_done;
    assign decode_converged  = ctrl_converged;
    assign decode_iterations = ctrl_iter_count;

endmodule
