/******************************************************************************
* Copyright (C) 2026 Marco
*
* File Name:    Outlier_Dispatcher.sv
* Project:      Dynamic Exponent Window Accumulation Based PE
* Module:       Signed Product Outlier Dispatcher
* Author:       Marco <harry2963753@gmail.com>
*
******************************************************************************/
`include "include.vh"

module Outlier_Dispatcher (
    input logic [`BFP_SPROD_BW-1:0] sprod_b,
    input logic [`OI_W-1:0] oi1,
    input logic [`OI_W-1:0] oi2,
    output logic [`BFP_SPROD_BW-1:0] routed_sprod_b,
    output logic outlier1_valid,
    output logic outlier2_valid
);

    localparam logic [`OI_W-1:0] OP1_LANE = `BFP_GSIZE - 1;
    localparam logic [`OI_W-1:0] OP2_LANE = `BFP_GSIZE - 2;

    logic no_outlier;
    logic [`BFP_SPROD_W-1:0] lane_input [0:`BFP_GSIZE-1];
    logic [`BFP_SPROD_W-1:0] lane_output [0:`BFP_GSIZE-1];

    always_comb begin : LANE_ROUTING
        no_outlier = &(oi1 & oi2);
        outlier1_valid = !no_outlier;
        outlier2_valid = !no_outlier && |oi2;
        routed_sprod_b = '0;

        for(int i = 0; i < `BFP_GSIZE; i++)
            lane_input[i] = sprod_b[i*`BFP_SPROD_W +: `BFP_SPROD_W];

        for(int i = 0; i < `BFP_GSIZE; i++) begin
            case({outlier1_valid, outlier2_valid})
                2'b10: begin
                    if(i == OP1_LANE) lane_output[i] = lane_input[oi1];
                    else if(oi1 == i) lane_output[i] = lane_input[OP1_LANE];
                    else lane_output[i] = lane_input[i];
                end
                2'b11: begin
                    if(i == OP1_LANE) lane_output[i] = lane_input[oi1];
                    else if(i == OP2_LANE) lane_output[i] = lane_input[oi2];
                    else if(oi1 == i) begin
                        if(oi2 == OP1_LANE) lane_output[i] = lane_input[OP2_LANE];
                        else lane_output[i] = lane_input[OP1_LANE];
                    end
                    else if(oi2 == i) begin
                        if(oi1 == OP2_LANE) lane_output[i] = lane_input[OP1_LANE];
                        else lane_output[i] = lane_input[OP2_LANE];
                    end
                    else lane_output[i] = lane_input[i];
                end
                default: lane_output[i] = lane_input[i];
            endcase
        end

        for(int i = 0; i < `BFP_GSIZE; i++)
            routed_sprod_b[i*`BFP_SPROD_W +: `BFP_SPROD_W] = lane_output[i];
    end

endmodule
