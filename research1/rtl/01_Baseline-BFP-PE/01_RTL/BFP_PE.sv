/******************************************************************************
* Copyright (C) 2026 Marco
*
* File Name:    BFP_PE.sv
* Project:      Research for Block Floating Point Processing Element
* Module:       Baselined BFP-PE (WS)
* Author:       Marco <harry2963753@gmail.com>
*
******************************************************************************/
`include "include.vh"

module BFP_PE (
    input clk,
    input rst_n,
    input acc_clear,
    input weight_load,
    input in_valid,
    input [`BFP_SIGN_BW-1:0] w_sign_b,
    input [`BFP_SIGN_BW-1:0] a_sign_b,
    input [`BFP_EXP_W-1:0] w_exp,
    input [`BFP_EXP_W-1:0] a_exp,
    input [`BFP_MAN_BW-1:0] w_man_b,
    input [`BFP_MAN_BW-1:0] a_man_b,
    output o_sign,
    output [`FPACC_EXP_W-1:0] o_exp,
    output [`FPACC_MAN_W-1:0] o_man
);

    //==========================================================================
    // Weight-Stationary Registers
    //==========================================================================
    logic [`BFP_SIGN_BW-1:0] w_sign_reg;
    logic [`BFP_EXP_W-1:0] w_exp_reg;
    logic [`BFP_MAN_BW-1:0] w_man_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            w_sign_reg <= '0;
            w_exp_reg <= '0;
            w_man_reg <= '0;
        end
        else if(weight_load) begin
            w_sign_reg <= w_sign_b;
            w_exp_reg <= w_exp;
            w_man_reg <= w_man_b;
        end
    end

    //==========================================================================
    // Block Exponent Adder
    //==========================================================================
    logic signed [`BFP_BEXP_W-1:0] blk_exp;
    assign blk_exp = $signed({1'b0, w_exp_reg}) + $signed({1'b0, a_exp}) - `BFP_EXP_BIAS;

    //==========================================================================
    // Integer MAC
    //==========================================================================
    logic dp_sign;
    logic [`BFP_MAG_W-1:0] dp_mag;

    INT_MAC u_int_mac (
        .w_sign_b(w_sign_reg),
        .a_sign_b(a_sign_b),
        .w_man_b(w_man_reg),
        .a_man_b(a_man_b),
        .dp_sign(dp_sign),
        .dp_mag(dp_mag)
    );

    //==========================================================================
    // FP Accumulator
    //==========================================================================
    FP_ACC u_fp_acc (
        .clk(clk),
        .rst_n(rst_n),
        .acc_clear(acc_clear),
        .in_valid(in_valid),
        .dp_sign(dp_sign),
        .dp_mag(dp_mag),
        .blk_exp(blk_exp),
        .o_sign(o_sign),
        .o_exp(o_exp),
        .o_man(o_man)
    );

endmodule
