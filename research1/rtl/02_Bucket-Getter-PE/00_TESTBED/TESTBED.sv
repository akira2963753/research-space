/******************************************************************************
* Copyright (C) 2026 Marco
*
* File Name:    TESTBED.sv
* Project:      Bucket Getter BFP Processing Element
* Module:       DUT wrapper, simulation mode, SDF, and FSDB ownership
* Author:       Marco <harry2963753@gmail.com>
*
******************************************************************************/
`include "include.vh"

module TESTBED;

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
    logic in_ready;
    logic in_last;
    logic out_valid;
    logic out_ready;
    logic o_sign;
    logic [`FPACC_EXP_W-1:0] o_exp;
    logic [`FPACC_MAN_W-1:0] o_man;
    logic busy;

    BG_PE u_dut(
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
        .in_ready(in_ready),
        .in_last(in_last),
        .out_valid(out_valid),
        .out_ready(out_ready),
        .o_sign(o_sign),
        .o_exp(o_exp),
        .o_man(o_man),
        .busy(busy)
    );

    PATTERN u_pattern(
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
        .in_ready(in_ready),
        .in_last(in_last),
        .out_valid(out_valid),
        .out_ready(out_ready),
        .o_sign(o_sign),
        .o_exp(o_exp),
        .o_man(o_man),
        .busy(busy)
    );

    `ifdef GATE
        initial begin
            $display("======================================");
            $display("  [INFO] GATE-LEVEL SIMULATION START  ");
            $display("======================================");
            $sdf_annotate("../02_SYN/Netlist/BG_PE_syn.sdf", u_dut, , , "maximum");
        end
    `else
        initial begin
            $display("======================================");
            $display("  [INFO] BEHAVIORAL SIMULATION START  ");
            $display("======================================");
        end
    `endif

    initial begin
        $fsdbDumpfile("BG_PE.fsdb");
        $fsdbDumpvars(0, u_dut, "+mda");
    end

endmodule
