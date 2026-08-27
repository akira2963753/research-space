/******************************************************************************
* Copyright (C) 2026 Marco
*
* File Name:    DEW_PE.sv
* Project:      Dynamic Exponent Window Accumulation Based PE
* Module:       DEW Processing Element
* Author:       Marco <harry2963753@gmail.com>
*
******************************************************************************/
`include "include.vh"

module DEW_PE (
    input logic clk,
    input logic rst_n,
    input logic acc_clear,
    input logic weight_load,
    input logic in_valid,
    input logic [`BFP_SIGN_BW-1:0] w_sign_b,
    input logic [`BFP_SIGN_BW-1:0] a_sign_b,
    input logic [`BFP_EXP_W-1:0] w_exp,
    input logic [`BFP_EXP_W-1:0] a_exp,
    input logic [`BFP_EXP_W-1:0] oa_exp,
    input logic [`BFP_MAN_BW-1:0] w_man_b,
    input logic [`BFP_MAN_BW-1:0] a_man_b,
    input logic [`OI_W-1:0] oi1,
    input logic [`OI_W-1:0] oi2,
    output logic in_ready,
    input logic in_last,
    output logic out_valid,
    input logic out_ready,
    output logic o_sign,
    output logic [`FPACC_EXP_W-1:0] o_exp,
    output logic [`FPACC_MAN_W-1:0] o_man,
    output logic busy
);




endmodule