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
    input clk,
    input rst_n,
    input acc_clear,
    input in_valid,
    input dp_sign, // dot-product sign (from INT_MAC)
    input [`BFP_MAG_W-1:0] dp_mag, // dot-product magnitude
    input signed [`BFP_BEXP_W-1:0] blk_exp, // w_exp + a_exp - BFP_EXP_BIAS
    output o_sign,
    output [`FPACC_EXP_W-1:0] o_exp,
    output [`FPACC_MAN_W-1:0] o_man
);

    import BFP_PKG::*;

    logic [`FPACC_W-1:0] fp_a; // Norm result of this cycle's dot product
    logic [`FPACC_W-1:0] acc_next; // accumulator after FP addition
    logic [`FPACC_W-1:0] acc_reg; // FP accumulator (the single register)

    //==========================================================================
    // Combinational Datapath
    //==========================================================================
    assign fp_a = NORM(dp_sign, dp_mag, blk_exp);
    assign acc_next = FP_ADD(fp_a, acc_reg);

    //==========================================================================
    // FP Accumulator Register
    //==========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n) acc_reg <= '0;
        else if(acc_clear) acc_reg <= '0;
        else if(in_valid) acc_reg <= acc_next;
    end

    assign {o_sign, o_exp, o_man} = acc_reg;

endmodule
