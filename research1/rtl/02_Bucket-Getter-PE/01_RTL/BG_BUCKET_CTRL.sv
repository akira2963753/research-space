/******************************************************************************
* Copyright (C) 2026 Marco
*
* File Name:    BG_BUCKET_CTRL.sv
* Project:      Bucket Getter BFP Processing Element
* Module:       Adaptive circular bucket address decoder
* Author:       Marco <harry2963753@gmail.com>
*
******************************************************************************/
`include "BG_INCLUDE.svh"

module BG_BUCKET_CTRL(
    input logic i_emax_valid,
    input logic signed [`BG_BEXP_W-1:0] i_emax_base,
    input logic [`BG_BUCKET_PTR_W-1:0] i_front_ptr,
    input logic signed [`BG_BEXP_W-1:0] i_value_exp,
    output logic signed [`BG_BEXP_W-1:0] o_value_base,
    output logic o_above_window,
    output logic o_below_window,
    output logic o_out_of_bound,
    output logic [`BG_BUCKET_PTR_W-1:0] o_bucket_ptr,
    output logic [`BG_BUCKET_PTR_W-1:0] o_logical_offset,
    output logic [`BG_BUCKET_SHIFT_W-1:0] o_shift
);

    import BG_PKG::*;

    integer exp_delta;
    integer logical_offset;
    integer physical_ptr;

    always_comb begin
        o_value_base = EXP_BASE(i_value_exp);
        o_above_window = 1'b0;
        o_below_window = 1'b0;
        o_out_of_bound = 1'b0;
        o_bucket_ptr = i_front_ptr;
        o_logical_offset = '0;
        o_shift = i_value_exp - o_value_base;
        exp_delta = 0;
        logical_offset = 0;
        physical_ptr = i_front_ptr;

        if (i_emax_valid) begin
            if (o_value_base > i_emax_base) begin
                o_above_window = 1'b1;
            end
            else begin
                exp_delta = i_emax_base - o_value_base;
                logical_offset = exp_delta / `BG_EXP_PER_BUCKET;
                if (logical_offset >= `BG_BUCKET_COUNT) begin
                    o_below_window = 1'b1;
                    o_out_of_bound = exp_delta >= `BG_FP_SIG_W;
                end
                else begin
                    physical_ptr = i_front_ptr + `BG_BUCKET_COUNT
                                 - (logical_offset % `BG_BUCKET_COUNT);
                    o_bucket_ptr = physical_ptr % `BG_BUCKET_COUNT;
                    o_logical_offset = logical_offset[`BG_BUCKET_PTR_W-1:0];
                end
            end
        end
    end

endmodule
