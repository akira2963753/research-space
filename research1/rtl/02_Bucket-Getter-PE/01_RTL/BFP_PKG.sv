/******************************************************************************
* Copyright (C) 2026 Marco
*
* File Name:    BFP_PKG.sv
* Project:      Bucket Getter BFP Processing Element
* Module:       Common FP-Acc normalization and addition primitives
* Author:       Marco <harry2963753@gmail.com>
*
******************************************************************************/
`include "include.vh"

package BFP_PKG;

    function automatic [`BFP_LOD_W-1:0] LOD_MAG;
        input [`BFP_MAG_W-1:0] val;
        begin
            LOD_MAG = `BFP_MAG_W - 1;
            for(int i = 0; i < `BFP_MAG_W; i++) begin
                if(val[i]) LOD_MAG = `BFP_MAG_W - 1 - i;
            end
        end
    endfunction

    function automatic [`FPACC_LOD_W-1:0] LOD_SIG;
        input [`FPACC_MAN_W:0] val;
        begin
            LOD_SIG = `FPACC_MAN_W;
            for(int i = 0; i <= `FPACC_MAN_W; i++) begin
                if(val[i]) LOD_SIG = `FPACC_MAN_W - i;
            end
        end
    endfunction

    function automatic [`FPACC_W-1:0] NORM;
        input sign;
        input [`BFP_MAG_W-1:0] mag;
        input signed [`BFP_BEXP_W-1:0] blk_exp;

        logic [`BFP_LOD_W-1:0] lz;
        logic [`BFP_MAG_W-1:0] norm_mag;
        logic [`BFP_MAG_W+`FPACC_MAN_W-1:0] wide;
        logic signed [`FPACC_CALC_EXP_W-1:0] out_exp;
        logic [`FPACC_MAN_W-1:0] man;
        begin
            NORM = '0;
            if(mag != 0) begin
                lz = LOD_MAG(mag);
                norm_mag = mag << lz;
                out_exp = $signed(blk_exp)
                        + (`FPACC_EXP_BIAS - `BFP_EXP_BIAS)
                        + $signed((`BFP_MAG_W - 1) - lz);
                wide = {norm_mag, {`FPACC_MAN_W{1'b0}}};
                man = wide[(`BFP_MAG_W-1+`FPACC_MAN_W)-1 -: `FPACC_MAN_W];
                if(out_exp <= 0) NORM = '0;
                else if(out_exp >= (2**`FPACC_EXP_W)-1)
                    NORM = {sign, {`FPACC_EXP_W{1'b1}}, {`FPACC_MAN_W{1'b1}}};
                else NORM = {sign, out_exp[`FPACC_EXP_W-1:0], man};
            end
        end
    endfunction

    function automatic [`FPACC_W-1:0] FP_ADD;
        input [`FPACC_W-1:0] A, B;

        logic A_sign, B_sign, Result_sign;
        logic [`FPACC_EXP_W-1:0] A_exp, B_exp, Result_exp, Exp_diff;
        logic [`FPACC_MAN_W-1:0] A_man, B_man, Result_man;
        logic [`FPACC_MAN_W:0] A_sig, B_sig;
        logic [`FPACC_MAN_W+1:0] Result_add;
        logic [`FPACC_LOD_W-1:0] lod_shift;
        begin
            {A_sign, A_exp, A_man} = A;
            {B_sign, B_exp, B_man} = B;

            if(A_exp == 0) FP_ADD = B;
            else if(B_exp == 0) FP_ADD = A;
            else begin
                FP_ADD = '0;
                if(A_exp >= B_exp) begin
                    Exp_diff = A_exp - B_exp;
                    Result_exp = A_exp;
                    A_sig = {1'b1, A_man};
                    B_sig = {1'b1, B_man} >> Exp_diff;
                end
                else begin
                    Exp_diff = B_exp - A_exp;
                    Result_exp = B_exp;
                    A_sig = {1'b1, A_man} >> Exp_diff;
                    B_sig = {1'b1, B_man};
                end

                if(A_sign == B_sign) begin
                    Result_add = A_sig + B_sig;
                    Result_sign = A_sign;
                end
                else if(A_sig >= B_sig) begin
                    Result_add = A_sig - B_sig;
                    Result_sign = A_sign;
                end
                else begin
                    Result_add = B_sig - A_sig;
                    Result_sign = B_sign;
                end

                if(Result_add[`FPACC_MAN_W+1]) begin
                    Result_add = Result_add >> 1;
                    Result_man = Result_add[`FPACC_MAN_W-1 -: `FPACC_MAN_W];
                    if(Result_exp >= (2**`FPACC_EXP_W)-2)
                        FP_ADD = {Result_sign, {`FPACC_EXP_W{1'b1}}, {`FPACC_MAN_W{1'b1}}};
                    else begin
                        Result_exp = Result_exp + 1;
                        FP_ADD = {Result_sign, Result_exp, Result_man};
                    end
                end
                else if(Result_add == 0) FP_ADD = '0;
                else begin
                    lod_shift = LOD_SIG(Result_add[`FPACC_MAN_W:0]);
                    if(Result_exp > lod_shift) begin
                        Result_add = Result_add << lod_shift;
                        Result_exp = Result_exp - lod_shift;
                        Result_man = Result_add[`FPACC_MAN_W-1 -: `FPACC_MAN_W];
                        FP_ADD = {Result_sign, Result_exp, Result_man};
                    end
                    else FP_ADD = '0;
                end
            end
        end
    endfunction

endpackage
