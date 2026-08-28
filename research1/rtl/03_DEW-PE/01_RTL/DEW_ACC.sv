/******************************************************************************
* Copyright (C) 2026 Marco
*
* File Name:    DEW_ACC.sv
* Project:      Dynamic Exponent Window Accumulation Based PE
* Module:       DEW Accumulator
* Author:       Marco <harry2963753@gmail.com>
*
******************************************************************************/
`include "include.vh"

module DEW_ACC #(
    parameter int ACC_W = 24,
    parameter int T_SKIP = 9,
    parameter int T_REPLACE = 3
) (
    input logic clk,
    input logic rst_n,
    input logic acc_clear,
    input logic in_valid,
    output logic in_ready,
    input logic in_last,
    input logic dp_sign,
    input logic [`BFP_MAG_W-1:0] dp_mag,
    input logic signed [`BFP_BEXP_W-1:0] blk_exp,
    output logic spill_valid,
    input logic spill_ready,
    output logic spill_sign,
    output logic [`BFP_MAG_W-1:0] spill_mag,
    output logic signed [`BFP_BEXP_W-1:0] spill_exp,
    output logic done
);

    localparam int SPILL_FORMAT_W = `BFP_BEXP_W + `BFP_MAG_W;
    localparam int SPILL_INDEX_W = (ACC_W > 0)? $clog2(ACC_W + 1) : 1;
    localparam logic [SPILL_INDEX_W-1:0] SPILL_KEEP_MSB = `BFP_MAG_W - 1;

    function automatic [SPILL_FORMAT_W-1:0] FORMAT_SPILL(
        input logic [ACC_W:0] raw_mag,
        input logic signed [`BFP_BEXP_W-1:0] raw_exp
    );
        logic [`BFP_MAG_W-1:0] format_mag;
        logic signed [`BFP_BEXP_W-1:0] format_exp;
        logic [SPILL_INDEX_W-1:0] msb_position;
        logic [SPILL_INDEX_W-1:0] shift_amount;
        begin
            format_mag = '0;
            format_exp = raw_exp;
            msb_position = 0;
            shift_amount = 0;
            for(int i = 0; i <= ACC_W; i++) if(raw_mag[i]) msb_position = i;
            if(msb_position > SPILL_KEEP_MSB) shift_amount = msb_position - SPILL_KEEP_MSB;
            format_mag = raw_mag >> shift_amount;
            format_exp = $signed(raw_exp) + $signed({1'b0, shift_amount});
            FORMAT_SPILL = {format_exp, format_mag};
        end
    endfunction

    //=============================================================
    //                    Accumulator Registers
    //=============================================================
    logic acc_valid_reg, acc_valid_next;
    logic signed [ACC_W-1:0] acc_value_reg, acc_value_next;
    logic signed [`BFP_BEXP_W-1:0] acc_lsb_exp_reg, acc_lsb_exp_next;

    logic spill_valid_reg, spill_last_reg;
    logic spill_sign_reg;
    logic [`BFP_MAG_W-1:0] spill_mag_reg;
    logic signed [`BFP_BEXP_W-1:0] spill_exp_reg;

    //=============================================================
    //                    Combinational Datapath
    //=============================================================
    logic input_fire;
    logic spill_push_valid_work, spill_push_last_work;
    logic spill_push_sign_work;
    logic [`BFP_MAG_W-1:0] spill_push_mag_work;
    logic signed [`BFP_BEXP_W-1:0] spill_push_exp_work;
    logic [ACC_W:0] spill_raw_mag_work;
    logic signed [`BFP_BEXP_W-1:0] spill_raw_exp_work;

    logic signed [ACC_W-1:0] input_value_work;
    logic [ACC_W-1:0] acc_mag_work, final_mag_work;
    logic [ACC_W:0] old_mag_aligned_work, new_mag_aligned_work;
    logic signed [ACC_W:0] old_value_aligned_work;
    logic signed [ACC_W:0] new_value_aligned_work;
    logic signed [ACC_W:0] candidate_work;
    logic signed [`BFP_BEXP_W-1:0] common_lsb_exp_work;
    logic overflow_work;
    integer new_msb_index_work, acc_msb_index_work;
    integer new_lead_exp_work, acc_lead_exp_work, delta_work;
    integer old_shift_work, new_shift_work;

    assign in_ready = !spill_valid_reg;
    assign input_fire = in_valid && in_ready;

    always_comb begin : DEW_UPDATE
        acc_valid_next = acc_valid_reg;
        acc_value_next = acc_value_reg;
        acc_lsb_exp_next = acc_lsb_exp_reg;
        spill_push_valid_work = 1'b0;
        spill_push_last_work = 1'b0;
        spill_push_sign_work = 1'b0;
        spill_push_mag_work = '0;
        spill_push_exp_work = '0;
        spill_raw_mag_work = '0;
        spill_raw_exp_work = '0;

        input_value_work = $signed({{(ACC_W-`BFP_SUM_W){1'b0}}, 1'b0, dp_mag});
        if(dp_sign) input_value_work = -input_value_work;

        acc_mag_work = (acc_value_reg[ACC_W-1])?
                       $unsigned(-acc_value_reg) : $unsigned(acc_value_reg);
        final_mag_work = '0;
        old_mag_aligned_work = '0;
        new_mag_aligned_work = '0;
        old_value_aligned_work = '0;
        new_value_aligned_work = '0;
        candidate_work = '0;
        common_lsb_exp_work = blk_exp;
        overflow_work = 1'b0;
        new_msb_index_work = 0;
        acc_msb_index_work = 0;
        new_lead_exp_work = 0;
        acc_lead_exp_work = 0;
        delta_work = 0;
        old_shift_work = 0;
        new_shift_work = 0;

        for(int i = 0; i < `BFP_MAG_W; i++) if(dp_mag[i]) new_msb_index_work = i;
        for(int i = 0; i < ACC_W; i++) if(acc_mag_work[i]) acc_msb_index_work = i;

        new_lead_exp_work = $signed(blk_exp) + new_msb_index_work;
        acc_lead_exp_work = $signed(acc_lsb_exp_reg) + acc_msb_index_work;
        delta_work = new_lead_exp_work - acc_lead_exp_work;

        if(input_fire) begin
            if(dp_mag != 0) begin
                if(!acc_valid_reg) begin
                    acc_valid_next = 1'b1;
                    acc_value_next = input_value_work;
                    acc_lsb_exp_next = blk_exp;
                end
                else if(delta_work <= -T_SKIP) acc_valid_next = acc_valid_reg;
                else if(delta_work >= T_REPLACE) begin
                    acc_valid_next = 1'b1;
                    acc_value_next = input_value_work;
                    acc_lsb_exp_next = blk_exp;
                end
                else begin
                    common_lsb_exp_work = ($signed(acc_lsb_exp_reg) >= $signed(blk_exp))?
                                          acc_lsb_exp_reg : blk_exp;
                    old_shift_work = $signed(common_lsb_exp_work) - $signed(acc_lsb_exp_reg);
                    new_shift_work = $signed(common_lsb_exp_work) - $signed(blk_exp);
                    old_mag_aligned_work = {1'b0, acc_mag_work} >> old_shift_work;
                    new_mag_aligned_work =
                        {{(ACC_W+1-`BFP_MAG_W){1'b0}}, dp_mag} >> new_shift_work;
                    old_value_aligned_work = (acc_value_reg[ACC_W-1])?
                                             -$signed(old_mag_aligned_work) :
                                             $signed(old_mag_aligned_work);
                    new_value_aligned_work = (dp_sign)?
                                             -$signed(new_mag_aligned_work) :
                                             $signed(new_mag_aligned_work);
                    candidate_work = old_value_aligned_work + new_value_aligned_work;
                    overflow_work = candidate_work[ACC_W] != candidate_work[ACC_W-1];
                    if(overflow_work) begin
                        spill_push_valid_work = 1'b1;
                        spill_push_sign_work = candidate_work[ACC_W];
                        spill_raw_mag_work = (candidate_work[ACC_W])?
                                             $unsigned(-candidate_work) :
                                             $unsigned(candidate_work);
                        spill_raw_exp_work = common_lsb_exp_work;
                        acc_valid_next = 1'b0;
                        acc_value_next = '0;
                        acc_lsb_exp_next = '0;
                    end
                    else begin
                        acc_value_next = candidate_work[ACC_W-1:0];
                        acc_lsb_exp_next = common_lsb_exp_work;
                        acc_valid_next = candidate_work != 0;
                    end
                end
            end

            if(in_last) begin
                if(spill_push_valid_work) spill_push_last_work = 1'b1;
                else if(acc_valid_next) begin
                    final_mag_work = (acc_value_next[ACC_W-1])?
                                     $unsigned(-acc_value_next) :
                                     $unsigned(acc_value_next);
                    spill_push_valid_work = 1'b1;
                    spill_push_last_work = 1'b1;
                    spill_push_sign_work = acc_value_next[ACC_W-1];
                    spill_raw_mag_work = {1'b0, final_mag_work};
                    spill_raw_exp_work = acc_lsb_exp_next;
                end
                acc_valid_next = 1'b0;
                acc_value_next = '0;
                acc_lsb_exp_next = '0;
            end
        end

        {spill_push_exp_work, spill_push_mag_work} =
            FORMAT_SPILL(spill_raw_mag_work, spill_raw_exp_work);
    end

    assign done = (input_fire && in_last && !spill_push_valid_work) ||
                  (spill_valid_reg && spill_ready && spill_last_reg);

    //=============================================================
    //                     Sequential State
    //=============================================================
    always_ff @(posedge clk or negedge rst_n) begin : ACC_STATE
        if(!rst_n) begin
            acc_valid_reg <= 1'b0;
            acc_value_reg <= '0;
            acc_lsb_exp_reg <= '0;
        end
        else if(acc_clear) begin
            acc_valid_reg <= 1'b0;
            acc_value_reg <= '0;
            acc_lsb_exp_reg <= '0;
        end
        else begin
            acc_valid_reg <= acc_valid_next;
            acc_value_reg <= acc_value_next;
            acc_lsb_exp_reg <= acc_lsb_exp_next;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin : SPILL_STATE
        if(!rst_n) begin
            spill_valid_reg <= 1'b0;
            spill_last_reg <= 1'b0;
            spill_sign_reg <= 1'b0;
            spill_mag_reg <= '0;
            spill_exp_reg <= '0;
        end
        else if(acc_clear) begin
            spill_valid_reg <= 1'b0;
            spill_last_reg <= 1'b0;
            spill_sign_reg <= 1'b0;
            spill_mag_reg <= '0;
            spill_exp_reg <= '0;
        end
        else begin
            if(spill_valid_reg && spill_ready) begin
                spill_valid_reg <= 1'b0;
                spill_last_reg <= 1'b0;
            end
            if(spill_push_valid_work) begin
                spill_valid_reg <= 1'b1;
                spill_last_reg <= spill_push_last_work;
                spill_sign_reg <= spill_push_sign_work;
                spill_mag_reg <= spill_push_mag_work;
                spill_exp_reg <= spill_push_exp_work;
            end
        end
    end

    assign spill_valid = spill_valid_reg;
    assign spill_sign = spill_sign_reg;
    assign spill_mag = spill_mag_reg;
    assign spill_exp = spill_exp_reg;

endmodule
