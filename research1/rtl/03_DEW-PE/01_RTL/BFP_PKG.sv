/******************************************************************************
* Copyright (C) 2026 Marco
*
* File Name:    BFP_PKG.sv
* Project:      Dynamic Exponent Window Accumulation Based PE
* Module:       FP Accumulator Arithmetic Package
* Author:       Marco <harry2963753@gmail.com>
*
******************************************************************************/
`include "include.vh"

package BFP_PKG;

    function automatic [`BFP_LOD_W-1:0] LOD_MAG(
        input logic [`BFP_MAG_W-1:0] value
    );
        begin
            LOD_MAG = `BFP_MAG_W - 1;
            for(int i = 0; i < `BFP_MAG_W; i++) if(value[i]) LOD_MAG = `BFP_MAG_W - 1 - i;
        end
    endfunction

    function automatic [`FPACC_LOD_W-1:0] LOD_SIG(
        input logic [`FPACC_MAN_W:0] value
    );
        begin
            LOD_SIG = `FPACC_MAN_W;
            for(int i = 0; i <= `FPACC_MAN_W; i++) if(value[i]) LOD_SIG = `FPACC_MAN_W - i;
        end
    endfunction

    function automatic [`FPACC_W-1:0] NORM(
        input logic sign,
        input logic [`BFP_MAG_W-1:0] mag,
        input logic signed [`BFP_BEXP_W-1:0] blk_exp
    );
        logic [`BFP_LOD_W-1:0] leading_zero;
        logic [`BFP_MAG_W-1:0] norm_mag;
        logic [`BFP_MAG_W+`FPACC_MAN_W-1:0] wide_mag;
        logic signed [`FPACC_CALC_EXP_W-1:0] result_exp;
        logic [`FPACC_MAN_W-1:0] result_man;
        begin
            NORM = '0;
            leading_zero = '0;
            norm_mag = '0;
            wide_mag = '0;
            result_exp = '0;
            result_man = '0;
            if(mag != 0) begin
                leading_zero = LOD_MAG(mag);
                norm_mag = mag << leading_zero;
                result_exp = $signed(blk_exp)
                           + (`FPACC_EXP_BIAS - `BFP_EXP_BIAS)
                           + $signed((`BFP_MAG_W - 1) - leading_zero);
                wide_mag = {norm_mag, {`FPACC_MAN_W{1'b0}}};
                result_man = wide_mag[(`BFP_MAG_W+`FPACC_MAN_W-2) -: `FPACC_MAN_W];
                if(result_exp <= 0) NORM = '0;
                else if(result_exp >= (2**`FPACC_EXP_W)-1) NORM = {sign, {`FPACC_EXP_W{1'b1}}, {`FPACC_MAN_W{1'b1}}};
                else NORM = {sign, result_exp[`FPACC_EXP_W-1:0], result_man};
            end
        end
    endfunction

    function automatic [`FPACC_W-1:0] FP_ADD(
        input logic [`FPACC_W-1:0] a,
        input logic [`FPACC_W-1:0] b
    );
        logic a_sign, b_sign, result_sign;
        logic [`FPACC_EXP_W-1:0] a_exp, b_exp, result_exp, exp_diff;
        logic [`FPACC_MAN_W-1:0] a_man, b_man, result_man;
        logic [`FPACC_MAN_W:0] a_sig, b_sig;
        logic [`FPACC_MAN_W+1:0] result_add;
        logic [`FPACC_LOD_W-1:0] lod_shift;
        begin
            {a_sign, a_exp, a_man} = a;
            {b_sign, b_exp, b_man} = b;
            result_sign = 1'b0;
            result_exp = '0;
            result_man = '0;
            exp_diff = '0;
            a_sig = '0;
            b_sig = '0;
            result_add = '0;
            lod_shift = '0;

            if(a_exp == 0) FP_ADD = b;
            else if(b_exp == 0) FP_ADD = a;
            else begin
                FP_ADD = '0;
                if(a_exp >= b_exp) begin
                    exp_diff = a_exp - b_exp;
                    result_exp = a_exp;
                    a_sig = {1'b1, a_man};
                    b_sig = {1'b1, b_man} >> exp_diff;
                end
                else begin
                    exp_diff = b_exp - a_exp;
                    result_exp = b_exp;
                    a_sig = {1'b1, a_man} >> exp_diff;
                    b_sig = {1'b1, b_man};
                end

                if(a_sign == b_sign) begin
                    result_add = a_sig + b_sig;
                    result_sign = a_sign;
                end
                else if(a_sig >= b_sig) begin
                    result_add = a_sig - b_sig;
                    result_sign = a_sign;
                end
                else begin
                    result_add = b_sig - a_sig;
                    result_sign = b_sign;
                end

                if(result_add[`FPACC_MAN_W+1]) begin
                    result_add = result_add >> 1;
                    result_man = result_add[`FPACC_MAN_W-1 -: `FPACC_MAN_W];
                    if(result_exp >= (2**`FPACC_EXP_W)-2) FP_ADD = {result_sign, {`FPACC_EXP_W{1'b1}}, {`FPACC_MAN_W{1'b1}}};
                    else begin
                        result_exp = result_exp + 1'b1;
                        FP_ADD = {result_sign, result_exp, result_man};
                    end
                end
                else if(result_add == 0) FP_ADD = '0;
                else begin
                    lod_shift = LOD_SIG(result_add[`FPACC_MAN_W:0]);
                    if(result_exp > lod_shift) begin
                        result_add = result_add << lod_shift;
                        result_exp = result_exp - lod_shift;
                        result_man = result_add[`FPACC_MAN_W-1 -: `FPACC_MAN_W];
                        FP_ADD = {result_sign, result_exp, result_man};
                    end
                    else FP_ADD = '0;
                end
            end
        end
    endfunction

endpackage
