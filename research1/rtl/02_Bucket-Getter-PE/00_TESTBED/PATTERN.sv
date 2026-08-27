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
    output logic acc_clear,
    output logic weight_load,
    output logic in_valid,
    output logic [`BFP_SIGN_BW-1:0] w_sign_b,
    output logic [`BFP_SIGN_BW-1:0] a_sign_b,
    output logic [`BFP_EXP_W-1:0] w_exp,
    output logic [`BFP_EXP_W-1:0] a_exp,
    output logic [`BFP_MAN_BW-1:0] w_man_b,
    output logic [`BFP_MAN_BW-1:0] a_man_b,
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

    integer fin;
    integer fout;
    integer scan_count;
    integer input_line_count;
    integer result_count;
    longint unsigned total_psum_count;
    longint unsigned carry_event_count;
    longint unsigned carry_hop_count;
    longint unsigned multi_hop_event_count;
    longint unsigned fifo_full_cycle_count;
    longint unsigned mac_stall_cycle_count;
    longint unsigned driver_wait_cycle_count;
    longint unsigned total_cycle_count;
    longint unsigned fp_flush_count;
    longint unsigned oob_drop_count;
    longint unsigned bucket_update_count;
    integer max_carry_chain;
    real carry_rate;
    real average_carry_hops;
    real stall_rate;
    real fp_activity_rate;
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

    always_ff @(posedge clk or negedge rst_n) begin : p_profile_counters
        if(!rst_n) begin
            total_psum_count <= 0;
            carry_event_count <= 0;
            carry_hop_count <= 0;
            multi_hop_event_count <= 0;
            fifo_full_cycle_count <= 0;
            mac_stall_cycle_count <= 0;
            total_cycle_count <= 0;
            fp_flush_count <= 0;
            oob_drop_count <= 0;
            bucket_update_count <= 0;
            max_carry_chain <= 0;
        end
        else begin
            total_cycle_count <= total_cycle_count + 1;
            if(in_valid && in_ready)
                total_psum_count <= total_psum_count + 1;
            if($root.TESTBED.u_dut.profile_carry_event)
                carry_event_count <= carry_event_count + 1;
            if($root.TESTBED.u_dut.profile_carry_hop)
                carry_hop_count <= carry_hop_count + 1;
            if($root.TESTBED.u_dut.profile_multi_hop)
                multi_hop_event_count <= multi_hop_event_count + 1;
            if($root.TESTBED.u_dut.profile_fifo_full)
                fifo_full_cycle_count <= fifo_full_cycle_count + 1;
            if(in_valid && !in_ready)
                mac_stall_cycle_count <= mac_stall_cycle_count + 1;
            if($root.TESTBED.u_dut.profile_fp_flush)
                fp_flush_count <= fp_flush_count + 1;
            if($root.TESTBED.u_dut.profile_oob_drop)
                oob_drop_count <= oob_drop_count + 1;
            if($root.TESTBED.u_dut.profile_bucket_update)
                bucket_update_count <= bucket_update_count + 1;
            if($root.TESTBED.u_dut.profile_carry_depth > max_carry_chain)
                max_carry_chain <= $root.TESTBED.u_dut.profile_carry_depth;
        end
    end

    task automatic drive_idle();
        acc_clear = 1'b0;
        weight_load = 1'b0;
        in_valid = 1'b0;
        w_sign_b = '0;
        a_sign_b = '0;
        w_exp = '0;
        a_exp = '0;
        w_man_b = '0;
        a_man_b = '0;
        in_last = 1'b0;
        out_ready = 1'b1;
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

        while(in_ready !== 1'b1) begin
            driver_wait_cycle_count++;
            @(negedge clk);
        end
        weight_load = weight_load_i;
        w_sign_b = w_sign_i;
        w_exp = w_exp_i;
        w_man_b = w_man_i;
        in_valid = 1'b1;
        in_last = block_index == BLOCKS_PER_DOT-1;
        a_sign_b = a_sign_i;
        a_exp = a_exp_i;
        a_man_b = a_man_i;
        @(posedge clk);
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

    initial begin
        fin = 0;
        fout = 0;
        input_line_count = 0;
        result_count = 0;
        driver_wait_cycle_count = 0;
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
        carry_rate = $itor(carry_event_count)
                   / $itor(total_psum_count);
        average_carry_hops = $itor(carry_hop_count)
                           / $itor(total_psum_count);
        stall_rate = $itor(driver_wait_cycle_count)
                   / $itor(total_cycle_count);
        fp_activity_rate = $itor(fp_flush_count)
                         / $itor(total_psum_count);
        $display("=========================================================");
        $display("  BUCKET GETTER TRACE COMPLETE");
        $display("  Input rows: %0d", input_line_count);
        $display("  Results:   %0d", result_count);
        $display("  Output: ../00_TESTBED/output.dat");
        $display("---------------------------------------------------------");
        $display("  Total psums:          %0d", total_psum_count);
        $display("  Bucket updates:       %0d", bucket_update_count);
        $display("  Carry events:         %0d", carry_event_count);
        $display("  Carry hops:           %0d", carry_hop_count);
        $display("  Multi-hop events:     %0d", multi_hop_event_count);
        $display("  Max carry chain:      %0d", max_carry_chain);
        $display("  FIFO-full cycles:     %0d", fifo_full_cycle_count);
        $display("  Held-valid stalls:    %0d", mac_stall_cycle_count);
        $display("  Driver wait cycles:   %0d", driver_wait_cycle_count);
        $display("  Total cycles:         %0d", total_cycle_count);
        $display("  FP flushes:           %0d", fp_flush_count);
        $display("  OOB drops:            %0d", oob_drop_count);
        $display("  Carry rate:           %0.6f", carry_rate);
        $display("  Average carry hops:   %0.6f", average_carry_hops);
        $display("  Stall rate:           %0.6f", stall_rate);
        $display("  FP activity rate:     %0.6f", fp_activity_rate);
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
                in_valid && !in_ready |=> $stable({
                    in_valid,
                    in_last,
                    weight_load,
                    w_sign_b,
                    w_exp,
                    w_man_b,
                    a_sign_b,
                    a_exp,
                    a_man_b
                });
        endproperty

        property p_known_result;
            @(posedge clk) disable iff(!rst_n)
                out_valid |-> !$isunknown({o_sign, o_exp, o_man});
        endproperty

        ap_hold_input_while_stalled: assert property(p_hold_input_while_stalled);
        ap_known_result: assert property(p_known_result);
    `endif

endmodule
