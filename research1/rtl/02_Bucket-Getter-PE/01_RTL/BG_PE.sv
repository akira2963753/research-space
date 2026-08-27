/******************************************************************************
* Copyright (C) 2026 Marco
*
* File Name:    BG_PE.sv
* Project:      Bucket Getter BFP Processing Element
* Module:       Bucket Getter processing element top
* Author:       Marco <harry2963753@gmail.com>
*
******************************************************************************/
`include "include.vh"

module BG_PE(
    input logic clk,
    input logic rst_n,
    input logic acc_clear,
    input logic weight_load,
    input logic in_valid,
    input logic [`BFP_SIGN_BW-1:0] w_sign_b,
    input logic [`BFP_SIGN_BW-1:0] a_sign_b,
    input logic [`BFP_EXP_W-1:0] w_exp,
    input logic [`BFP_EXP_W-1:0] a_exp,
    input logic [`BFP_MAN_BW-1:0] w_man_b,
    input logic [`BFP_MAN_BW-1:0] a_man_b,
    output logic in_ready,
    input logic in_last,
    output logic out_valid,
    input logic out_ready,
    output logic o_sign,
    output logic [`FPACC_EXP_W-1:0] o_exp,
    output logic [`FPACC_MAN_W-1:0] o_man,
    output logic busy
);

    logic [`BFP_SIGN_BW-1:0] w_sign_reg;
    logic [`BFP_EXP_W-1:0] w_exp_reg;
    logic [`BFP_MAN_BW-1:0] w_man_reg;

    logic dp_sign;
    logic [`BFP_MAG_W-1:0] dp_mag;
    logic signed [`BFP_BEXP_W-1:0] blk_exp;

    logic mac_valid_reg;
    logic mac_last_reg;
    logic mac_sign_reg;
    logic [`BFP_MAG_W-1:0] mac_mag_reg;
    logic signed [`BFP_BEXP_W-1:0] mac_exp_reg;
    logic mac_ready;
    logic input_fire;

    logic bg_ready;
    logic bg_spill_valid;
    logic bg_spill_sign;
    logic [`BFP_MAG_W-1:0] bg_spill_mag;
    logic signed [`BFP_BEXP_W-1:0] bg_spill_exp;
    logic bg_done;
    logic bg_busy;
    logic result_valid_reg;

    logic profile_fifo_full;
    logic profile_bucket_update;
    logic profile_carry_event;
    logic profile_carry_hop;
    logic profile_multi_hop;
    logic profile_fp_flush;
    logic profile_oob_drop;
    logic [2:0] profile_carry_depth;

    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            w_sign_reg <= '0;
            w_exp_reg <= '0;
            w_man_reg <= '0;
        end
        else if(weight_load) begin
            w_sign_reg <= w_sign_b;
            w_exp_reg <= w_exp;
            w_man_reg <= w_man_b;
        end
    end

    assign blk_exp = $signed({1'b0, w_exp_reg})
                   + $signed({1'b0, a_exp})
                   - `BFP_EXP_BIAS;

    assign mac_ready = !mac_valid_reg || bg_ready;
    assign in_ready = mac_ready && !result_valid_reg;
    assign input_fire = in_valid && in_ready;

    INT_MAC u_int_mac(
        .w_sign_b(w_sign_reg),
        .a_sign_b(a_sign_b),
        .w_man_b(w_man_reg),
        .a_man_b(a_man_b),
        .dp_sign(dp_sign),
        .dp_mag(dp_mag)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            mac_valid_reg <= 1'b0;
            mac_last_reg <= 1'b0;
            mac_sign_reg <= 1'b0;
            mac_mag_reg <= '0;
            mac_exp_reg <= '0;
        end
        else if(acc_clear) begin
            mac_valid_reg <= 1'b0;
            mac_last_reg <= 1'b0;
            mac_sign_reg <= 1'b0;
            mac_mag_reg <= '0;
            mac_exp_reg <= '0;
        end
        else if(mac_ready) begin
            mac_valid_reg <= input_fire;
            if(input_fire) begin
                mac_last_reg <= in_last;
                mac_sign_reg <= dp_sign;
                mac_mag_reg <= dp_mag;
                mac_exp_reg <= blk_exp;
            end
        end
    end

    BG_ACC u_bg_acc(
        .clk(clk),
        .rst_n(rst_n),
        .acc_clear(acc_clear),
        .in_valid(mac_valid_reg),
        .in_ready(bg_ready),
        .in_last(mac_last_reg),
        .dp_sign(mac_sign_reg),
        .dp_mag(mac_mag_reg),
        .blk_exp(mac_exp_reg),
        .spill_valid(bg_spill_valid),
        .spill_ready(1'b1),
        .spill_sign(bg_spill_sign),
        .spill_mag(bg_spill_mag),
        .spill_exp(bg_spill_exp),
        .done(bg_done),
        .busy(bg_busy),
        .profile_fifo_full(profile_fifo_full),
        .profile_bucket_update(profile_bucket_update),
        .profile_carry_event(profile_carry_event),
        .profile_carry_hop(profile_carry_hop),
        .profile_multi_hop(profile_multi_hop),
        .profile_fp_flush(profile_fp_flush),
        .profile_oob_drop(profile_oob_drop),
        .profile_carry_depth(profile_carry_depth)
    );

    FP_ACC u_fp_acc(
        .clk(clk),
        .rst_n(rst_n),
        .acc_clear(acc_clear),
        .in_valid(bg_spill_valid),
        .dp_sign(bg_spill_sign),
        .dp_mag(bg_spill_mag),
        .blk_exp(bg_spill_exp),
        .o_sign(o_sign),
        .o_exp(o_exp),
        .o_man(o_man)
    );

    assign out_valid = result_valid_reg;
    assign busy = mac_valid_reg || bg_busy || result_valid_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n)
            result_valid_reg <= 1'b0;
        else if(acc_clear)
            result_valid_reg <= 1'b0;
        else if(bg_done)
            result_valid_reg <= 1'b1;
        else if(result_valid_reg && out_ready)
            result_valid_reg <= 1'b0;
    end

endmodule
