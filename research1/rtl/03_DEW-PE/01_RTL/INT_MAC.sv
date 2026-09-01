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
    input logic [`OI_W-1:0] oi1,
    input logic [`OI_W-1:0] oi2,
    output logic signed [`BFP_SUM_W-1:0] normal_psum,
    output logic outlier_sign,
    output logic [`BFP_SPROD_W-1:0] outlier_mag
);

    //=============================================================
    //                    Per-Lane Multiplication
    //=============================================================
    logic [`BFP_MAN_W-1:0] w_man [0:`BFP_GSIZE-1];
    logic [`BFP_MAN_W-1:0] a_man [0:`BFP_GSIZE-1];
    logic [`BFP_PROD_W-1:0] prod [0:`BFP_GSIZE-1];
    logic signed [`BFP_SPROD_W-1:0] lane_sprod [0:`BFP_GSIZE-1];
    logic [`BFP_SPROD_BW-1:0] sprod_b;
    logic [`BFP_SPROD_BW-1:0] routed_sprod_b;
    logic signed [`BFP_SPROD_W-1:0] routed_sprod [0:`BFP_GSIZE-1];

    generate
        for(genvar i = 0; i < `BFP_GSIZE; i++) begin : LANE_GEN
            assign w_man[i] = w_man_b[i*`BFP_MAN_W +: `BFP_MAN_W];
            assign a_man[i] = a_man_b[i*`BFP_MAN_W +: `BFP_MAN_W];
            assign prod[i] = w_man[i] * a_man[i];

            // transfer to signed product
            assign lane_sprod[i] = (w_sign_b[i] ^ a_sign_b[i])? -$signed({1'b0, prod[i]}) : $signed({1'b0, prod[i]});
            assign sprod_b[i*`BFP_SPROD_W +: `BFP_SPROD_W] = lane_sprod[i];

            // unpacked from outlier dispatcher
            assign routed_sprod[i] = $signed(routed_sprod_b[i*`BFP_SPROD_W +: `BFP_SPROD_W]);
        end
    endgenerate

    //=============================================================
    //                  Signed Product Dispatch
    //=============================================================
    logic no_outlier, one_outlier;

    Outlier_Dispatcher u_outlier_dispatcher (
        .sprod_b(sprod_b),
        .oi1(oi1),
        .oi2(oi2),
        .routed_sprod_b(routed_sprod_b),
        .no_outlier(no_outlier),
        .one_outlier(one_outlier)
    );

    //=============================================================
    //               Architecture Mux / DMux Routing
    //=============================================================
    logic signed [`BFP_SPROD_W-1:0] opsum1, opsum2;
    logic signed [`BFP_SPROD_W-1:0] op1_to_tail;
    logic signed [`BFP_SPROD_W:0] tail_sum;
    logic signed [`BFP_SPROD_W:0] tail_to_normal;
    logic signed [`BFP_SPROD_W:0] outlier_sum;
    logic [`BFP_SPROD_W:0] outlier_abs;

    assign opsum1 = routed_sprod[`BFP_GSIZE-1];
    assign opsum2 = routed_sprod[`BFP_GSIZE-2];
    assign op1_to_tail = (one_outlier)? '0 : opsum1;
    assign tail_sum =
        $signed({opsum2[`BFP_SPROD_W-1], opsum2}) +
        $signed({op1_to_tail[`BFP_SPROD_W-1], op1_to_tail});
    assign outlier_sum = (no_outlier)?
                         '0 :
                         (one_outlier)?
                         $signed({opsum1[`BFP_SPROD_W-1], opsum1}) : tail_sum;
    assign tail_to_normal = (no_outlier || one_outlier)? tail_sum : '0;
    assign outlier_abs = (outlier_sum[`BFP_SPROD_W])? $unsigned(-outlier_sum) : $unsigned(outlier_sum);
    assign outlier_sign = outlier_sum[`BFP_SPROD_W];
    assign outlier_mag = outlier_abs[`BFP_SPROD_W-1:0];

    //=============================================================
    //                    Four-Stage Adder Tree
    //=============================================================
    logic signed [`BFP_SPROD_W:0] add_stage1 [0:7];
    logic signed [`BFP_SPROD_W+1:0] add_stage2 [0:3];
    logic signed [`BFP_SPROD_W+2:0] add_stage3 [0:1];
    generate
        for(genvar i = 0; i < 7; i++) begin : ADD_STAGE1_GEN
            assign add_stage1[i] =
                $signed({routed_sprod[2*i][`BFP_SPROD_W-1], routed_sprod[2*i]}) +
                $signed({routed_sprod[2*i+1][`BFP_SPROD_W-1], routed_sprod[2*i+1]});
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
    assign normal_psum =
        $signed({add_stage3[0][`BFP_SPROD_W+2], add_stage3[0]}) +
        $signed({add_stage3[1][`BFP_SPROD_W+2], add_stage3[1]});

endmodule
