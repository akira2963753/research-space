////////////////////////////////////////////////////////////////////////////////
// File: TESTBED.sv
// Project: Bucket Getter BFP Processing Element
// Author: Marco <harry2963753@gmail.com>
// Description: DUT wrapper, simulation mode, SDF, and FSDB ownership
////////////////////////////////////////////////////////////////////////////////
`include "BG_INCLUDE.svh"

module TESTBED;

    logic clk;
    logic rst_n;
    logic i_start;
    logic i_weight_load;
    logic [`BG_SIGN_BW-1:0] i_w_sign;
    logic [`BG_EXP_W-1:0] i_w_exp;
    logic [`BG_MAN_BW-1:0] i_w_man;
    logic i_valid;
    logic o_ready;
    logic i_last;
    logic [`BG_SIGN_BW-1:0] i_a_sign;
    logic [`BG_EXP_W-1:0] i_a_exp;
    logic [`BG_MAN_BW-1:0] i_a_man;
    logic o_result_valid;
    logic i_result_ready;
    logic o_sign;
    logic [`BG_FP_EXP_W-1:0] o_exp;
    logic [`BG_FP_MAN_W-1:0] o_man;
    logic o_busy;

    BUCKET_GETTER_PE u_dut(
        .clk(clk),
        .rst_n(rst_n),
        .i_start(i_start),
        .i_weight_load(i_weight_load),
        .i_w_sign(i_w_sign),
        .i_w_exp(i_w_exp),
        .i_w_man(i_w_man),
        .i_valid(i_valid),
        .o_ready(o_ready),
        .i_last(i_last),
        .i_a_sign(i_a_sign),
        .i_a_exp(i_a_exp),
        .i_a_man(i_a_man),
        .o_result_valid(o_result_valid),
        .i_result_ready(i_result_ready),
        .o_sign(o_sign),
        .o_exp(o_exp),
        .o_man(o_man),
        .o_busy(o_busy)
    );

    PATTERN u_pattern(
        .clk(clk),
        .rst_n(rst_n),
        .i_start(i_start),
        .i_weight_load(i_weight_load),
        .i_w_sign(i_w_sign),
        .i_w_exp(i_w_exp),
        .i_w_man(i_w_man),
        .i_valid(i_valid),
        .o_ready(o_ready),
        .i_last(i_last),
        .i_a_sign(i_a_sign),
        .i_a_exp(i_a_exp),
        .i_a_man(i_a_man),
        .o_result_valid(o_result_valid),
        .i_result_ready(i_result_ready),
        .o_sign(o_sign),
        .o_exp(o_exp),
        .o_man(o_man),
        .o_busy(o_busy)
    );

    `ifdef GATE
        initial begin
            $display("======================================");
            $display("  [INFO] GATE-LEVEL SIMULATION START  ");
            $display("======================================");
            $sdf_annotate("../02_SYN/Netlist/BUCKET_GETTER_PE_syn.sdf", u_dut, , , "maximum");
        end
    `else
        initial begin
            $display("======================================");
            $display("  [INFO] BEHAVIORAL SIMULATION START  ");
            $display("======================================");
        end
    `endif

    `ifndef IVERILOG
        initial begin
            $fsdbDumpfile("TESTBED.fsdb");
            $fsdbDumpvars(0, TESTBED, "+mda");
        end
    `endif

endmodule
