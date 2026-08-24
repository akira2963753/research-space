/******************************************************************************
* Copyright (C) 2026 Marco
*
* File Name:    BG_FP_ACC.sv
* Project:      Bucket Getter BFP Processing Element
* Module:       Stateless shared FP32 accumulation service
* Author:       Marco <harry2963753@gmail.com>
*
******************************************************************************/
`include "BG_INCLUDE.svh"

module BG_FP_ACC(
    input logic [`BG_FP_W-1:0] i_psum,
    input logic [`BG_FP_W-1:0] i_term,
    output logic [`BG_FP_W-1:0] o_result
);

    import BG_PKG::*;

    always_comb o_result = FP_ADD(i_psum, i_term);

endmodule
