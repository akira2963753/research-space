/******************************************************************************
* Copyright (C) 2026 Marco
*
* File Name:    DEW_PE.sv
* Project:      Dynamic Exponent Window Accumulation Based PE
* Module:       DEW Processing Element
* Author:       Marco <harry2963753@gmail.com>
*
******************************************************************************/
`include "include.vh"

module DEW_PE #(
    parameter int DEW_ACC_W = 24,
    parameter int T_SKIP = 9,
    parameter int T_REPLACE = 3
) (
    input logic clk,
    input logic rst_n,
    input logic acc_clear,
    input logic weight_load,
    input logic in_valid,
    input logic [`BFP_SIGN_BW-1:0] w_sign_b,
    input logic [`BFP_SIGN_BW-1:0] a_sign_b,
    input logic [`BFP_EXP_W-1:0] w_exp,
    input logic [`BFP_EXP_W-1:0] a_exp,
    input logic [`BFP_EXP_W-1:0] oa_exp,
    input logic [`BFP_MAN_BW-1:0] w_man_b,
    input logic [`BFP_MAN_BW-1:0] a_man_b,
    input logic [`OI_W-1:0] oi1,
    input logic [`OI_W-1:0] oi2,
    output logic in_ready,
    input logic in_last,
    output logic out_valid,
    input logic out_ready,
    output logic o_sign,
    output logic [`FPACC_EXP_W-1:0] o_exp,
    output logic [`FPACC_MAN_W-1:0] o_man,
    output logic busy
);

    //=============================================================
    //                  Weight-Stationary Registers
    //=============================================================
    logic [`BFP_SIGN_BW-1:0] w_sign_reg;
    logic [`BFP_EXP_W-1:0] w_exp_reg;
    logic [`BFP_MAN_BW-1:0] w_man_reg;

    always_ff @(posedge clk or negedge rst_n) begin : WEIGHT_REGISTERS
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

    //=============================================================
    //                        Exponents
    //=============================================================
    logic signed [`BFP_BEXP_W-1:0] normal_blk_exp;
    logic signed [`BFP_BEXP_W-1:0] outlier_blk_exp;

    assign normal_blk_exp = $signed({1'b0, w_exp_reg})
                          + $signed({1'b0, a_exp})
                          - `BFP_EXP_BIAS;
    assign outlier_blk_exp = $signed({1'b0, w_exp_reg})
                           + $signed({1'b0, oa_exp})
                           - `BFP_EXP_BIAS;

    //=============================================================
    //                    Outlier-Aware INT MAC
    //=============================================================
    logic signed [`BFP_SUM_W-1:0] normal_psum;
    logic outlier_sign;
    logic [`BFP_SPROD_W-1:0] outlier_mag;

    INT_MAC u_int_mac (
        .w_sign_b(w_sign_reg),
        .a_sign_b(a_sign_b),
        .w_man_b(w_man_reg),
        .a_man_b(a_man_b),
        .oi1(oi1),
        .oi2(oi2),
        .normal_psum(normal_psum),
        .outlier_sign(outlier_sign),
        .outlier_mag(outlier_mag)
    );

    //=============================================================
    //                    Integer MAC Pipeline
    //=============================================================
    logic input_fire;
    logic mac_valid_reg, mac_last_reg;
    logic signed [`BFP_SUM_W-1:0] mac_normal_psum_reg;
    logic signed [`BFP_BEXP_W-1:0] mac_normal_exp_reg;
    logic mac_outlier_sign_reg;
    logic [`BFP_SPROD_W-1:0] mac_outlier_mag_reg;
    logic signed [`BFP_BEXP_W-1:0] mac_outlier_exp_reg;
    logic mac_ready, mac_fire;

    always_ff @(posedge clk or negedge rst_n) begin : MAC_PIPELINE
        if(!rst_n) begin
            mac_valid_reg <= 1'b0;
            mac_last_reg <= 1'b0;
            mac_normal_psum_reg <= '0;
            mac_normal_exp_reg <= '0;
            mac_outlier_sign_reg <= 1'b0;
            mac_outlier_mag_reg <= '0;
            mac_outlier_exp_reg <= '0;
        end
        else if(acc_clear) begin
            mac_valid_reg <= 1'b0;
            mac_last_reg <= 1'b0;
            mac_normal_psum_reg <= '0;
            mac_normal_exp_reg <= '0;
            mac_outlier_sign_reg <= 1'b0;
            mac_outlier_mag_reg <= '0;
            mac_outlier_exp_reg <= '0;
        end
        else if(mac_ready) begin
            mac_valid_reg <= input_fire;
            if(input_fire) begin
                mac_last_reg <= in_last;
                mac_normal_psum_reg <= normal_psum;
                mac_normal_exp_reg <= normal_blk_exp;
                mac_outlier_sign_reg <= outlier_sign;
                mac_outlier_mag_reg <= outlier_mag;
                mac_outlier_exp_reg <= outlier_blk_exp;
            end
        end
    end

    //=============================================================
    //                       DEW Accumulator
    //=============================================================
    logic dew_in_ready;
    logic dew_spill_valid;
    logic dew_spill_sign;
    logic [`BFP_MAG_W-1:0] dew_spill_mag;
    logic signed [`BFP_BEXP_W-1:0] dew_spill_exp;
    logic dew_done;

    DEW_ACC #(
        .ACC_W(DEW_ACC_W),
        .T_SKIP(T_SKIP),
        .T_REPLACE(T_REPLACE)
    ) u_dew_acc (
        .clk(clk),
        .rst_n(rst_n),
        .acc_clear(acc_clear),
        .in_valid(mac_valid_reg),
        .in_ready(dew_in_ready),
        .in_last(mac_last_reg),
        .dp_value(mac_normal_psum_reg),
        .blk_exp(mac_normal_exp_reg),
        .spill_valid(dew_spill_valid),
        .spill_sign(dew_spill_sign),
        .spill_mag(dew_spill_mag),
        .spill_exp(dew_spill_exp),
        .done(dew_done)
    );

    //=============================================================
    //                    Local FP Source Select
    //=============================================================
    logic fp_in_valid, fp_in_sign;
    logic [`BFP_MAG_W-1:0] fp_in_mag;
    logic signed [`BFP_BEXP_W-1:0] fp_in_exp;
    logic [`BFP_MAG_W-1:0] current_outlier_mag;
    logic current_outlier;

    assign current_outlier = mac_fire && mac_outlier_mag_reg != 0;
    assign current_outlier_mag = {
        {(`BFP_MAG_W-`BFP_SPROD_W){1'b0}},
        mac_outlier_mag_reg
    };
    assign fp_in_valid = dew_spill_valid || current_outlier;
    assign fp_in_sign = (dew_spill_valid)?
                        dew_spill_sign :
                        (current_outlier)? mac_outlier_sign_reg : 1'b0;
    assign fp_in_mag = (dew_spill_valid)?
                       dew_spill_mag :
                       (current_outlier)? current_outlier_mag : '0;
    assign fp_in_exp = (dew_spill_valid)?
                       dew_spill_exp :
                       (current_outlier)? mac_outlier_exp_reg : '0;

    FP_ACC u_fp_acc (
        .clk(clk),
        .rst_n(rst_n),
        .acc_clear(acc_clear),
        .in_valid(fp_in_valid),
        .dp_sign(fp_in_sign),
        .dp_mag(fp_in_mag),
        .blk_exp(fp_in_exp),
        .o_sign(o_sign),
        .o_exp(o_exp),
        .o_man(o_man)
    );

    //=============================================================
    //                    Transaction Completion
    //=============================================================
    logic transaction_active_reg;
    logic closing_reg, result_valid_reg;
    logic result_complete;

    assign mac_fire = mac_valid_reg && dew_in_ready;
    assign mac_ready = !mac_valid_reg || dew_in_ready;
    assign in_ready = mac_ready && !closing_reg && !result_valid_reg;
    assign input_fire = in_valid && in_ready;
    assign result_complete = closing_reg && dew_done;

    always_ff @(posedge clk or negedge rst_n) begin : RESULT_CONTROL
        if(!rst_n) begin
            transaction_active_reg <= 1'b0;
            closing_reg <= 1'b0;
            result_valid_reg <= 1'b0;
        end
        else if(acc_clear) begin
            transaction_active_reg <= 1'b0;
            closing_reg <= 1'b0;
            result_valid_reg <= 1'b0;
        end
        else begin
            if(input_fire) transaction_active_reg <= 1'b1;
            if(input_fire && in_last) closing_reg <= 1'b1;
            if(result_valid_reg && out_ready) begin
                transaction_active_reg <= 1'b0;
                result_valid_reg <= 1'b0;
            end
            if(result_complete) begin
                closing_reg <= 1'b0;
                result_valid_reg <= 1'b1;
            end
        end
    end

    assign out_valid = result_valid_reg;
    assign busy = transaction_active_reg;

endmodule
