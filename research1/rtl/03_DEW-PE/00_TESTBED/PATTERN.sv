/******************************************************************************
* Copyright (C) 2026 Marco
*
* File Name:    PATTERN.sv
* Project:      Dynamic Exponent Window Accumulation Based PE
* Module:       PATTERN
* Author:       Marco <harry2963753@gmail.com>
*
******************************************************************************/
`include "include.vh"

module PATTERN(
    output logic clk,
    output logic rst_n,
    output logic acc_clear,
    output logic weight_load,
    output logic in_valid,
    output logic [`BFP_SIGN_BW-1:0] w_sign_b,
    output logic [`BFP_SIGN_BW-1:0] a_sign_b,
    output logic [`BFP_EXP_W-1:0] w_exp,
    output logic [`BFP_EXP_W-1:0] a_exp,
    output logic [`BFP_EXP_W-1:0] oa_exp,
    output logic [`BFP_MAN_BW-1:0] w_man_b,
    output logic [`BFP_MAN_BW-1:0] a_man_b,
    output logic [`OI_W-1:0] oi1,
    output logic [`OI_W-1:0] oi2,
    input logic in_ready,
    output logic in_last,
    input logic out_valid,
    output logic out_ready,
    input logic o_sign,
    input logic [`FPACC_EXP_W-1:0] o_exp,
    input logic [`FPACC_MAN_W-1:0] o_man,
    input logic busy
);

    localparam integer CLK_PERIOD = 10;
    localparam integer TIMEOUT = 20_000_000;
    localparam integer BLOCKS_PER_DOT = 688;
    localparam integer DOT_PRODUCT_COUNT = 256;
    localparam integer EXPECTED_INPUT_ROWS = 176_384;
    localparam integer EXPECTED_VALID_BLOCKS = 176_128;

    integer fin, fout;
    integer scan_count;
    integer input_line_count, accepted_block_count, result_count;
    logic power_window;
    logic acc_clear_i, weight_load_i, in_valid_i;
    logic [`BFP_SIGN_BW-1:0] w_sign_i, a_sign_i;
    logic [`BFP_EXP_W-1:0] w_exp_i, a_exp_i, oa_exp_i;
    logic [`BFP_MAN_BW-1:0] w_man_i, a_man_i;
    logic [`OI_W-1:0] oi1_i, oi2_i;

    initial clk = 1'b0;
    always #(CLK_PERIOD / 2.0) clk = ~clk;

    task automatic drive_idle();
        acc_clear = 1'b0;
        weight_load = 1'b0;
        in_valid = 1'b0;
        w_sign_b = '0;
        a_sign_b = '0;
        w_exp = '0;
        a_exp = '0;
        oa_exp = '0;
        w_man_b = '0;
        a_man_b = '0;
        oi1 = {`OI_W{1'b1}};
        oi2 = {`OI_W{1'b1}};
        in_last = 1'b0;
        out_ready = 1'b1;
    endtask

    task automatic drive_reset();
        drive_idle();
        power_window = 1'b0;
        rst_n = 1'b1;
        force clk = 1'b0;
        #20 rst_n = 1'b0;
        #20 rst_n = 1'b1;
        release clk;
        @(negedge clk);
    endtask

    task automatic read_trace_line();
        scan_count = $fscanf(
            fin,
            "%h %h %h %h %h %h %h %h %h %h %h %h",
            acc_clear_i,
            weight_load_i,
            in_valid_i,
            w_sign_i,
            w_exp_i,
            w_man_i,
            a_sign_i,
            a_exp_i,
            oa_exp_i,
            a_man_i,
            oi1_i,
            oi2_i
        );
        if(scan_count != 12)
            $fatal(1, "[ERROR]: malformed or early EOF at input line %0d", input_line_count);
        input_line_count++;
    endtask

    task automatic start_dot_product(input integer dot_index);
        read_trace_line();
        if(!(acc_clear_i && weight_load_i && !in_valid_i))
            $fatal(1, "[ERROR]: invalid setup row for dot product %0d", dot_index);
        if(oi1_i != {`OI_W{1'b1}} || oi2_i != {`OI_W{1'b1}})
            $fatal(1, "[ERROR]: setup row must use the no-outlier OI code");

        acc_clear = 1'b1;
        weight_load = 1'b1;
        w_sign_b = w_sign_i;
        w_exp = w_exp_i;
        w_man_b = w_man_i;
        @(posedge clk);
        #1;
        if((^{in_ready, busy}) === 1'bx)
            $fatal(1, "[ERROR]: unknown DUT status while starting dot product %0d", dot_index);
        @(negedge clk);
        drive_idle();
    endtask

    task automatic send_block(
        input integer dot_index,
        input integer block_index
    );
        read_trace_line();
        if(acc_clear_i || !in_valid_i)
            $fatal(1, "[ERROR]: invalid data row at dot %0d block %0d", dot_index, block_index);
        if(weight_load_i != (block_index != BLOCKS_PER_DOT-1))
            $fatal(1, "[ERROR]: weight_load mismatch at dot %0d block %0d", dot_index, block_index);
        while(in_ready !== 1'b1) @(negedge clk);
        weight_load = weight_load_i;
        w_sign_b = w_sign_i;
        w_exp = w_exp_i;
        w_man_b = w_man_i;
        in_valid = 1'b1;
        in_last = block_index == BLOCKS_PER_DOT-1;
        a_sign_b = a_sign_i;
        a_exp = a_exp_i;
        oa_exp = oa_exp_i;
        a_man_b = a_man_i;
        oi1 = oi1_i;
        oi2 = oi2_i;
        @(posedge clk);
        accepted_block_count++;
        #1;
        if((^{in_ready, busy}) === 1'bx)
            $fatal(1, "[ERROR]: unknown DUT status at dot %0d block %0d", dot_index, block_index);
        @(negedge clk);
        drive_idle();
    endtask

    task automatic capture_result(input integer dot_index);
        while(out_valid !== 1'b1) @(negedge clk);
        if((^{o_sign, o_exp, o_man}) === 1'bx)
            $fatal(1, "[ERROR]: unknown result for dot product %0d", dot_index);
        $fwrite(fout, "%08h\n", {o_sign, o_exp, o_man});
        result_count++;
        @(posedge clk);
        @(negedge clk);
    endtask

    initial begin : MAIN_FLOW
        fin = 0;
        fout = 0;
        input_line_count = 0;
        accepted_block_count = 0;
        result_count = 0;
        drive_reset();

        fin = $fopen("../00_TESTBED/input.dat", "r");
        if(fin == 0) $fatal(1, "[ERROR]: cannot open input.dat");
        fout = $fopen("../00_TESTBED/output.dat", "w");
        if(fout == 0) $fatal(1, "[ERROR]: cannot open output.dat");

        power_window = 1'b1;
        $display("[POWER_WINDOW]: start=%0t", $time);
        for(int dot_index = 0; dot_index < DOT_PRODUCT_COUNT; dot_index++) begin
            start_dot_product(dot_index);
            for(int block_index = 0; block_index < BLOCKS_PER_DOT; block_index++)
                send_block(dot_index, block_index);
            capture_result(dot_index);
        end
        power_window = 1'b0;
        $display("[POWER_WINDOW]: end=%0t", $time);

        scan_count = $fscanf(
            fin,
            "%h %h %h %h %h %h %h %h %h %h %h %h",
            acc_clear_i,
            weight_load_i,
            in_valid_i,
            w_sign_i,
            w_exp_i,
            w_man_i,
            a_sign_i,
            a_exp_i,
            oa_exp_i,
            a_man_i,
            oi1_i,
            oi2_i
        );
        if(scan_count != -1)
            $fatal(1, "[ERROR]: input.dat has trailing data after %0d lines", input_line_count);
        if(input_line_count != EXPECTED_INPUT_ROWS)
            $fatal(1, "[ERROR]: read %0d input rows, expected %0d", input_line_count, EXPECTED_INPUT_ROWS);
        if(accepted_block_count != EXPECTED_VALID_BLOCKS)
            $fatal(1, "[ERROR]: accepted %0d blocks, expected %0d", accepted_block_count, EXPECTED_VALID_BLOCKS);
        if(result_count != DOT_PRODUCT_COUNT)
            $fatal(1, "[ERROR]: captured %0d results, expected %0d", result_count, DOT_PRODUCT_COUNT);

        $fclose(fin);
        $fclose(fout);
        $display("=========================================================");
        $display("  DEW PE TRACE COMPLETE");
        $display("  Input rows:      %0d", input_line_count);
        $display("  Accepted blocks: %0d", accepted_block_count);
        $display("  FP results:      %0d", result_count);
        $display("  Output: ../00_TESTBED/output.dat");
        $display("=========================================================");
        $finish;
    end

    initial begin : WATCHDOG
        #(TIMEOUT);
        $fatal(1, "[ERROR]: simulation timeout");
    end

    //=============================================================
    //                 SystemVerilog Assertion
    //=============================================================

    `ifdef SVA
        S_INPUT_STABLE: assert property(
            @(posedge clk) disable iff(!rst_n)
            in_valid && !in_ready |=> $stable({in_valid, in_last, weight_load, w_sign_b, w_exp,
            w_man_b, a_sign_b, a_exp, oa_exp, a_man_b, oi1, oi2})
        )
        else $fatal(1, "[ERROR]: input transaction changed while stalled");

        S_OUTPUT_KNOWN: assert property(
            @(posedge clk) disable iff(!rst_n)
            out_valid |-> !$isunknown({o_sign, o_exp, o_man})
        )
        else $fatal(1, "[ERROR]: FP output contains X or Z");
    `endif

endmodule
