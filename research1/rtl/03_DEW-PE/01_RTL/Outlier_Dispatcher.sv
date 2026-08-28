/******************************************************************************
* Copyright (C) 2026 Marco
*
* File Name:    Outlier_Dispatcher.sv
* Project:      Dynamic Exponent Window Accumulation Based PE
* Module:       Outlier Dispatcher
* Author:       Marco <harry2963753@gmail.com>
*
******************************************************************************/
`include "include.vh"

module Outlier_Dispatcher (
    input logic [`BFP_SIGN_BW-1:0] w_sign_b,
    input logic [`BFP_SIGN_BW-1:0] a_sign_b,
    input logic [`BFP_MAN_BW-1:0] w_man_b,
    input logic [`BFP_MAN_BW-1:0] a_man_b,
    input logic [`OI_W-1:0] oi1,
    input logic [`OI_W-1:0] oi2,
    output logic [`BFP_SIGN_BW-1:0] routed_w_sign_b,
    output logic [`BFP_SIGN_BW-1:0] routed_a_sign_b,
    output logic [`BFP_MAN_BW-1:0] routed_w_man_b,
    output logic [`BFP_MAN_BW-1:0] routed_a_man_b,
    output logic outlier1_valid,
    output logic outlier2_valid
);

    localparam int LANE_PAYLOAD_W = 2 + 2*`BFP_MAN_W;
    localparam logic [`OI_W-1:0] OP1_LANE = `BFP_GSIZE - 1;
    localparam logic [`OI_W-1:0] OP2_LANE = `BFP_GSIZE - 2;

    logic no_outlier;
    logic [`OI_W-1:0] oi2_position;
    logic [LANE_PAYLOAD_W-1:0] lane_input [0:`BFP_GSIZE-1];
    logic [LANE_PAYLOAD_W-1:0] lane_stage1 [0:`BFP_GSIZE-1];
    logic [LANE_PAYLOAD_W-1:0] lane_stage2 [0:`BFP_GSIZE-1];

    always_comb begin : LANE_ROUTING
        no_outlier = &(oi1 & oi2);
        outlier1_valid = !no_outlier;
        outlier2_valid = !no_outlier && oi2 != '0;
        oi2_position = oi2;
        routed_w_sign_b = '0;
        routed_a_sign_b = '0;
        routed_w_man_b = '0;
        routed_a_man_b = '0;

        for(int i = 0; i < `BFP_GSIZE; i++) begin
            lane_input[i] = {
                w_sign_b[i],
                a_sign_b[i],
                w_man_b[i*`BFP_MAN_W +: `BFP_MAN_W],
                a_man_b[i*`BFP_MAN_W +: `BFP_MAN_W]
            };
            lane_stage1[i] = lane_input[i];
        end

        if(outlier1_valid) begin
            lane_stage1[OP1_LANE] = lane_input[oi1];
            lane_stage1[oi1] = lane_input[OP1_LANE];
        end

        for(int i = 0; i < `BFP_GSIZE; i++) lane_stage2[i] = lane_stage1[i];

        if(outlier2_valid) begin
            oi2_position = (oi2 == OP1_LANE)? oi1 : oi2;
            lane_stage2[OP2_LANE] = lane_stage1[oi2_position];
            lane_stage2[oi2_position] = lane_stage1[OP2_LANE];
        end

        for(int i = 0; i < `BFP_GSIZE; i++) begin
            {
                routed_w_sign_b[i],
                routed_a_sign_b[i],
                routed_w_man_b[i*`BFP_MAN_W +: `BFP_MAN_W],
                routed_a_man_b[i*`BFP_MAN_W +: `BFP_MAN_W]
            } = lane_stage2[i];
        end
    end

endmodule
