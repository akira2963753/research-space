/******************************************************************************
* Copyright (C) 2026 Marco
*
* File Name:    BG_PKG.sv
* Project:      Bucket Getter BFP Processing Element
* Module:       Bucket mapping and FP32 reconstruction primitives
* Author:       Marco <harry2963753@gmail.com>
*
******************************************************************************/
`include "BG_INCLUDE.svh"

package BG_PKG;

    function automatic signed [`BG_BEXP_W-1:0] EXP_BASE;
        input signed [`BG_BEXP_W-1:0] exp_value;
        integer rem_value;
        begin
            rem_value = exp_value % `BG_EXP_PER_BUCKET;
            if (rem_value < 0) rem_value = rem_value + `BG_EXP_PER_BUCKET;
            EXP_BASE = exp_value - rem_value;
        end
    endfunction

    function automatic [`BG_BUCKET_PTR_W-1:0] PTR_INC;
        input [`BG_BUCKET_PTR_W-1:0] ptr;
        begin
            if (ptr == `BG_BUCKET_COUNT-1) PTR_INC = '0;
            else PTR_INC = ptr + 1'b1;
        end
    endfunction

    function automatic [`BG_BUCKET_PTR_W-1:0] PTR_SUB;
        input [`BG_BUCKET_PTR_W-1:0] ptr;
        input integer amount;
        integer value;
        integer amount_mod;
        begin
            amount_mod = amount % `BG_BUCKET_COUNT;
            value = ptr + `BG_BUCKET_COUNT - amount_mod;
            PTR_SUB = value % `BG_BUCKET_COUNT;
        end
    endfunction

    function automatic [`BG_FP_W-1:0] FP_ADD;
        input [`BG_FP_W-1:0] a;
        input [`BG_FP_W-1:0] b;
        logic a_sign;
        logic b_sign;
        logic result_sign;
        logic [`BG_FP_EXP_W-1:0] a_exp;
        logic [`BG_FP_EXP_W-1:0] b_exp;
        logic [`BG_FP_EXP_W-1:0] result_exp;
        logic [`BG_FP_EXP_W-1:0] exp_diff;
        logic [`BG_FP_MAN_W-1:0] a_man;
        logic [`BG_FP_MAN_W-1:0] b_man;
        logic [`BG_FP_MAN_W-1:0] result_man;
        logic [`BG_FP_MAN_W:0] a_sig;
        logic [`BG_FP_MAN_W:0] b_sig;
        logic [`BG_FP_MAN_W+1:0] result_add;
        integer shift_count;
        begin
            {a_sign, a_exp, a_man} = a;
            {b_sign, b_exp, b_man} = b;
            FP_ADD = '0;

            if (a_exp == 0) FP_ADD = b;
            else if (b_exp == 0) FP_ADD = a;
            else begin
                if (a_exp >= b_exp) begin
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

                if (a_sign == b_sign) begin
                    result_add = a_sig + b_sig;
                    result_sign = a_sign;
                end
                else if (a_sig >= b_sig) begin
                    result_add = a_sig - b_sig;
                    result_sign = a_sign;
                end
                else begin
                    result_add = b_sig - a_sig;
                    result_sign = b_sign;
                end

                if (result_add[`BG_FP_MAN_W+1]) begin
                    result_add = result_add >> 1;
                    if (result_exp >= {`BG_FP_EXP_W{1'b1}}-1'b1) begin
                        FP_ADD = {result_sign, {`BG_FP_EXP_W{1'b1}}, {`BG_FP_MAN_W{1'b1}}};
                    end
                    else begin
                        result_exp = result_exp + 1'b1;
                        result_man = result_add[`BG_FP_MAN_W-1:0];
                        FP_ADD = {result_sign, result_exp, result_man};
                    end
                end
                else if (result_add != 0) begin
                    shift_count = 0;
                    for (int i = 0; i <= `BG_FP_MAN_W; i++) begin
                        if (result_add[i]) shift_count = `BG_FP_MAN_W - i;
                    end
                    if (result_exp > shift_count) begin
                        result_add = result_add << shift_count;
                        result_exp = result_exp - shift_count;
                        result_man = result_add[`BG_FP_MAN_W-1:0];
                        FP_ADD = {result_sign, result_exp, result_man};
                    end
                end
            end
        end
    endfunction

    function automatic [`BG_FP_W-1:0] SUM_TO_FP;
        input signed [`BG_SUM_W-1:0] sum_value;
        input signed [`BG_BEXP_W-1:0] value_exp;
        logic sign_value;
        logic [`BG_SUM_W-1:0] magnitude;
        logic [`BG_FP_MAN_W-1:0] man_value;
        integer leading_index;
        integer fp_exp_value;
        integer source_index;
        begin
            SUM_TO_FP = '0;
            sign_value = sum_value[`BG_SUM_W-1];
            magnitude = sign_value ? -sum_value : sum_value;
            if (magnitude != 0) begin
                leading_index = 0;
                for (int i = 0; i < `BG_SUM_W; i++) begin
                    if (magnitude[i]) leading_index = i;
                end
                man_value = '0;
                for (int j = 0; j < `BG_FP_MAN_W; j++) begin
                    source_index = leading_index - 1 - j;
                    if (source_index >= 0) man_value[`BG_FP_MAN_W-1-j] = magnitude[source_index];
                end
                fp_exp_value = value_exp + (`BG_FP_EXP_BIAS-`BG_EXP_BIAS) + leading_index;
                if (fp_exp_value > 0 && fp_exp_value < (2**`BG_FP_EXP_W)-1) begin
                    SUM_TO_FP = {sign_value, fp_exp_value[`BG_FP_EXP_W-1:0], man_value};
                end
                else if (fp_exp_value >= (2**`BG_FP_EXP_W)-1) begin
                    SUM_TO_FP = {sign_value, {`BG_FP_EXP_W{1'b1}}, {`BG_FP_MAN_W{1'b1}}};
                end
            end
        end
    endfunction

    function automatic [`BG_FP_W-1:0] BUCKET_TO_FP;
        input signed [`BG_BUCKET_WIDTH-1:0] bucket_value;
        input signed [`BG_BEXP_W-1:0] bucket_base;
        logic sign_value;
        logic [`BG_BUCKET_WIDTH-1:0] magnitude;
        logic [`BG_FP_MAN_W-1:0] man_value;
        integer leading_index;
        integer fp_exp_value;
        integer source_index;
        begin
            BUCKET_TO_FP = '0;
            sign_value = bucket_value[`BG_BUCKET_WIDTH-1];
            magnitude = sign_value ? -bucket_value : bucket_value;
            if (magnitude != 0) begin
                leading_index = 0;
                for (int i = 0; i < `BG_BUCKET_WIDTH; i++) begin
                    if (magnitude[i]) leading_index = i;
                end
                man_value = '0;
                for (int j = 0; j < `BG_FP_MAN_W; j++) begin
                    source_index = leading_index - 1 - j;
                    if (source_index >= 0) man_value[`BG_FP_MAN_W-1-j] = magnitude[source_index];
                end
                fp_exp_value = bucket_base + (`BG_FP_EXP_BIAS-`BG_EXP_BIAS) + leading_index;
                if (fp_exp_value > 0 && fp_exp_value < (2**`BG_FP_EXP_W)-1) begin
                    BUCKET_TO_FP = {sign_value, fp_exp_value[`BG_FP_EXP_W-1:0], man_value};
                end
                else if (fp_exp_value >= (2**`BG_FP_EXP_W)-1) begin
                    BUCKET_TO_FP = {sign_value, {`BG_FP_EXP_W{1'b1}}, {`BG_FP_MAN_W{1'b1}}};
                end
            end
        end
    endfunction

endpackage
