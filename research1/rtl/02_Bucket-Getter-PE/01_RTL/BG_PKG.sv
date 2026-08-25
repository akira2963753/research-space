/******************************************************************************
* Copyright (C) 2026 Marco
*
* File Name:    BG_PKG.sv
* Project:      Bucket Getter BFP Processing Element
* Module:       Adaptive circular bucket helper functions
* Author:       Marco <harry2963753@gmail.com>
*
******************************************************************************/
`include "include.vh"

package BG_PKG;

    function automatic signed [`BFP_BEXP_W-1:0] EXP_BASE;
        input signed [`BFP_BEXP_W-1:0] exp_value;
        integer rem_value;
        begin
            rem_value = exp_value % `BG_EXP_PER_BUCKET;
            if(rem_value < 0) rem_value = rem_value + `BG_EXP_PER_BUCKET;
            EXP_BASE = exp_value - rem_value;
        end
    endfunction

    function automatic [`BG_BUCKET_PTR_W-1:0] PTR_INC;
        input [`BG_BUCKET_PTR_W-1:0] ptr;
        begin
            if(ptr == `BG_BUCKET_COUNT-1) PTR_INC = '0;
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

    function automatic integer WORK_TOP_OFFSET;
        input signed [`BG_WORK_W-1:0] work_value;
        logic signed [`BG_WORK_W-1:0] remaining_value;
        logic signed [`BG_BUCKET_WIDTH-1:0] digit_value;
        logic signed [`BG_WORK_W-1:0] digit_extended;
        begin
            WORK_TOP_OFFSET = 0;
            remaining_value = work_value;
            digit_value = '0;
            digit_extended = '0;
            for(int i = 0; i < `BG_WORK_DIGITS; i++) begin
                if(remaining_value != 0) begin
                    WORK_TOP_OFFSET = i;
                    digit_value = remaining_value[`BG_BUCKET_WIDTH-1:0];
                    digit_extended = {{(`BG_WORK_W-`BG_BUCKET_WIDTH){digit_value[`BG_BUCKET_WIDTH-1]}}, digit_value};
                    remaining_value = (remaining_value - digit_extended) >>> `BG_EXP_PER_BUCKET;
                end
            end
        end
    endfunction

    function automatic [`BFP_MAG_W-1:0] BUCKET_MAG;
        input signed [`BG_BUCKET_WIDTH-1:0] bucket_value;
        logic [`BG_BUCKET_WIDTH-1:0] magnitude;
        begin
            magnitude = bucket_value[`BG_BUCKET_WIDTH-1] ? -bucket_value : bucket_value;
            BUCKET_MAG = {{(`BFP_MAG_W-`BG_BUCKET_WIDTH){1'b0}}, magnitude};
        end
    endfunction

endpackage
