/******************************************************************************
* Copyright (C) 2026 Marco
*
* File Name:    FP_ACC.sv
* Project:      Bucket Getter BFP Processing Element
* Module:       Common FP accumulator used by Baseline and Bucket Getter
* Author:       Marco <harry2963753@gmail.com>
*
******************************************************************************/
`include "include.vh"

module FP_ACC(
    input clk,
    input rst_n,
    input acc_clear,
    input in_valid,
    input dp_sign,
    input [`BFP_MAG_W-1:0] dp_mag,
    input signed [`BFP_BEXP_W-1:0] blk_exp,
    output o_sign,
    output [`FPACC_EXP_W-1:0] o_exp,
    output [`FPACC_MAN_W-1:0] o_man
);

    import BFP_PKG::*;

    logic [`FPACC_W-1:0] fp_a;
    logic [`FPACC_W-1:0] acc_next;
    logic [`FPACC_W-1:0] acc_reg;

    assign fp_a = NORM(dp_sign, dp_mag, blk_exp);
    assign acc_next = FP_ADD(fp_a, acc_reg);

    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n) acc_reg <= '0;
        else if(acc_clear) acc_reg <= '0;
        else if(in_valid) acc_reg <= acc_next;
    end

    assign {o_sign, o_exp, o_man} = acc_reg;

endmodule
