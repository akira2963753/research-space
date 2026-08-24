/******************************************************************************
* Copyright (C) 2026 Marco
*
* File Name:    BG_PE_CORE.sv
* Project:      Bucket Getter BFP Processing Element
* Module:       Weight-stationary Bucket Getter PE core
* Author:       Marco <harry2963753@gmail.com>
*
******************************************************************************/
`include "BG_INCLUDE.svh"

module BG_PE_CORE(
    input logic clk,
    input logic rst_n,
    input logic i_start,
    input logic i_weight_load,
    input logic [`BG_SIGN_BW-1:0] i_w_sign,
    input logic [`BG_EXP_W-1:0] i_w_exp,
    input logic [`BG_MAN_BW-1:0] i_w_man,
    input logic i_valid,
    output logic o_ready,
    input logic i_last,
    input logic [`BG_SIGN_BW-1:0] i_a_sign,
    input logic [`BG_EXP_W-1:0] i_a_exp,
    input logic [`BG_MAN_BW-1:0] i_a_man,
    output logic o_fp_req_valid,
    input logic i_fp_req_ready,
    output logic [`BG_FP_W-1:0] o_fp_req_psum,
    output logic [`BG_FP_W-1:0] o_fp_req_term,
    input logic [`BG_FP_W-1:0] i_fp_req_result,
    output logic o_result_valid,
    input logic i_result_ready,
    output logic [`BG_FP_W-1:0] o_result,
    output logic o_busy
);

    logic [`BG_SIGN_BW-1:0] w_sign_reg;
    logic [`BG_EXP_W-1:0] w_exp_reg;
    logic [`BG_MAN_BW-1:0] w_man_reg;

    logic signed [`BG_SUM_W-1:0] dot_sum;
    logic signed [`BG_BEXP_W-1:0] block_exp;
    logic bank_ready;
    logic bank_spill_valid;
    logic [`BG_FP_W-1:0] bank_spill_fp;
    logic bank_done;
    logic bank_busy;
    logic [`BG_FP_W-1:0] fp_psum_reg;
    logic result_valid_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_sign_reg <= '0;
            w_exp_reg <= '0;
            w_man_reg <= '0;
        end
        else if (i_weight_load) begin
            w_sign_reg <= i_w_sign;
            w_exp_reg <= i_w_exp;
            w_man_reg <= i_w_man;
        end
    end

    BG_INT_MAC u_int_mac(
        .i_w_sign(w_sign_reg),
        .i_a_sign(i_a_sign),
        .i_w_man(w_man_reg),
        .i_a_man(i_a_man),
        .o_sum(dot_sum)
    );

    always_comb begin
        block_exp = $signed({1'b0, w_exp_reg})
                  + $signed({1'b0, i_a_exp})
                  - `BG_EXP_BIAS;
    end

    BG_BUCKET_BANK u_bucket_bank(
        .clk(clk),
        .rst_n(rst_n),
        .i_start(i_start),
        .i_valid(i_valid && o_ready),
        .o_ready(bank_ready),
        .i_last(i_last),
        .i_sum(dot_sum),
        .i_exp(block_exp),
        .o_spill_valid(bank_spill_valid),
        .i_spill_ready(i_fp_req_ready),
        .o_spill_fp(bank_spill_fp),
        .o_done(bank_done),
        .o_busy(bank_busy)
    );

    assign o_ready = bank_ready && !result_valid_reg;
    assign o_fp_req_valid = bank_spill_valid;
    assign o_fp_req_psum = fp_psum_reg;
    assign o_fp_req_term = bank_spill_fp;
    assign o_result_valid = result_valid_reg;
    assign o_result = fp_psum_reg;
    assign o_busy = bank_busy || result_valid_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fp_psum_reg <= '0;
            result_valid_reg <= 1'b0;
        end
        else if (i_start) begin
            fp_psum_reg <= '0;
            result_valid_reg <= 1'b0;
        end
        else begin
            if (o_fp_req_valid && i_fp_req_ready) fp_psum_reg <= i_fp_req_result;
            if (bank_done) result_valid_reg <= 1'b1;
            else if (result_valid_reg && i_result_ready) result_valid_reg <= 1'b0;
        end
    end

endmodule
