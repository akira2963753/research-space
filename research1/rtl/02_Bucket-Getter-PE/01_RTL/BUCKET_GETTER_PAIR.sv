/******************************************************************************
* Copyright (C) 2026 Marco
*
* File Name:    BUCKET_GETTER_PAIR.sv
* Project:      Bucket Getter BFP Processing Element
* Module:       Two Bucket Getter PEs sharing one FP-Acc
* Author:       Marco <harry2963753@gmail.com>
*
******************************************************************************/
`include "BG_INCLUDE.svh"

module BUCKET_GETTER_PAIR(
    input logic clk,
    input logic rst_n,

    input logic i_start_0,
    input logic i_weight_load_0,
    input logic [`BG_SIGN_BW-1:0] i_w_sign_0,
    input logic [`BG_EXP_W-1:0] i_w_exp_0,
    input logic [`BG_MAN_BW-1:0] i_w_man_0,
    input logic i_valid_0,
    output logic o_ready_0,
    input logic i_last_0,
    input logic [`BG_SIGN_BW-1:0] i_a_sign_0,
    input logic [`BG_EXP_W-1:0] i_a_exp_0,
    input logic [`BG_MAN_BW-1:0] i_a_man_0,
    output logic o_result_valid_0,
    input logic i_result_ready_0,
    output logic [`BG_FP_W-1:0] o_result_0,
    output logic o_busy_0,

    input logic i_start_1,
    input logic i_weight_load_1,
    input logic [`BG_SIGN_BW-1:0] i_w_sign_1,
    input logic [`BG_EXP_W-1:0] i_w_exp_1,
    input logic [`BG_MAN_BW-1:0] i_w_man_1,
    input logic i_valid_1,
    output logic o_ready_1,
    input logic i_last_1,
    input logic [`BG_SIGN_BW-1:0] i_a_sign_1,
    input logic [`BG_EXP_W-1:0] i_a_exp_1,
    input logic [`BG_MAN_BW-1:0] i_a_man_1,
    output logic o_result_valid_1,
    input logic i_result_ready_1,
    output logic [`BG_FP_W-1:0] o_result_1,
    output logic o_busy_1
);

    logic req_valid_0;
    logic req_ready_0;
    logic [`BG_FP_W-1:0] req_psum_0;
    logic [`BG_FP_W-1:0] req_term_0;
    logic [`BG_FP_W-1:0] req_result_0;
    logic req_valid_1;
    logic req_ready_1;
    logic [`BG_FP_W-1:0] req_psum_1;
    logic [`BG_FP_W-1:0] req_term_1;
    logic [`BG_FP_W-1:0] req_result_1;

    logic round_robin;
    logic grant_0;
    logic grant_1;
    logic [`BG_FP_W-1:0] shared_psum;
    logic [`BG_FP_W-1:0] shared_term;
    logic [`BG_FP_W-1:0] shared_result;

    BG_PE_CORE u_pe_0(
        .clk(clk), .rst_n(rst_n), .i_start(i_start_0),
        .i_weight_load(i_weight_load_0), .i_w_sign(i_w_sign_0),
        .i_w_exp(i_w_exp_0), .i_w_man(i_w_man_0),
        .i_valid(i_valid_0), .o_ready(o_ready_0), .i_last(i_last_0),
        .i_a_sign(i_a_sign_0), .i_a_exp(i_a_exp_0), .i_a_man(i_a_man_0),
        .o_fp_req_valid(req_valid_0), .i_fp_req_ready(req_ready_0),
        .o_fp_req_psum(req_psum_0), .o_fp_req_term(req_term_0),
        .i_fp_req_result(req_result_0), .o_result_valid(o_result_valid_0),
        .i_result_ready(i_result_ready_0), .o_result(o_result_0), .o_busy(o_busy_0)
    );

    BG_PE_CORE u_pe_1(
        .clk(clk), .rst_n(rst_n), .i_start(i_start_1),
        .i_weight_load(i_weight_load_1), .i_w_sign(i_w_sign_1),
        .i_w_exp(i_w_exp_1), .i_w_man(i_w_man_1),
        .i_valid(i_valid_1), .o_ready(o_ready_1), .i_last(i_last_1),
        .i_a_sign(i_a_sign_1), .i_a_exp(i_a_exp_1), .i_a_man(i_a_man_1),
        .o_fp_req_valid(req_valid_1), .i_fp_req_ready(req_ready_1),
        .o_fp_req_psum(req_psum_1), .o_fp_req_term(req_term_1),
        .i_fp_req_result(req_result_1), .o_result_valid(o_result_valid_1),
        .i_result_ready(i_result_ready_1), .o_result(o_result_1), .o_busy(o_busy_1)
    );

    always_comb begin
        grant_0 = 1'b0;
        grant_1 = 1'b0;
        shared_psum = '0;
        shared_term = '0;

        if (req_valid_0 && req_valid_1) begin
            if (!round_robin) grant_0 = 1'b1;
            else grant_1 = 1'b1;
        end
        else if (req_valid_0) grant_0 = 1'b1;
        else if (req_valid_1) grant_1 = 1'b1;

        if (grant_0) begin
            shared_psum = req_psum_0;
            shared_term = req_term_0;
        end
        else if (grant_1) begin
            shared_psum = req_psum_1;
            shared_term = req_term_1;
        end
    end

    assign req_ready_0 = grant_0;
    assign req_ready_1 = grant_1;
    assign req_result_0 = shared_result;
    assign req_result_1 = shared_result;

    BG_FP_ACC u_shared_fp_acc(
        .i_psum(shared_psum),
        .i_term(shared_term),
        .o_result(shared_result)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) round_robin <= 1'b0;
        else if (req_valid_0 && req_valid_1) round_robin <= ~round_robin;
    end

endmodule
