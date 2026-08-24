/******************************************************************************
* Copyright (C) 2026 Marco
*
* File Name:    PATTERN.sv
* Project:      Research for Block Floating Point Processing Element
* Module:       PATTERN
* Author:       Marco <harry2963753@gmail.com>
*
******************************************************************************/
`include "include.vh"

module PATTERN (
    output logic clk,
    output logic rst_n,
    output logic acc_clear,
    output logic weight_load,
    output logic in_valid,
    output logic [`BFP_SIGN_BW-1:0] w_sign_b,
    output logic [`BFP_SIGN_BW-1:0] a_sign_b,
    output logic [`BFP_EXP_W-1:0] w_exp,
    output logic [`BFP_EXP_W-1:0] a_exp,
    output logic [`BFP_MAN_BW-1:0] w_man_b,
    output logic [`BFP_MAN_BW-1:0] a_man_b,
    input logic o_sign,
    input logic [`FPACC_EXP_W-1:0] o_exp,
    input logic [`FPACC_MAN_W-1:0] o_man
);

    localparam integer CLK_PERIOD = 10;
    localparam integer TIMEOUT = 10_000_000;

    //=============================================================
    //                       Clock Generation
    //=============================================================
    initial clk = 1'b0;
    always #(CLK_PERIOD / 2.0) clk = ~clk;

    //=============================================================
    //                     File and Loop State
    //=============================================================
    integer fin;
    integer fout;
    integer scan_count;
    integer cycle_count;
    logic acc_clear_i;
    logic weight_load_i;
    logic in_valid_i;
    logic [`BFP_SIGN_BW-1:0] w_sign_i;
    logic [`BFP_SIGN_BW-1:0] a_sign_i;
    logic [`BFP_EXP_W-1:0] w_exp_i;
    logic [`BFP_EXP_W-1:0] a_exp_i;
    logic [`BFP_MAN_BW-1:0] w_man_i;
    logic [`BFP_MAN_BW-1:0] a_man_i;

    //=============================================================
    //                         Reset Task
    //=============================================================
    task automatic drive_reset();
        acc_clear = 1'b0;
        weight_load = 1'b0;
        in_valid = 1'b0;
        w_sign_b = '0;
        a_sign_b = '0;
        w_exp = '0;
        a_exp = '0;
        w_man_b = '0;
        a_man_b = '0;

        rst_n = 1'b1;
        force clk = 1'b0;
        #20 rst_n = 1'b0;
        #20 rst_n = 1'b1;
        release clk;
        @(negedge clk);
    endtask

    //=============================================================
    //                      Cycle Driver Task
    //=============================================================
    task automatic drive_cycle(
        input logic clear,
        input logic load,
        input logic valid,
        input logic [`BFP_SIGN_BW-1:0] weight_sign,
        input logic [`BFP_EXP_W-1:0] weight_exp,
        input logic [`BFP_MAN_BW-1:0] weight_man,
        input logic [`BFP_SIGN_BW-1:0] activation_sign,
        input logic [`BFP_EXP_W-1:0] activation_exp,
        input logic [`BFP_MAN_BW-1:0] activation_man
    );
        acc_clear = clear;
        weight_load = load;
        in_valid = valid;
        w_sign_b = weight_sign;
        w_exp = weight_exp;
        w_man_b = weight_man;
        a_sign_b = activation_sign;
        a_exp = activation_exp;
        a_man_b = activation_man;

        @(posedge clk);
        #1;
        if((^{o_sign, o_exp, o_man}) === 1'bx)
            $fatal(1, "[ERROR]: unknown DUT output at cycle %0d", cycle_count);
        $fwrite(fout, "%08h\n", {o_sign, o_exp, o_man});
        cycle_count++;
        @(negedge clk);
    endtask

    //=============================================================
    //                           Main
    //=============================================================
    initial begin
        fin = 0;
        fout = 0;
        cycle_count = 0;
        drive_reset();

        fin = $fopen("../00_TESTBED/input.dat", "r");
        if(fin == 0)
            $fatal(1, "[ERROR]: cannot open input.dat");

        fout = $fopen("../00_TESTBED/output.dat", "w");
        if(fout == 0)
            $fatal(1, "[ERROR]: cannot open output.dat");

        scan_count = $fscanf(
            fin,
            "%h %h %h %h %h %h %h %h %h",
            acc_clear_i,
            weight_load_i,
            in_valid_i,
            w_sign_i,
            w_exp_i,
            w_man_i,
            a_sign_i,
            a_exp_i,
            a_man_i
        );
        while(scan_count == 9) begin
            drive_cycle(
                acc_clear_i,
                weight_load_i,
                in_valid_i,
                w_sign_i,
                w_exp_i,
                w_man_i,
                a_sign_i,
                a_exp_i,
                a_man_i
            );
            scan_count = $fscanf(
                fin,
                "%h %h %h %h %h %h %h %h %h",
                acc_clear_i,
                weight_load_i,
                in_valid_i,
                w_sign_i,
                w_exp_i,
                w_man_i,
                a_sign_i,
                a_exp_i,
                a_man_i
            );
        end

        if(!$feof(fin))
            $fatal(1, "[ERROR]: malformed input.dat at cycle %0d", cycle_count);

        $fclose(fin);
        $fclose(fout);
        $display("=========================================================");
        $display("  BFP-PE TRACE COMPLETE: %0d cycles written", cycle_count);
        $display("  Output: ../00_TESTBED/output.dat");
        $display("=========================================================");
        $finish;
    end

    //=============================================================
    //                         Watchdog
    //=============================================================
    initial begin
        #(TIMEOUT);
        $fatal(1, "[ERROR]: simulation timeout");
    end

endmodule
