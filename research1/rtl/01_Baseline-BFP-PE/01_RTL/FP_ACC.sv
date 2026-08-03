/******************************************************************************
* Copyright (C) 2026 Marco
*
* File Name:    FP_ACC.sv
* Project:      Research for Block Floating Point Processing Element
* Module:       FP-Acc (Norm -> Align -> Addition -> FXP2FP) + FP accumulator
* Author:       Marco <harry2963753@gmail.com>
*
******************************************************************************/
`include "include.svh"

module FP_ACC(
    input clk,
    input rst_n,
    input preload, // clears the accumulator
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

    // -----------------------------------------------------------------------
    // Norm : fixed-point dot product -> FP accumulator format
    // Align + Addition + FXP2FP : add into the running accumulator
    // -----------------------------------------------------------------------
    assign fp_a = NORM(dp_sign, dp_mag, blk_exp);
    assign acc_next = FP_ADD(fp_a, acc_reg);

    // -----------------------------------------------------------------------
    // FP register : reset / preload clears, otherwise accumulate
    // -----------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) acc_reg <= '0;
        else if (preload) acc_reg <= '0;
        else acc_reg <= acc_next;
    end

    assign {o_sign, o_exp, o_man} = acc_reg;

endmodule
