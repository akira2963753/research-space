/******************************************************************************
* Copyright (C) 2026 Marco
*
* File Name:    TESTBED.sv
* Project:      Research for Block Floating Point Processing Element
* Module:       TESTBED
* Author:       Marco <harry2963753@gmail.com>
*
******************************************************************************/
`include "include.vh"

module TESTBED;

    //=============================================================
    //                           Signals
    //=============================================================
    logic clk;
    logic rst_n;
    logic acc_clear;
    logic weight_load;
    logic in_valid;
    logic [`BFP_SIGN_BW-1:0] w_sign_b;
    logic [`BFP_SIGN_BW-1:0] a_sign_b;
    logic [`BFP_EXP_W-1:0] w_exp;
    logic [`BFP_EXP_W-1:0] a_exp;
    logic [`BFP_MAN_BW-1:0] w_man_b;
    logic [`BFP_MAN_BW-1:0] a_man_b;
    logic o_sign;
    logic [`FPACC_EXP_W-1:0] o_exp;
    logic [`FPACC_MAN_W-1:0] o_man;

    //=============================================================
    //                             DUT
    //=============================================================
    BFP_PE u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .acc_clear(acc_clear),
        .weight_load(weight_load),
        .in_valid(in_valid),
        .w_sign_b(w_sign_b),
        .a_sign_b(a_sign_b),
        .w_exp(w_exp),
        .a_exp(a_exp),
        .w_man_b(w_man_b),
        .a_man_b(a_man_b),
        .o_sign(o_sign),
        .o_exp(o_exp),
        .o_man(o_man)
    );

    //=============================================================
    //                           PATTERN
    //=============================================================
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
        .w_man_b(w_man_b),
        .a_man_b(a_man_b),
        .o_sign(o_sign),
        .o_exp(o_exp),
        .o_man(o_man)
    );

    //=============================================================
    //                   Sim Mode & SDF Annotate
    //=============================================================
    `ifdef GATE
        initial begin
            $display("======================================");
            $display("  [INFO] GATE-LEVEL SIMULATION START  ");
            $display("======================================");
            $sdf_annotate("../02_SYN/Netlist/BFP_PE_syn.sdf", u_dut, , , "maximum");
            $dumpfile("BFP_PE.vcd");
            $dumpvars(0, TESTBED.u_dut);
        end
    `else
        initial begin
            $display("======================================");
            $display("  [INFO] BEHAVIORAL SIMULATION START  ");
            $display("======================================");
        end
    `endif

    //=============================================================
    //                         FSDB Dump
    //=============================================================
    `ifndef IVERILOG
        initial begin
            $fsdbDumpfile("TESTBED.fsdb");
            $fsdbDumpvars(0, TESTBED, "+mda");
        end
    `endif

endmodule
