/******************************************************************************
* Copyright (C) 2026 Marco
*
* File Name:    BG_INT_MAC.sv
* Project:      Bucket Getter BFP Processing Element
* Module:       16-lane signed integer dot-product unit
* Author:       Marco <harry2963753@gmail.com>
*
******************************************************************************/
`include "BG_INCLUDE.svh"

module BG_INT_MAC(
    input logic [`BG_SIGN_BW-1:0] i_w_sign,
    input logic [`BG_SIGN_BW-1:0] i_a_sign,
    input logic [`BG_MAN_BW-1:0] i_w_man,
    input logic [`BG_MAN_BW-1:0] i_a_man,
    output logic signed [`BG_SUM_W-1:0] o_sum
);

    logic [`BG_MAN_W-1:0] w_man [`BG_GSIZE];
    logic [`BG_MAN_W-1:0] a_man [`BG_GSIZE];
    logic [`BG_PROD_W-1:0] product [`BG_GSIZE];
    logic signed [`BG_SPROD_W-1:0] signed_product [`BG_GSIZE];

    genvar gi;
    generate
        for (gi = 0; gi < `BG_GSIZE; gi++) begin : g_lane
            assign w_man[gi] = i_w_man[gi*`BG_MAN_W +: `BG_MAN_W];
            assign a_man[gi] = i_a_man[gi*`BG_MAN_W +: `BG_MAN_W];
            assign product[gi] = w_man[gi] * a_man[gi];
            assign signed_product[gi] = (i_w_sign[gi] ^ i_a_sign[gi])
                                      ? -$signed({1'b0, product[gi]})
                                      : $signed({1'b0, product[gi]});
        end
    endgenerate

    always_comb begin
        o_sum = '0;
        for (int i = 0; i < `BG_GSIZE; i++) o_sum = o_sum + signed_product[i];
    end

endmodule
