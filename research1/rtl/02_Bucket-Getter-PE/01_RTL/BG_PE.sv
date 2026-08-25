/******************************************************************************
* Copyright (C) 2026 Marco
*
* File Name:    BG_PE.sv
* Project:      Bucket Getter BFP Processing Element
* Module:       Bucket Getter processing element top
* Author:       Marco <harry2963753@gmail.com>
*
******************************************************************************/
`include "include.vh"

module BG_PE(
    input logic clk,
    input logic rst_n,
    input logic i_start,
    input logic i_weight_load,
    input logic [`BFP_SIGN_BW-1:0] i_w_sign,
    input logic [`BFP_EXP_W-1:0] i_w_exp,
    input logic [`BFP_MAN_BW-1:0] i_w_man,
    input logic i_valid,
    output logic o_ready,
    input logic i_last,
    input logic [`BFP_SIGN_BW-1:0] i_a_sign,
    input logic [`BFP_EXP_W-1:0] i_a_exp,
    input logic [`BFP_MAN_BW-1:0] i_a_man,
    output logic o_result_valid,
    input logic i_result_ready,
    output logic o_sign,
    output logic [`FPACC_EXP_W-1:0] o_exp,
    output logic [`FPACC_MAN_W-1:0] o_man,
    output logic o_busy
);

    logic [`BFP_SIGN_BW-1:0] w_sign_reg;
    logic [`BFP_EXP_W-1:0] w_exp_reg;
    logic [`BFP_MAN_BW-1:0] w_man_reg;

    logic dp_sign;
    logic [`BFP_MAG_W-1:0] dp_mag;
    logic signed [`BFP_BEXP_W-1:0] block_exp;

    logic bg_ready;
    logic bg_spill_valid;
    logic bg_spill_sign;
    logic [`BFP_MAG_W-1:0] bg_spill_mag;
    logic signed [`BFP_BEXP_W-1:0] bg_spill_exp;
    logic bg_done;
    logic bg_busy;
    logic result_valid_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            w_sign_reg <= '0;
            w_exp_reg <= '0;
            w_man_reg <= '0;
        end
        else if(i_weight_load) begin
            w_sign_reg <= i_w_sign;
            w_exp_reg <= i_w_exp;
            w_man_reg <= i_w_man;
        end
    end

    assign block_exp = $signed({1'b0, w_exp_reg})
                     + $signed({1'b0, i_a_exp})
                     - `BFP_EXP_BIAS;

    INT_MAC u_int_mac(
        .w_sign_b(w_sign_reg),
        .a_sign_b(i_a_sign),
        .w_man_b(w_man_reg),
        .a_man_b(i_a_man),
        .dp_sign(dp_sign),
        .dp_mag(dp_mag)
    );

    BG_ACC u_bg_acc(
        .clk(clk),
        .rst_n(rst_n),
        .i_start(i_start),
        .i_valid(i_valid && o_ready),
        .o_ready(bg_ready),
        .i_last(i_last),
        .i_dp_sign(dp_sign),
        .i_dp_mag(dp_mag),
        .i_exp(block_exp),
        .o_spill_valid(bg_spill_valid),
        .i_spill_ready(1'b1),
        .o_spill_sign(bg_spill_sign),
        .o_spill_mag(bg_spill_mag),
        .o_spill_exp(bg_spill_exp),
        .o_done(bg_done),
        .o_busy(bg_busy)
    );

    FP_ACC u_fp_acc(
        .clk(clk),
        .rst_n(rst_n),
        .acc_clear(i_start),
        .in_valid(bg_spill_valid),
        .dp_sign(bg_spill_sign),
        .dp_mag(bg_spill_mag),
        .blk_exp(bg_spill_exp),
        .o_sign(o_sign),
        .o_exp(o_exp),
        .o_man(o_man)
    );

    assign o_ready = bg_ready && !result_valid_reg;
    assign o_result_valid = result_valid_reg;
    assign o_busy = bg_busy || result_valid_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n) result_valid_reg <= 1'b0;
        else if(i_start) result_valid_reg <= 1'b0;
        else if(bg_done) result_valid_reg <= 1'b1;
        else if(result_valid_reg && i_result_ready) result_valid_reg <= 1'b0;
    end

endmodule
