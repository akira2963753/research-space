/******************************************************************************
* Copyright (C) 2026 Marco
*
* File Name:    BFP_PKG.sv
* Project:      Research for Block Floating Point Processing Element
* Module:       FP-Acc primitives (Leading-One Detector / Norm / FP add)
* Author:       Marco <harry2963753@gmail.com>
*
******************************************************************************/
`include "include.svh"

package BFP_PKG;

    // -----------------------------------------------------------------------
    // Leading-One Detectors : return the number of leading zeros, i.e. the
    // left-shift amount that moves the leading one to the MSB. A zero input
    // returns the maximum shift.
    //
    // Two separate detectors on purpose -- they operate on different widths:
    //   LOD_MAG : `BFP_MAG_W bits       (dot-product magnitude, scales with BFP_GSIZE)
    //   LOD_SIG : `FPACC_MAN_W+1 bits   (FP accumulator significand, 24 for FP32)
    // They operate on independently parameterized widths, so they stay distinct.
    // Written as a loop (ascending, last hit wins) so the width is generic.
    // -----------------------------------------------------------------------
    function automatic [`BFP_LOD_W-1:0] LOD_MAG;
        input [`BFP_MAG_W-1:0] val;
        begin
            LOD_MAG = `BFP_MAG_W - 1;
            for (int i = 0; i < `BFP_MAG_W; i++) if (val[i]) LOD_MAG = `BFP_MAG_W - 1 - i;
        end
    endfunction

    function automatic [`FPACC_LOD_W-1:0] LOD_SIG;
        input [`FPACC_MAN_W:0] val;
        begin
            LOD_SIG = `FPACC_MAN_W;
            for (int i = 0; i <= `FPACC_MAN_W; i++) if (val[i]) LOD_SIG = `FPACC_MAN_W - i;
        end
    endfunction

    // -----------------------------------------------------------------------
    // NORM : fixed-point dot product -> FP accumulator format
    //   value = (-1)^sign * mag * 2^(blk_exp-BFP_EXP_BIAS), with mag an
    //   `BFP_MAG_W-bit integer and blk_exp = w_exp + a_exp - BFP_EXP_BIAS.
    //   The fraction below the
    //   leading one is BFP_MAG_W-1 bits wide, which may be shorter OR longer
    //   than FPACC_MAN_W depending on BFP_GSIZE, so it is left-justified into
    //   the mantissa field (zero-padded when short, truncated when long).
    //   Underflow flushes to zero; overflow saturates.
    // -----------------------------------------------------------------------
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
            if (mag != 0) begin
                lz = LOD_MAG(mag);
                norm_mag = mag << lz; // leading one -> MSB
                out_exp = $signed(blk_exp) + (`FPACC_EXP_BIAS - `BFP_EXP_BIAS) + ((`BFP_MAG_W-1) - lz); // rebias + leading-one index
                wide = {norm_mag, {`FPACC_MAN_W{1'b0}}}; // leading one -> bit MAG_W-1+MAN_W
                // G16/M3/FP32: leading one is wide[32], mantissa is wide[31:9].
                man = wide[(`BFP_MAG_W-1+`FPACC_MAN_W)-1 -: `FPACC_MAN_W];
                if (out_exp <= 0) NORM = '0; // underflow -> zero
                else if (out_exp >= (2**`FPACC_EXP_W)-1) NORM = {sign, {`FPACC_EXP_W{1'b1}}, {`FPACC_MAN_W{1'b1}}}; // overflow -> saturate
                else NORM = {sign, out_exp[`FPACC_EXP_W-1:0], man};
            end
        end
    endfunction

    // -----------------------------------------------------------------------
    // FP_ADD : Align -> Addition -> FXP2FP (post-normalize)
    //   exp == 0 denotes zero (no subnormals). Uses truncation, flush-to-zero,
    //   and saturation rather than IEEE rounding or special values.
    // -----------------------------------------------------------------------
    function automatic [`FPACC_W-1:0] FP_ADD;
        input [`FPACC_W-1:0] A, B;

        logic A_sign, B_sign, Result_sign;
        logic [`FPACC_EXP_W-1:0] A_exp, B_exp, Result_exp, Exp_diff;
        logic [`FPACC_MAN_W-1:0] A_man, B_man, Result_man;
        logic [`FPACC_MAN_W:0] A_sig, B_sig; // 24-bit {1, man}
        logic [`FPACC_MAN_W+1:0] Result_add; // 25-bit (carry headroom)
        logic [`FPACC_LOD_W-1:0] lod_shift;
        begin
            {A_sign, A_exp, A_man} = A;
            {B_sign, B_exp, B_man} = B;

            if (A_exp == 0) FP_ADD = B; // A is zero
            else if (B_exp == 0) FP_ADD = A; // B is zero
            else begin
                FP_ADD = '0;
                // ---- Align : shift the smaller-exponent significand right ----
                if (A_exp >= B_exp) begin
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
                // ---- Addition : add on equal signs, else subtract ----
                if (A_sign == B_sign) begin
                    Result_add = A_sig + B_sig;
                    Result_sign = A_sign;
                end
                else if (A_sig >= B_sig) begin
                    Result_add = A_sig - B_sig;
                    Result_sign = A_sign;
                end
                else begin
                    Result_add = B_sig - A_sig;
                    Result_sign = B_sign;
                end
                // ---- FXP2FP : renormalize back to FP accumulator format ----
                if (Result_add[`FPACC_MAN_W+1]) begin // carry overflow
                    Result_add = Result_add >> 1;
                    Result_man = Result_add[`FPACC_MAN_W-1 -: `FPACC_MAN_W];
                    if (Result_exp >= (2**`FPACC_EXP_W)-2) FP_ADD = {Result_sign, {`FPACC_EXP_W{1'b1}}, {`FPACC_MAN_W{1'b1}}}; // overflow -> saturate
                    else begin
                        Result_exp = Result_exp + 1;
                        FP_ADD = {Result_sign, Result_exp, Result_man};
                    end
                end
                else if (Result_add == 0) FP_ADD = '0; // exact cancel
                else begin
                    lod_shift = LOD_SIG(Result_add[`FPACC_MAN_W:0]);
                    if (Result_exp > lod_shift) begin
                        Result_add = Result_add << lod_shift;
                        Result_exp = Result_exp - lod_shift;
                        Result_man = Result_add[`FPACC_MAN_W-1 -: `FPACC_MAN_W];
                        FP_ADD = {Result_sign, Result_exp, Result_man};
                    end
                    else FP_ADD = '0; // underflow
                end
            end
        end
    endfunction

endpackage
