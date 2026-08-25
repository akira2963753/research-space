/******************************************************************************
* Copyright (C) 2026 Marco
*
* File Name:    PATTERN.sv
* Project:      Bucket Getter BFP Processing Element
* Module:       Full LLaMA2-7B G16/BFP4 trace driver and result writer
* Author:       Marco <harry2963753@gmail.com>
*
******************************************************************************/
`include "include.vh"

module PATTERN(
    output logic clk,
    output logic rst_n,
    output logic i_start,
    output logic i_weight_load,
    output logic [`BFP_SIGN_BW-1:0] i_w_sign,
    output logic [`BFP_EXP_W-1:0] i_w_exp,
    output logic [`BFP_MAN_BW-1:0] i_w_man,
    output logic i_valid,
    input logic o_ready,
    output logic i_last,
    output logic [`BFP_SIGN_BW-1:0] i_a_sign,
    output logic [`BFP_EXP_W-1:0] i_a_exp,
    output logic [`BFP_MAN_BW-1:0] i_a_man,
    input logic o_result_valid,
    output logic i_result_ready,
    input logic o_sign,
    input logic [`FPACC_EXP_W-1:0] o_exp,
    input logic [`FPACC_MAN_W-1:0] o_man,
    input logic o_busy
);

    localparam integer CLK_PERIOD = 10;
    localparam integer TIMEOUT = 20_000_000;
    localparam integer BLOCKS_PER_DOT = 688;
    localparam integer DOT_PRODUCT_COUNT = 256;

    integer fin;
    integer fout;
    integer scan_count;
    integer input_line_count;
    integer result_count;
    logic acc_clear_i;
    logic weight_load_i;
    logic in_valid_i;
    logic [`BFP_SIGN_BW-1:0] w_sign_i;
    logic [`BFP_EXP_W-1:0] w_exp_i;
    logic [`BFP_MAN_BW-1:0] w_man_i;
    logic [`BFP_SIGN_BW-1:0] a_sign_i;
    logic [`BFP_EXP_W-1:0] a_exp_i;
    logic [`BFP_MAN_BW-1:0] a_man_i;

    initial clk = 1'b0;
    always #(CLK_PERIOD / 2.0) clk = ~clk;

    task automatic drive_idle();
        i_start = 1'b0;
        i_weight_load = 1'b0;
        i_w_sign = '0;
        i_w_exp = '0;
        i_w_man = '0;
        i_valid = 1'b0;
        i_last = 1'b0;
        i_a_sign = '0;
        i_a_exp = '0;
        i_a_man = '0;
        i_result_ready = 1'b1;
    endtask

    task automatic drive_reset();
        drive_idle();
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
        if(scan_count != 9)
            $fatal(1, "[ERROR]: malformed or early EOF at input line %0d", input_line_count);
        input_line_count++;
    endtask

    task automatic start_dot_product(input integer dot_index);
        read_trace_line();
        if(!(acc_clear_i && weight_load_i && !in_valid_i))
            $fatal(1, "[ERROR]: invalid setup row for dot product %0d", dot_index);

        i_start = 1'b1;
        i_weight_load = 1'b1;
        i_w_sign = w_sign_i;
        i_w_exp = w_exp_i;
        i_w_man = w_man_i;
        @(posedge clk);
        #1;
        if((^{o_ready, o_busy}) === 1'bx)
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

        while(o_ready !== 1'b1) @(negedge clk);
        i_weight_load = weight_load_i;
        i_w_sign = w_sign_i;
        i_w_exp = w_exp_i;
        i_w_man = w_man_i;
        i_valid = 1'b1;
        i_last = block_index == BLOCKS_PER_DOT-1;
        i_a_sign = a_sign_i;
        i_a_exp = a_exp_i;
        i_a_man = a_man_i;
        @(posedge clk);
        #1;
        if((^{o_ready, o_busy}) === 1'bx)
            $fatal(1, "[ERROR]: unknown DUT status at dot %0d block %0d", dot_index, block_index);
        @(negedge clk);
        drive_idle();
    endtask

    task automatic capture_result(input integer dot_index);
        while(o_result_valid !== 1'b1) @(negedge clk);
        if((^{o_sign, o_exp, o_man}) === 1'bx)
            $fatal(1, "[ERROR]: unknown result for dot product %0d", dot_index);
        $fwrite(fout, "%08h\n", {o_sign, o_exp, o_man});
        result_count++;
        @(posedge clk);
        @(negedge clk);
    endtask

    initial begin
        fin = 0;
        fout = 0;
        input_line_count = 0;
        result_count = 0;
        drive_reset();

        fin = $fopen("../00_TESTBED/input.dat", "r");
        if(fin == 0)
            $fatal(1, "[ERROR]: cannot open input.dat");
        fout = $fopen("../00_TESTBED/output.dat", "w");
        if(fout == 0)
            $fatal(1, "[ERROR]: cannot open output.dat");

        for(int dot_index = 0; dot_index < DOT_PRODUCT_COUNT; dot_index++) begin
            start_dot_product(dot_index);
            for(int block_index = 0; block_index < BLOCKS_PER_DOT; block_index++)
                send_block(dot_index, block_index);
            capture_result(dot_index);
        end

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
        if(!$feof(fin))
            $fatal(1, "[ERROR]: input.dat has trailing data after %0d lines", input_line_count);

        $fclose(fin);
        $fclose(fout);
        $display("=========================================================");
        $display("  BUCKET GETTER TRACE COMPLETE");
        $display("  Input rows: %0d", input_line_count);
        $display("  Results:   %0d", result_count);
        $display("  Output: ../00_TESTBED/output.dat");
        $display("=========================================================");
        $finish;
    end

    initial begin
        #(TIMEOUT);
        $fatal(1, "[ERROR]: simulation timeout");
    end

    `ifdef SVA
        property p_hold_input_while_stalled;
            @(posedge clk) disable iff(!rst_n)
                i_valid && !o_ready |=> $stable({
                    i_valid,
                    i_last,
                    i_weight_load,
                    i_w_sign,
                    i_w_exp,
                    i_w_man,
                    i_a_sign,
                    i_a_exp,
                    i_a_man
                });
        endproperty

        property p_known_result;
            @(posedge clk) disable iff(!rst_n)
                o_result_valid |-> !$isunknown({o_sign, o_exp, o_man});
        endproperty

        ap_hold_input_while_stalled: assert property(p_hold_input_while_stalled);
        ap_known_result: assert property(p_known_result);
    `endif

endmodule
