// =============================================================================
// fft_64pt.sv — 64-point Radix-2 Single-path Delay Feedback (SDF) FFT
// =============================================================================
// 6-stage SDF pipeline for N=64.
//
// Each stage s (0..5):
//   - Delay line depth: 2^(5-s) = {32, 16, 8, 4, 2, 1}
//   - When counter bit [5-s] == 0: store input in delay, pass delayed sample
//   - When counter bit [5-s] == 1: butterfly(delayed, input), twiddle multiply B
//
// Input ordering is bit-reversed so output is in natural order.
// Throughput: 1 sample/clock.
// Latency: ~FFT_N + pipeline register delays.
//
// Bit growth: +1 bit per stage (6 stages), truncated back to W_OUT with
// rounding after each butterfly.
//
// TIMING FIX: Each stage uses a per-stage counter (stg_cnt) that increments
// on stg_valid[s], ensuring the sel/twiddle/wr_ptr signals are aligned with
// the data actually flowing through that stage.  The multiply pipeline adds
// 2 register stages per SDF stage, so a global counter would be misaligned
// by 2*s cycles at stage s.
// =============================================================================
`timescale 1ns / 1ps

module fft_64pt #(
    parameter integer FFT_N = 64,
    parameter integer W_IN  = 16,
    parameter integer W_OUT = 16,
    parameter integer TW    = 12
)(
    input  wire                     clk,
    input  wire                     rst_n,

    // Input stream
    input  wire signed [W_IN-1:0]  s_re,
    input  wire signed [W_IN-1:0]  s_im,
    input  wire                     s_valid,

    // Output stream
    output wire signed [W_OUT-1:0] m_re,
    output wire signed [W_OUT-1:0] m_im,
    output wire                     m_valid,
    output wire                     m_last
);

    // =========================================================================
    // Global sample counter (0..63) — kept for bit-reverse addressing only
    // =========================================================================
    reg [5:0] sample_cnt;
    reg       cnt_active;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_cnt <= 6'd0;
            cnt_active <= 1'b0;
        end else if (s_valid) begin
            sample_cnt <= sample_cnt + 6'd1;
            cnt_active <= 1'b1;
        end
    end

    // =========================================================================
    // Bit-reverse the input counter so we feed samples in bit-reversed order
    // =========================================================================
    wire [5:0] br_cnt = {sample_cnt[0], sample_cnt[1], sample_cnt[2],
                         sample_cnt[3], sample_cnt[4], sample_cnt[5]};

    // =========================================================================
    // Internal data width: W_IN + 6 bits growth (one per stage), but we
    // truncate after each stage to keep width manageable.
    // We use W_IN throughout and saturate/round at each stage.
    // =========================================================================
    localparam integer WD = W_IN;  // internal data width per stage

    // =========================================================================
    // Inter-stage wires
    // =========================================================================
    wire signed [WD-1:0] stg_re [0:6];
    wire signed [WD-1:0] stg_im [0:6];
    wire                  stg_valid [0:6];

    assign stg_re[0]    = s_re;
    assign stg_im[0]    = s_im;
    assign stg_valid[0] = s_valid;

    // =========================================================================
    // Generate 6 SDF stages
    // =========================================================================
    genvar s;
    generate
        for (s = 0; s < 6; s = s + 1) begin : sdf_stage

            localparam integer DELAY_DEPTH = (1 << (5 - s));  // 32, 16, 8, 4, 2, 1
            localparam integer BIT_SEL     = 5 - s;           // counter bit to check

            // =================================================================
            // Per-stage counter: increments on stg_valid[s] so it is
            // naturally aligned with data arriving at this stage.
            // Stage 0 sees stg_valid[0] = s_valid  -> same as sample_cnt.
            // Stage 1 sees stg_valid[1] which fires 2 cycles later, etc.
            // =================================================================
            reg [5:0] stg_cnt;

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n)
                    stg_cnt <= 6'd0;
                else if (stg_valid[s])
                    stg_cnt <= stg_cnt + 6'd1;
            end

            // Delay line memory (shift register)
            reg signed [WD-1:0] delay_re [0:DELAY_DEPTH-1];
            reg signed [WD-1:0] delay_im [0:DELAY_DEPTH-1];
            reg [5:0] wr_ptr;

            // Butterfly input/output — sel derived from stage-local counter
            wire                 sel = stg_cnt[BIT_SEL];  // 0=store, 1=butterfly
            wire signed [WD-1:0] in_re = stg_re[s];
            wire signed [WD-1:0] in_im = stg_im[s];

            // Read from delay line head
            wire signed [WD-1:0] del_re = delay_re[wr_ptr[($clog2(DELAY_DEPTH) > 0 ? $clog2(DELAY_DEPTH)-1 : 0):0]];
            wire signed [WD-1:0] del_im = delay_im[wr_ptr[($clog2(DELAY_DEPTH) > 0 ? $clog2(DELAY_DEPTH)-1 : 0):0]];

            // Butterfly: A=delayed sample, B=current input
            // X = A + B (goes to delay or next stage)
            // Y = A - B (gets twiddle multiplied, goes to next stage)
            // But in SDF architecture:
            //   sel=0: output = delayed, store input in delay
            //   sel=1: store (A+B) in delay, output = (A-B) * twiddle

            wire signed [WD:0] sum_re_w = {del_re[WD-1], del_re} + {in_re[WD-1], in_re};
            wire signed [WD:0] sum_im_w = {del_im[WD-1], del_im} + {in_im[WD-1], in_im};
            wire signed [WD:0] dif_re_w = {del_re[WD-1], del_re} - {in_re[WD-1], in_re};
            wire signed [WD:0] dif_im_w = {del_im[WD-1], del_im} - {in_im[WD-1], in_im};

            // Truncate with saturation
            wire signed [WD-1:0] sum_re_t;
            wire signed [WD-1:0] sum_im_t;
            wire signed [WD-1:0] dif_re_t;
            wire signed [WD-1:0] dif_im_t;

            assign sum_re_t = (sum_re_w > $signed({{2{1'b0}}, {(WD-1){1'b1}}})) ? {1'b0, {(WD-1){1'b1}}} :
                              (sum_re_w < $signed({{2{1'b1}}, {(WD-1){1'b0}}})) ? {1'b1, {(WD-1){1'b0}}} :
                              sum_re_w[WD-1:0];
            assign sum_im_t = (sum_im_w > $signed({{2{1'b0}}, {(WD-1){1'b1}}})) ? {1'b0, {(WD-1){1'b1}}} :
                              (sum_im_w < $signed({{2{1'b1}}, {(WD-1){1'b0}}})) ? {1'b1, {(WD-1){1'b0}}} :
                              sum_im_w[WD-1:0];
            assign dif_re_t = (dif_re_w > $signed({{2{1'b0}}, {(WD-1){1'b1}}})) ? {1'b0, {(WD-1){1'b1}}} :
                              (dif_re_w < $signed({{2{1'b1}}, {(WD-1){1'b0}}})) ? {1'b1, {(WD-1){1'b0}}} :
                              dif_re_w[WD-1:0];
            assign dif_im_t = (dif_im_w > $signed({{2{1'b0}}, {(WD-1){1'b1}}})) ? {1'b0, {(WD-1){1'b1}}} :
                              (dif_im_w < $signed({{2{1'b1}}, {(WD-1){1'b0}}})) ? {1'b1, {(WD-1){1'b0}}} :
                              dif_im_w[WD-1:0];

            // ---- Twiddle address computation (uses stage-local counter) ----
            // For stage s, the twiddle index is:
            //   tw_addr = lower BIT_SEL bits of stg_cnt, shifted left by s
            // At stage s, twiddle exponent = k * 2^s where k is the sub-counter
            // For stage 0 (DELAY=32): tw_idx = stg_cnt[4:0] * 1
            // For stage 1 (DELAY=16): tw_idx = stg_cnt[3:0] * 2
            // For stage 2 (DELAY=8):  tw_idx = stg_cnt[2:0] * 4
            // For stage 3 (DELAY=4):  tw_idx = stg_cnt[1:0] * 8
            // For stage 4 (DELAY=2):  tw_idx = stg_cnt[0]   * 16
            // For stage 5 (DELAY=1):  tw_idx = 0 (always W^0 = 1)
            wire [5:0] tw_addr;

            // Compute twiddle address based on stage using stage-local counter
            if (s == 0) begin : tw_s0
                assign tw_addr = stg_cnt[4:0];
            end else if (s == 1) begin : tw_s1
                assign tw_addr = {stg_cnt[3:0], 1'b0};
            end else if (s == 2) begin : tw_s2
                assign tw_addr = {stg_cnt[2:0], 2'b00};
            end else if (s == 3) begin : tw_s3
                assign tw_addr = {stg_cnt[1:0], 3'b000};
            end else if (s == 4) begin : tw_s4
                assign tw_addr = {stg_cnt[0], 4'b0000};
            end else begin : tw_s5
                assign tw_addr = 6'd0;
            end

            // Twiddle ROM instance
            wire signed [TW-1:0] tw_r, tw_i;

            twiddle_rom #(
                .FFT_N(FFT_N),
                .TW(TW)
            ) u_tw (
                .clk   (clk),
                .addr  (tw_addr[5:1]),  // ROM has N/2=32 entries, addr is k mod 32
                .tw_re (tw_r),
                .tw_im (tw_i)
            );

            // ---- Twiddle multiply on the difference path ----
            // dif * twiddle  (only when sel=1)
            // Using registered multiply for timing
            localparam integer PW = WD + TW;
            localparam integer SH = TW - 2;  // twiddle fractional bits

            reg signed [PW-1:0] tw_mul_rr, tw_mul_ii, tw_mul_ri, tw_mul_ir;
            reg signed [WD-1:0] dif_re_d1, dif_im_d1;
            reg                 sel_d1, valid_d1;
            reg signed [WD-1:0] sum_re_d1, sum_im_d1;

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    tw_mul_rr <= {PW{1'b0}};
                    tw_mul_ii <= {PW{1'b0}};
                    tw_mul_ri <= {PW{1'b0}};
                    tw_mul_ir <= {PW{1'b0}};
                    dif_re_d1 <= {WD{1'b0}};
                    dif_im_d1 <= {WD{1'b0}};
                    sum_re_d1 <= {WD{1'b0}};
                    sum_im_d1 <= {WD{1'b0}};
                    sel_d1    <= 1'b0;
                    valid_d1  <= 1'b0;
                end else begin
                    tw_mul_rr <= dif_re_t * tw_r;
                    tw_mul_ii <= dif_im_t * tw_i;
                    tw_mul_ri <= dif_re_t * tw_i;
                    tw_mul_ir <= dif_im_t * tw_r;
                    dif_re_d1 <= dif_re_t;
                    dif_im_d1 <= dif_im_t;
                    sum_re_d1 <= sum_re_t;
                    sum_im_d1 <= sum_im_t;
                    sel_d1    <= sel;
                    valid_d1  <= stg_valid[s];
                end
            end

            // Complex product: (dif_re + j*dif_im) * (tw_r + j*tw_i)
            //   real = dif_re*tw_r - dif_im*tw_i
            //   imag = dif_re*tw_i + dif_im*tw_r
            wire signed [PW-1:0] prod_re_full = tw_mul_rr - tw_mul_ii;
            wire signed [PW-1:0] prod_im_full = tw_mul_ri + tw_mul_ir;

            // Round and truncate
            wire signed [PW-1:0] prod_re_rnd = prod_re_full + (1 <<< (SH - 1));
            wire signed [PW-1:0] prod_im_rnd = prod_im_full + (1 <<< (SH - 1));

            wire signed [WD-1:0] tw_out_re = prod_re_rnd[SH + WD - 1 : SH];
            wire signed [WD-1:0] tw_out_im = prod_im_rnd[SH + WD - 1 : SH];

            // ---- Stage output register ----
            reg signed [WD-1:0] out_re_r, out_im_r;
            reg                 out_valid_r;

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    out_re_r   <= {WD{1'b0}};
                    out_im_r   <= {WD{1'b0}};
                    out_valid_r <= 1'b0;
                end else begin
                    out_valid_r <= valid_d1;
                    if (sel_d1) begin
                        // Butterfly phase: output twiddle-multiplied difference
                        out_re_r <= tw_out_re;
                        out_im_r <= tw_out_im;
                    end else begin
                        // Store phase: output delayed sample (passed through)
                        out_re_r <= sum_re_d1;  // In store phase, this is just the delayed val
                        out_im_r <= sum_im_d1;
                    end
                end
            end

            // Update delay line: store sum when sel=1, store input when sel=0
            // Uses stage-local counter for synchronized wr_ptr
            integer idx;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    wr_ptr <= 6'd0;
                    for (idx = 0; idx < DELAY_DEPTH; idx = idx + 1) begin
                        delay_re[idx] <= {WD{1'b0}};
                        delay_im[idx] <= {WD{1'b0}};
                    end
                end else if (stg_valid[s]) begin
                    if (sel) begin
                        // Butterfly: store A+B back into delay for next cycle's output
                        delay_re[wr_ptr[($clog2(DELAY_DEPTH) > 0 ? $clog2(DELAY_DEPTH)-1 : 0):0]] <= sum_re_t;
                        delay_im[wr_ptr[($clog2(DELAY_DEPTH) > 0 ? $clog2(DELAY_DEPTH)-1 : 0):0]] <= sum_im_t;
                    end else begin
                        // Store input into delay
                        delay_re[wr_ptr[($clog2(DELAY_DEPTH) > 0 ? $clog2(DELAY_DEPTH)-1 : 0):0]] <= in_re;
                        delay_im[wr_ptr[($clog2(DELAY_DEPTH) > 0 ? $clog2(DELAY_DEPTH)-1 : 0):0]] <= in_im;
                    end
                    if (wr_ptr[($clog2(DELAY_DEPTH) > 0 ? $clog2(DELAY_DEPTH)-1 : 0):0] == DELAY_DEPTH - 1)
                        wr_ptr <= 6'd0;
                    else
                        wr_ptr <= wr_ptr + 6'd1;
                end
            end

            assign stg_re[s+1]    = out_re_r;
            assign stg_im[s+1]    = out_im_r;
            assign stg_valid[s+1] = out_valid_r;

        end // for stage
    endgenerate

    // =========================================================================
    // Output assignment
    // =========================================================================
    assign m_re = stg_re[6];
    assign m_im = stg_im[6];
    assign m_valid = stg_valid[6];

    // ---- Output counter for m_last ----
    // m_last asserted on the last output sample of a 64-sample FFT frame
    reg [5:0] out_cnt;
    reg       m_last_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_cnt  <= 6'd0;
            m_last_r <= 1'b0;
        end else if (stg_valid[6]) begin
            if (out_cnt == 6'd63) begin
                out_cnt  <= 6'd0;
                m_last_r <= 1'b1;
            end else begin
                out_cnt  <= out_cnt + 6'd1;
                m_last_r <= 1'b0;
            end
        end else begin
            m_last_r <= 1'b0;
        end
    end

    assign m_last = m_last_r;

endmodule
