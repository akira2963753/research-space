/******************************************************************************
* Copyright (C) 2026 Marco
*
* File Name:    PATTERN.sv
* Project:      Research for Block Floating Point Processing Element
* Module:       PATTERN
* Author:       Marco <harry2963753@gmail.com>
* Student ID:   M11407439
* Tool:         VCS & Verdi
*
******************************************************************************/
`include "include.svh"

`define CLK_PERIOD 10
`define TIMEOUT 1000000

module PATTERN(
    // clock / reset (driven by PATTERN)
    output logic clk,
    output logic rst_n,
    // DUT inputs (driven by PATTERN)
    output logic preload,
    output logic [`BFP_SIGN_BW-1:0] w_sign_b,
    output logic [`BFP_SIGN_BW-1:0] a_sign_b,
    output logic [`BFP_EXP_W-1:0] w_exp,
    output logic [`BFP_EXP_W-1:0] a_exp,
    output logic [`BFP_MAN_BW-1:0] w_man_b,
    output logic [`BFP_MAN_BW-1:0] a_man_b,
    // DUT outputs (observed by PATTERN)
    input o_sign,
    input [`FP16_EXP_W-1:0] o_exp,
    input [`FP16_MAN_W-1:0] o_man
);

    //=============================================================
    // ----------------------- Clock Gen --------------------------
    //=============================================================
    initial clk = 0;
    always #(`CLK_PERIOD/2.0) clk = ~clk;

    //=============================================================
    // ------------------- File / Loop State ----------------------
    //=============================================================
    integer fin, fgold, r, rg, idx;
    logic pre_i;
    logic [`BFP_SIGN_BW-1:0] ws_i, as_i;
    logic [`BFP_EXP_W-1:0] we_i, ae_i;
    logic [`BFP_MAN_BW-1:0] wm_i, am_i;
    logic [`FP16_W-1:0] gold_i;

    //=============================================================
    // ------------------------ Reset Task ------------------------
    //=============================================================
    task automatic reset_dut();
        rst_n = 1;
        preload = 0;
        w_sign_b = 0;
        a_sign_b = 0;
        w_exp = 0;
        a_exp = 0;
        w_man_b = 0;
        a_man_b = 0;
        @(negedge clk) rst_n = 0;
        @(negedge clk) rst_n = 1;
    endtask

    //=============================================================
    // ------------------- Drive & Check Task ---------------------
    //=============================================================
    // Stimulus is launched on negedge (gate-safe). The FP accumulator is
    // registered, so the expected output is sampled just after the following
    // posedge, where o == acc_reg for this cycle.
    task automatic drive_and_check(
        input pre,
        input [`BFP_SIGN_BW-1:0] ws,
        input [`BFP_EXP_W-1:0] we,
        input [`BFP_MAN_BW-1:0] wm,
        input [`BFP_SIGN_BW-1:0] as,
        input [`BFP_EXP_W-1:0] ae,
        input [`BFP_MAN_BW-1:0] am,
        input [`FP16_W-1:0] gold
    );
        @(negedge clk);
        preload = pre;
        w_sign_b = ws;
        w_exp = we;
        w_man_b = wm;
        a_sign_b = as;
        a_exp = ae;
        a_man_b = am;
        @(posedge clk);
        #1;
        if ({o_sign, o_exp, o_man} !== gold) begin
            $display("[ERROR] cycle %0d : DUT=%h  golden=%h  (preload=%b)",
                     idx, {o_sign, o_exp, o_man}, gold, pre);
            $fatal(1, "[ERROR] : output mismatch at cycle %0d", idx);
        end
        idx = idx + 1;
    endtask

    //=============================================================
    // -------------------------- Main ----------------------------
    //=============================================================
    initial begin
        reset_dut();
        fin   = $fopen("../00_TESTBED/input.dat", "r");
        fgold = $fopen("../00_TESTBED/golden.dat", "r");
        if (fin == 0 || fgold == 0) $fatal(1, "[ERROR] : cannot open input.dat / golden.dat");
        idx = 0;
        forever begin
            r = $fscanf(fin, "%h %h %h %h %h %h %h",
                        pre_i, ws_i, we_i, wm_i, as_i, ae_i, am_i);
            if (r != 7) break;
            rg = $fscanf(fgold, "%h", gold_i);
            if (rg != 1) $fatal(1, "[ERROR] : golden.dat shorter than input.dat");
            drive_and_check(pre_i, ws_i, we_i, wm_i, as_i, ae_i, am_i, gold_i);
        end
        $fclose(fin);
        $fclose(fgold);
        $display("=========================================================");
        $display("  BFP-PE PATTERN PASS : %0d cycles verified, 0 error", idx);
        $display("=========================================================");
        $finish;
    end

    //=============================================================
    // ------------------------ Watchdog --------------------------
    //=============================================================
    initial begin
        #(`TIMEOUT);
        $fatal(1, "[ERROR] : simulation timeout");
    end

endmodule
