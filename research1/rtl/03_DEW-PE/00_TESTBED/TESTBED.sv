/******************************************************************************
* Copyright (C) 2026 Marco
*
* File Name:    TESTBED.sv
* Project:      Dynamic Exponent Window Accumulation Based PE
* Module:       TESTBED
* Author:       Marco <harry2963753@gmail.com>
*
******************************************************************************/
`include "include.vh"

module TESTBED;

    logic clk, rst_n;
    logic acc_clear, weight_load, in_valid;
    logic [`BFP_SIGN_BW-1:0] w_sign_b, a_sign_b;
    logic [`BFP_EXP_W-1:0] w_exp, a_exp, oa_exp;
    logic [`BFP_MAN_BW-1:0] w_man_b, a_man_b;
    logic [`OI_W-1:0] oi1, oi2;
    logic in_ready, in_last;
    logic out_valid, out_ready;
    logic o_sign;
    logic [`FPACC_EXP_W-1:0] o_exp;
    logic [`FPACC_MAN_W-1:0] o_man;
    logic busy;

    DEW_PE #(
        .DEW_ACC_W(24),
        .T_SKIP(9),
        .T_REPLACE(3)
    ) u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .acc_clear(acc_clear),
        .weight_load(weight_load),
        .in_valid(in_valid),
        .w_sign_b(w_sign_b),
        .a_sign_b(a_sign_b),
        .w_exp(w_exp),
        .a_exp(a_exp),
        .oa_exp(oa_exp),
        .w_man_b(w_man_b),
        .a_man_b(a_man_b),
        .oi1(oi1),
        .oi2(oi2),
        .in_ready(in_ready),
        .in_last(in_last),
        .out_valid(out_valid),
        .out_ready(out_ready),
        .o_sign(o_sign),
        .o_exp(o_exp),
        .o_man(o_man),
        .busy(busy)
    );

    PATTERN u_pattern (
        .clk(clk),
        .rst_n(rst_n),
        .acc_clear(acc_clear),
        .weight_load(weight_load),
        .in_valid(in_valid),
        .w_sign_b(w_sign_b),
        .a_sign_b(a_sign_b),
        .w_exp(w_exp),
        .a_exp(a_exp),
        .oa_exp(oa_exp),
        .w_man_b(w_man_b),
        .a_man_b(a_man_b),
        .oi1(oi1),
        .oi2(oi2),
        .in_ready(in_ready),
        .in_last(in_last),
        .out_valid(out_valid),
        .out_ready(out_ready),
        .o_sign(o_sign),
        .o_exp(o_exp),
        .o_man(o_man),
        .busy(busy)
    );

    //=============================================================
    //                   Sim Mode & SDF Annotate
    //=============================================================
    `ifdef GATE
        initial begin
            $display("======================================");
            $display("  [INFO] GATE-LEVEL SIMULATION START  ");
            $display("======================================");
            $sdf_annotate("../02_SYN/Netlist/DEW_PE_syn.sdf", u_dut, , , "maximum");
        end
    `else
        initial begin
            $display("======================================");
            $display("  [INFO] BEHAVIORAL SIMULATION START  ");
            $display("======================================");
        end
    `endif

    initial begin
        $fsdbDumpfile("DEW_PE.fsdb");
        $fsdbDumpvars(0, TESTBED, "+mda");
    end

endmodule
