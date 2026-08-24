/******************************************************************************
* Copyright (C) 2026 Marco
*
* File Name:    BG_BUCKET_BANK.sv
* Project:      Bucket Getter BFP Processing Element
* Module:       OB-aware adaptive circular bucket accumulator
* Author:       Marco <harry2963753@gmail.com>
*
******************************************************************************/
`include "BG_INCLUDE.svh"

module BG_BUCKET_BANK(
    input logic clk,
    input logic rst_n,
    input logic i_start,
    input logic i_valid,
    output logic o_ready,
    input logic i_last,
    input logic signed [`BG_SUM_W-1:0] i_sum,
    input logic signed [`BG_BEXP_W-1:0] i_exp,
    output logic o_spill_valid,
    input logic i_spill_ready,
    output logic [`BG_FP_W-1:0] o_spill_fp,
    output logic o_done,
    output logic o_busy
);

    import BG_PKG::*;

    localparam logic [2:0] S_ACC = 3'd0;
    localparam logic [2:0] S_APPLY = 3'd1;
    localparam logic [2:0] S_ROTATE = 3'd2;
    localparam logic [2:0] S_CARRY = 3'd3;
    localparam logic [2:0] S_SPILL = 3'd4;
    localparam logic [2:0] S_DRAIN = 3'd5;
    localparam logic [2:0] S_DONE = 3'd6;

    logic [2:0] state;
    logic [2:0] spill_return_state;

    logic signed [`BG_BUCKET_WIDTH-1:0] bucket_reg [`BG_BUCKET_COUNT];
    logic [`BG_BUCKET_COUNT-1:0] bucket_valid;
    logic emax_valid;
    logic signed [`BG_BEXP_W-1:0] emax_base;
    logic [`BG_BUCKET_PTR_W-1:0] front_ptr;

    logic pending_valid;
    logic pending_last;
    logic signed [`BG_SUM_W-1:0] pending_sum;
    logic signed [`BG_BEXP_W-1:0] pending_exp;
    logic signed [`BG_BEXP_W-1:0] rotate_target_base;

    logic [`BG_BUCKET_PTR_W-1:0] carry_logical_offset;
    logic signed [`BG_BUCKET_WIDTH-1:0] carry_value;
    integer drain_offset;

    logic spill_valid_reg;
    logic [`BG_FP_W-1:0] spill_fp_reg;

    logic signed [`BG_BEXP_W-1:0] ctrl_value_base;
    logic ctrl_above_window;
    logic ctrl_below_window;
    logic ctrl_out_of_bound;
    logic [`BG_BUCKET_PTR_W-1:0] ctrl_bucket_ptr;
    logic [`BG_BUCKET_PTR_W-1:0] ctrl_logical_offset;
    logic [`BG_BUCKET_SHIFT_W-1:0] ctrl_shift;

    logic signed [`BG_BUCKET_WIDTH-1:0] pending_term;
    logic signed [`BG_BUCKET_WIDTH:0] selected_add_ext;
    logic selected_add_fits;
    logic [`BG_BUCKET_PTR_W-1:0] carry_bucket_ptr;
    logic signed [`BG_BUCKET_WIDTH:0] carry_add_ext;
    logic carry_add_fits;
    logic signed [`BG_BUCKET_WIDTH-1:0] positive_carry;
    logic signed [`BG_BUCKET_WIDTH-1:0] negative_carry;

    BG_BUCKET_CTRL u_bucket_ctrl(
        .i_emax_valid(emax_valid),
        .i_emax_base(emax_base),
        .i_front_ptr(front_ptr),
        .i_value_exp(pending_exp),
        .o_value_base(ctrl_value_base),
        .o_above_window(ctrl_above_window),
        .o_below_window(ctrl_below_window),
        .o_out_of_bound(ctrl_out_of_bound),
        .o_bucket_ptr(ctrl_bucket_ptr),
        .o_logical_offset(ctrl_logical_offset),
        .o_shift(ctrl_shift)
    );

    always_comb begin
        pending_term = {{(`BG_BUCKET_WIDTH-`BG_SUM_W){pending_sum[`BG_SUM_W-1]}}, pending_sum};
        pending_term = pending_term <<< ctrl_shift;
        selected_add_ext = $signed({bucket_reg[ctrl_bucket_ptr][`BG_BUCKET_WIDTH-1], bucket_reg[ctrl_bucket_ptr]})
                         + $signed({pending_term[`BG_BUCKET_WIDTH-1], pending_term});
        selected_add_fits = selected_add_ext[`BG_BUCKET_WIDTH]
                          == selected_add_ext[`BG_BUCKET_WIDTH-1];

        carry_bucket_ptr = PTR_SUB(front_ptr, carry_logical_offset);
        carry_add_ext = $signed({bucket_reg[carry_bucket_ptr][`BG_BUCKET_WIDTH-1], bucket_reg[carry_bucket_ptr]})
                      + $signed({carry_value[`BG_BUCKET_WIDTH-1], carry_value});
        carry_add_fits = carry_add_ext[`BG_BUCKET_WIDTH]
                       == carry_add_ext[`BG_BUCKET_WIDTH-1];

        positive_carry = '0;
        positive_carry[`BG_BUCKET_WIDTH-`BG_EXP_PER_BUCKET] = 1'b1;
        negative_carry = -positive_carry;
    end

    assign o_ready = state == S_ACC && !pending_valid;
    assign o_spill_valid = spill_valid_reg;
    assign o_spill_fp = spill_fp_reg;
    assign o_busy = state != S_ACC;

    initial begin
        if (`BG_BUCKET_COUNT < 2) $error("BG_BUCKET_COUNT must be at least two.");
        if ((1 << `BG_BUCKET_PTR_W) != `BG_BUCKET_COUNT) $error("BG_BUCKET_COUNT must be a power of two.");
        if (`BG_EXP_PER_BUCKET < 2) $error("BG_EXP_PER_BUCKET must be at least two.");
        if (`BG_EXP_PER_BUCKET >= `BG_BUCKET_WIDTH) $error("BG_EXP_PER_BUCKET must be smaller than BG_BUCKET_WIDTH.");
    end

    always_ff @(posedge clk or negedge rst_n) begin : p_bucket_state
        integer victim_ptr;
        integer victim_base;
        integer drain_ptr;
        integer drain_base;
        if (!rst_n) begin
            state <= S_ACC;
            spill_return_state <= S_ACC;
            bucket_valid <= '0;
            emax_valid <= 1'b0;
            emax_base <= '0;
            front_ptr <= '0;
            pending_valid <= 1'b0;
            pending_last <= 1'b0;
            pending_sum <= '0;
            pending_exp <= '0;
            rotate_target_base <= '0;
            carry_logical_offset <= '0;
            carry_value <= '0;
            drain_offset <= 0;
            spill_valid_reg <= 1'b0;
            spill_fp_reg <= '0;
            o_done <= 1'b0;
            for (int i = 0; i < `BG_BUCKET_COUNT; i++) bucket_reg[i] <= '0;
        end
        else if (i_start) begin
            state <= S_ACC;
            spill_return_state <= S_ACC;
            bucket_valid <= '0;
            emax_valid <= 1'b0;
            emax_base <= '0;
            front_ptr <= '0;
            pending_valid <= 1'b0;
            pending_last <= 1'b0;
            pending_sum <= '0;
            pending_exp <= '0;
            rotate_target_base <= '0;
            carry_logical_offset <= '0;
            carry_value <= '0;
            drain_offset <= 0;
            spill_valid_reg <= 1'b0;
            spill_fp_reg <= '0;
            o_done <= 1'b0;
            for (int i = 0; i < `BG_BUCKET_COUNT; i++) bucket_reg[i] <= '0;
        end
        else begin
            o_done <= 1'b0;

            case (state)
                S_ACC: begin
                    if (i_valid && o_ready) begin
                        pending_valid <= 1'b1;
                        pending_last <= i_last;
                        pending_sum <= i_sum;
                        pending_exp <= i_exp;
                        state <= S_APPLY;
                    end
                end

                S_APPLY: begin
                    if (pending_sum == 0) begin
                        pending_valid <= 1'b0;
                        if (pending_last) begin
                            drain_offset <= 0;
                            state <= S_DRAIN;
                        end
                        else state <= S_ACC;
                    end
                    else if (!emax_valid) begin
                        emax_valid <= 1'b1;
                        emax_base <= ctrl_value_base;
                        front_ptr <= '0;
                        bucket_reg[0] <= pending_term;
                        bucket_valid[0] <= pending_term != 0;
                        pending_valid <= 1'b0;
                        if (pending_last) begin
                            drain_offset <= 0;
                            state <= S_DRAIN;
                        end
                        else state <= S_ACC;
                    end
                    else if (ctrl_above_window) begin
                        rotate_target_base <= ctrl_value_base;
                        state <= S_ROTATE;
                    end
                    else if (ctrl_below_window) begin
                        pending_valid <= 1'b0;
                        if (ctrl_out_of_bound || pending_sum == 0) begin
                            if (pending_last) begin
                                drain_offset <= 0;
                                state <= S_DRAIN;
                            end
                            else state <= S_ACC;
                        end
                        else begin
                            spill_fp_reg <= SUM_TO_FP(pending_sum, pending_exp);
                            spill_valid_reg <= 1'b1;
                            if (pending_last) begin
                                drain_offset <= 0;
                                spill_return_state <= S_DRAIN;
                            end
                            else spill_return_state <= S_ACC;
                            state <= S_SPILL;
                        end
                    end
                    else if (!bucket_valid[ctrl_bucket_ptr]) begin
                        bucket_reg[ctrl_bucket_ptr] <= pending_term;
                        bucket_valid[ctrl_bucket_ptr] <= pending_term != 0;
                        pending_valid <= 1'b0;
                        if (pending_last) begin
                            drain_offset <= 0;
                            state <= S_DRAIN;
                        end
                        else state <= S_ACC;
                    end
                    else if (selected_add_fits) begin
                        bucket_reg[ctrl_bucket_ptr] <= selected_add_ext[`BG_BUCKET_WIDTH-1:0];
                        bucket_valid[ctrl_bucket_ptr] <= selected_add_ext[`BG_BUCKET_WIDTH-1:0] != 0;
                        pending_valid <= 1'b0;
                        if (pending_last) begin
                            drain_offset <= 0;
                            state <= S_DRAIN;
                        end
                        else state <= S_ACC;
                    end
                    else if (ctrl_logical_offset == 0) begin
                        spill_fp_reg <= BUCKET_TO_FP(bucket_reg[ctrl_bucket_ptr], emax_base);
                        spill_valid_reg <= 1'b1;
                        spill_return_state <= S_APPLY;
                        bucket_reg[ctrl_bucket_ptr] <= '0;
                        bucket_valid[ctrl_bucket_ptr] <= 1'b0;
                        state <= S_SPILL;
                    end
                    else begin
                        bucket_reg[ctrl_bucket_ptr] <= selected_add_ext[`BG_BUCKET_WIDTH-1:0];
                        bucket_valid[ctrl_bucket_ptr] <= selected_add_ext[`BG_BUCKET_WIDTH-1:0] != 0;
                        carry_logical_offset <= ctrl_logical_offset - 1'b1;
                        carry_value <= selected_add_ext[`BG_BUCKET_WIDTH] ? negative_carry : positive_carry;
                        state <= S_CARRY;
                    end
                end

                S_ROTATE: begin
                    if (emax_base < rotate_target_base) begin
                        victim_ptr = PTR_INC(front_ptr);
                        victim_base = emax_base - (`BG_BUCKET_COUNT-1)*`BG_EXP_PER_BUCKET;
                        front_ptr <= PTR_INC(front_ptr);
                        emax_base <= emax_base + `BG_EXP_PER_BUCKET;
                        bucket_reg[victim_ptr] <= '0;
                        bucket_valid[victim_ptr] <= 1'b0;

                        if (bucket_valid[victim_ptr]
                            && rotate_target_base-victim_base < `BG_FP_SIG_W) begin
                            spill_fp_reg <= BUCKET_TO_FP(bucket_reg[victim_ptr], victim_base);
                            spill_valid_reg <= 1'b1;
                            spill_return_state <= S_ROTATE;
                            state <= S_SPILL;
                        end
                    end
                    else state <= S_APPLY;
                end

                S_CARRY: begin
                    if (!bucket_valid[carry_bucket_ptr]) begin
                        bucket_reg[carry_bucket_ptr] <= carry_value;
                        bucket_valid[carry_bucket_ptr] <= carry_value != 0;
                        pending_valid <= 1'b0;
                        if (pending_last) begin
                            drain_offset <= 0;
                            state <= S_DRAIN;
                        end
                        else state <= S_ACC;
                    end
                    else if (carry_add_fits) begin
                        bucket_reg[carry_bucket_ptr] <= carry_add_ext[`BG_BUCKET_WIDTH-1:0];
                        bucket_valid[carry_bucket_ptr] <= carry_add_ext[`BG_BUCKET_WIDTH-1:0] != 0;
                        pending_valid <= 1'b0;
                        if (pending_last) begin
                            drain_offset <= 0;
                            state <= S_DRAIN;
                        end
                        else state <= S_ACC;
                    end
                    else if (carry_logical_offset == 0) begin
                        spill_fp_reg <= BUCKET_TO_FP(bucket_reg[carry_bucket_ptr], emax_base);
                        spill_valid_reg <= 1'b1;
                        spill_return_state <= S_CARRY;
                        bucket_reg[carry_bucket_ptr] <= '0;
                        bucket_valid[carry_bucket_ptr] <= 1'b0;
                        state <= S_SPILL;
                    end
                    else begin
                        bucket_reg[carry_bucket_ptr] <= carry_add_ext[`BG_BUCKET_WIDTH-1:0];
                        bucket_valid[carry_bucket_ptr] <= carry_add_ext[`BG_BUCKET_WIDTH-1:0] != 0;
                        carry_logical_offset <= carry_logical_offset - 1'b1;
                        carry_value <= carry_add_ext[`BG_BUCKET_WIDTH] ? negative_carry : positive_carry;
                    end
                end

                S_SPILL: begin
                    if (spill_valid_reg && i_spill_ready) begin
                        spill_valid_reg <= 1'b0;
                        state <= spill_return_state;
                    end
                end

                S_DRAIN: begin
                    if (drain_offset >= `BG_BUCKET_COUNT) begin
                        o_done <= 1'b1;
                        state <= S_DONE;
                    end
                    else begin
                        drain_ptr = PTR_SUB(front_ptr, drain_offset);
                        drain_base = emax_base - drain_offset*`BG_EXP_PER_BUCKET;
                        drain_offset <= drain_offset + 1;
                        if (bucket_valid[drain_ptr]
                            && emax_base-drain_base < `BG_FP_SIG_W) begin
                            spill_fp_reg <= BUCKET_TO_FP(bucket_reg[drain_ptr], drain_base);
                            spill_valid_reg <= 1'b1;
                            spill_return_state <= S_DRAIN;
                            bucket_reg[drain_ptr] <= '0;
                            bucket_valid[drain_ptr] <= 1'b0;
                            state <= S_SPILL;
                        end
                        else begin
                            bucket_reg[drain_ptr] <= '0;
                            bucket_valid[drain_ptr] <= 1'b0;
                        end
                    end
                end

                S_DONE: state <= S_DONE;

                default: state <= S_ACC;
            endcase
        end
    end

endmodule
