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
        begin
            EXP_BASE = (exp_value >>> `BG_BUCKET_SHIFT_W)
                     <<< `BG_BUCKET_SHIFT_W;
        end
    endfunction

    function automatic [`BG_BUCKET_PTR_W-1:0] PTR_INC;
        input [`BG_BUCKET_PTR_W-1:0] ptr;
        begin
            if(ptr == `BG_BUCKET_COUNT-1) PTR_INC = '0;
            else PTR_INC = ptr + 1'b1;
        end
    endfunction

    function automatic [`BG_BUCKET_PTR_W-1:0] PTR_DEC;
        input [`BG_BUCKET_PTR_W-1:0] ptr;
        begin
            if(ptr == 0)
                PTR_DEC = `BG_BUCKET_COUNT-1;
            else
                PTR_DEC = ptr - 1'b1;
        end
    endfunction

    function automatic [`BG_BUCKET_PTR_W-1:0] PTR_ADD;
        input [`BG_BUCKET_PTR_W-1:0] ptr;
        input integer amount;
        begin
            case(amount)
                1: PTR_ADD = PTR_INC(ptr);
                2: PTR_ADD = PTR_INC(PTR_INC(ptr));
                3: PTR_ADD = PTR_INC(PTR_INC(PTR_INC(ptr)));
                4: PTR_ADD = PTR_INC(PTR_INC(PTR_INC(PTR_INC(ptr))));
                5: PTR_ADD = PTR_INC(PTR_INC(PTR_INC(PTR_INC(PTR_INC(ptr)))));
                default: PTR_ADD = ptr;
            endcase
        end
    endfunction

    function automatic [`BG_BUCKET_PTR_W-1:0] PTR_SUB;
        input [`BG_BUCKET_PTR_W-1:0] ptr;
        input integer amount;
        begin
            case(amount)
                1: PTR_SUB = PTR_DEC(ptr);
                2: PTR_SUB = PTR_DEC(PTR_DEC(ptr));
                3: PTR_SUB = PTR_DEC(PTR_DEC(PTR_DEC(ptr)));
                4: PTR_SUB = PTR_DEC(PTR_DEC(PTR_DEC(PTR_DEC(ptr))));
                5: PTR_SUB = PTR_DEC(PTR_DEC(PTR_DEC(PTR_DEC(PTR_DEC(ptr)))));
                default: PTR_SUB = ptr;
            endcase
        end
    endfunction

    function automatic integer WORK_TOP_OFFSET;
        input signed [`BG_WORK_W-1:0] work_value;
        logic signed [`BG_WORK_W-1:0] remaining_value;
        logic signed [`BG_LOGICAL_BUCKET_WIDTH-1:0] digit_value;
        logic signed [`BG_WORK_W-1:0] digit_extended;
        begin
            WORK_TOP_OFFSET = 0;
            remaining_value = work_value;
            digit_value = '0;
            digit_extended = '0;
            for(int i = 0; i < `BG_WORK_DIGITS; i++) begin
                if(remaining_value != 0) begin
                    WORK_TOP_OFFSET = i;
                    digit_value = remaining_value[`BG_LOGICAL_BUCKET_WIDTH-1:0];
                    digit_extended = {
                        {(`BG_WORK_W-`BG_LOGICAL_BUCKET_WIDTH){
                            digit_value[`BG_LOGICAL_BUCKET_WIDTH-1]
                        }},
                        digit_value
                    };
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
