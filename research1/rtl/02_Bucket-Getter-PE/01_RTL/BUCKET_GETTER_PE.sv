/******************************************************************************
* Copyright (C) 2026 Marco
*
* File Name:    BUCKET_GETTER_PE.sv
* Project:      Bucket Getter BFP Processing Element
* Module:       Standalone Bucket Getter PE with local FP-Acc
* Author:       Marco <harry2963753@gmail.com>
*
******************************************************************************/
`include "BG_INCLUDE.svh"

module BUCKET_GETTER_PE(
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
    output logic o_result_valid,
    input logic i_result_ready,
    output logic o_sign,
    output logic [`BG_FP_EXP_W-1:0] o_exp,
    output logic [`BG_FP_MAN_W-1:0] o_man,
    output logic o_busy
);

    logic fp_req_valid;
    logic [`BG_FP_W-1:0] fp_req_psum;
    logic [`BG_FP_W-1:0] fp_req_term;
    logic [`BG_FP_W-1:0] fp_req_result;
    logic [`BG_FP_W-1:0] result;

    BG_PE_CORE u_pe_core(
        .clk(clk),
        .rst_n(rst_n),
        .i_start(i_start),
        .i_weight_load(i_weight_load),
        .i_w_sign(i_w_sign),
        .i_w_exp(i_w_exp),
        .i_w_man(i_w_man),
        .i_valid(i_valid),
        .o_ready(o_ready),
        .i_last(i_last),
        .i_a_sign(i_a_sign),
        .i_a_exp(i_a_exp),
        .i_a_man(i_a_man),
        .o_fp_req_valid(fp_req_valid),
        .i_fp_req_ready(1'b1),
        .o_fp_req_psum(fp_req_psum),
        .o_fp_req_term(fp_req_term),
        .i_fp_req_result(fp_req_result),
        .o_result_valid(o_result_valid),
        .i_result_ready(i_result_ready),
        .o_result(result),
        .o_busy(o_busy)
    );

    BG_FP_ACC u_fp_acc(
        .i_psum(fp_req_psum),
        .i_term(fp_req_term),
        .o_result(fp_req_result)
    );

    assign {o_sign, o_exp, o_man} = result;

endmodule
