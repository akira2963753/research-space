/******************************************************************************
* Copyright (C) 2026 Marco
*
* File Name:    FP_ACC.sv
* Project:      Dynamic Exponent Window Accumulation Based PE
* Module:       FP Accumulator
* Author:       Marco <harry2963753@gmail.com>
*
******************************************************************************/
`include "include.vh"

module FP_ACC (
    input logic clk,
    input logic rst_n,
    input logic acc_clear,
    input logic in_valid,
    input logic dp_sign,
    input logic [`BFP_MAG_W-1:0] dp_mag,
    input logic signed [`BFP_BEXP_W-1:0] blk_exp,
    output logic o_sign,
    output logic [`FPACC_EXP_W-1:0] o_exp,
    output logic [`FPACC_MAN_W-1:0] o_man
);

    import BFP_PKG::*;

    //=============================================================
    //                     FP Accumulator State
    //=============================================================
    logic [`FPACC_W-1:0] fp_input;
    logic [`FPACC_W-1:0] acc_next;
    logic [`FPACC_W-1:0] acc_reg;

    assign fp_input = NORM(dp_sign, dp_mag, blk_exp);
    assign acc_next = FP_ADD(fp_input, acc_reg);

    always_ff @(posedge clk or negedge rst_n) begin : ACCUMULATOR
        if(!rst_n) acc_reg <= '0;
        else if(acc_clear) acc_reg <= '0;
        else if(in_valid) acc_reg <= acc_next;
    end

    assign {o_sign, o_exp, o_man} = acc_reg;

endmodule
