/******************************************************************************
* Copyright (C) 2026 Marco
*
* File Name:    INT_MAC.sv
* Project:      Dynamic Exponent Window Accumulation Based PE
* Module:       Integer MAC with Outlier-Aware Adder Tree
* Author:       Marco <harry2963753@gmail.com>
*
******************************************************************************/
`include "include.vh"

module INT_MAC (
    input logic [`BFP_SIGN_BW-1:0] w_sign_b,
    input logic [`BFP_SIGN_BW-1:0] a_sign_b,
    input logic [`BFP_MAN_BW-1:0] w_man_b,
    input logic [`BFP_MAN_BW-1:0] a_man_b,
    input logic outlier1_valid,
    input logic outlier2_valid,
    output logic normal_sign,
    output logic [`BFP_MAG_W-1:0] normal_mag,
    output logic outlier_sign,
    output logic [`BFP_SPROD_W-1:0] outlier_mag
);

    //=============================================================
    //                    Per-Lane Multiplication
    //=============================================================
    logic [`BFP_MAN_W-1:0] w_man [0:`BFP_GSIZE-1];
    logic [`BFP_MAN_W-1:0] a_man [0:`BFP_GSIZE-1];
    logic [`BFP_PROD_W-1:0] prod [0:`BFP_GSIZE-1];
    logic signed [`BFP_SPROD_W-1:0] sprod [0:`BFP_GSIZE-1];

    generate
        for(genvar i = 0; i < `BFP_GSIZE; i++) begin : LANE_GEN
            assign w_man[i] = w_man_b[i*`BFP_MAN_W +: `BFP_MAN_W];
            assign a_man[i] = a_man_b[i*`BFP_MAN_W +: `BFP_MAN_W];
            assign prod[i] = w_man[i] * a_man[i];
            assign sprod[i] = (w_sign_b[i] ^ a_sign_b[i])?
                              -$signed({1'b0, prod[i]}) :
                              $signed({1'b0, prod[i]});
        end
    endgenerate

    //=============================================================
    //               Architecture Mux / DMux Routing
    //=============================================================
    logic one_outlier, two_outliers;
    logic signed [`BFP_SPROD_W-1:0] opsum1, opsum2;
    logic signed [`BFP_SPROD_W-1:0] op1_to_tail, op1_to_outlier;
    logic signed [`BFP_SPROD_W:0] tail_sum;
    logic signed [`BFP_SPROD_W:0] tail_to_normal, tail_to_outlier;
    logic signed [`BFP_SPROD_W:0] outlier_sum;
    logic [`BFP_SPROD_W:0] outlier_abs;

    assign one_outlier = outlier1_valid && !outlier2_valid;
    assign two_outliers = outlier2_valid;
    assign opsum1 = sprod[`BFP_GSIZE-1];
    assign opsum2 = sprod[`BFP_GSIZE-2];

    assign op1_to_tail = (one_outlier)? '0 : opsum1;
    assign op1_to_outlier = (one_outlier)? opsum1 : '0;

    assign tail_sum =
        $signed({opsum2[`BFP_SPROD_W-1], opsum2}) +
        $signed({op1_to_tail[`BFP_SPROD_W-1], op1_to_tail});

    assign tail_to_normal = (two_outliers)? '0 : tail_sum;
    assign tail_to_outlier = (two_outliers)? tail_sum : '0;

    assign outlier_sum = (one_outlier)?
                          $signed({op1_to_outlier[`BFP_SPROD_W-1], op1_to_outlier}) :
                          tail_to_outlier;
    assign outlier_abs = (outlier_sum[`BFP_SPROD_W])?
                         $unsigned(-outlier_sum) : $unsigned(outlier_sum);
    assign outlier_sign = outlier_sum[`BFP_SPROD_W];
    assign outlier_mag = outlier_abs[`BFP_SPROD_W-1:0];

    //=============================================================
    //                    Four-Stage Adder Tree
    //=============================================================
    logic signed [`BFP_SPROD_W:0] add_stage1 [0:7];
    logic signed [`BFP_SPROD_W+1:0] add_stage2 [0:3];
    logic signed [`BFP_SPROD_W+2:0] add_stage3 [0:1];
    logic signed [`BFP_SUM_W-1:0] normal_sum;
    logic [`BFP_SUM_W-1:0] normal_abs;

    generate
        for(genvar i = 0; i < 7; i++) begin : ADD_STAGE1_GEN
            assign add_stage1[i] =
                $signed({sprod[2*i][`BFP_SPROD_W-1], sprod[2*i]}) +
                $signed({sprod[2*i+1][`BFP_SPROD_W-1], sprod[2*i+1]});
        end
        for(genvar i = 0; i < 4; i++) begin : ADD_STAGE2_GEN
            assign add_stage2[i] =
                $signed({add_stage1[2*i][`BFP_SPROD_W], add_stage1[2*i]}) +
                $signed({add_stage1[2*i+1][`BFP_SPROD_W], add_stage1[2*i+1]});
        end
        for(genvar i = 0; i < 2; i++) begin : ADD_STAGE3_GEN
            assign add_stage3[i] =
                $signed({add_stage2[2*i][`BFP_SPROD_W+1], add_stage2[2*i]}) +
                $signed({add_stage2[2*i+1][`BFP_SPROD_W+1], add_stage2[2*i+1]});
        end
    endgenerate

    assign add_stage1[7] = tail_to_normal;
    assign normal_sum =
        $signed({add_stage3[0][`BFP_SPROD_W+2], add_stage3[0]}) +
        $signed({add_stage3[1][`BFP_SPROD_W+2], add_stage3[1]});
    assign normal_abs = (normal_sum[`BFP_SUM_W-1])?
                        $unsigned(-normal_sum) : $unsigned(normal_sum);
    assign normal_sign = normal_sum[`BFP_SUM_W-1];
    assign normal_mag = normal_abs[`BFP_MAG_W-1:0];

endmodule
