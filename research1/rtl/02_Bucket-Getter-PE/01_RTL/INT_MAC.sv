/******************************************************************************
* Copyright (C) 2026 Marco
*
* File Name:    INT_MAC.sv
* Project:      Bucket Getter BFP Processing Element
* Module:       Common integer MAC used by Baseline and Bucket Getter
* Author:       Marco <harry2963753@gmail.com>
*
******************************************************************************/
`include "include.vh"

module INT_MAC(
    input [`BFP_SIGN_BW-1:0] w_sign_b,
    input [`BFP_SIGN_BW-1:0] a_sign_b,
    input [`BFP_MAN_BW-1:0] w_man_b,
    input [`BFP_MAN_BW-1:0] a_man_b,
    output dp_sign,
    output [`BFP_MAG_W-1:0] dp_mag
);

    logic [`BFP_MAN_W-1:0] w_man [`BFP_GSIZE];
    logic [`BFP_MAN_W-1:0] a_man [`BFP_GSIZE];
    logic w_sign [`BFP_GSIZE];
    logic a_sign [`BFP_GSIZE];

    genvar gi;
    generate
        for(gi = 0; gi < `BFP_GSIZE; gi++) begin : g_unpack
            assign w_man[gi] = w_man_b[gi*`BFP_MAN_W +: `BFP_MAN_W];
            assign a_man[gi] = a_man_b[gi*`BFP_MAN_W +: `BFP_MAN_W];
            assign w_sign[gi] = w_sign_b[gi];
            assign a_sign[gi] = a_sign_b[gi];
        end
    endgenerate

    logic [`BFP_PROD_W-1:0] prod [`BFP_GSIZE];
    logic psign [`BFP_GSIZE];
    logic signed [`BFP_SPROD_W-1:0] sprod [`BFP_GSIZE];

    generate
        for(gi = 0; gi < `BFP_GSIZE; gi++) begin : g_mul
            assign prod[gi] = w_man[gi] * a_man[gi];
            assign psign[gi] = w_sign[gi] ^ a_sign[gi];
            assign sprod[gi] = psign[gi] ? -$signed({1'b0, prod[gi]})
                                         : $signed({1'b0, prod[gi]});
        end
    endgenerate

    logic signed [`BFP_SUM_W-1:0] sum;

    always_comb begin
        sum = '0;
        for(int i = 0; i < `BFP_GSIZE; i++) begin
            sum = sum + sprod[i];
        end
    end

    assign dp_sign = sum[`BFP_SUM_W-1];
    assign dp_mag = sum[`BFP_SUM_W-1] ? -sum : sum;

endmodule
