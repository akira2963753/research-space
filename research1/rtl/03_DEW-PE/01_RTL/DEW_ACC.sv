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
    input logic signed [`BFP_SUM_W-1:0] dp_value,
    input logic signed [`BFP_BEXP_W-1:0] blk_exp,
    output logic spill_valid,
    output logic spill_sign,
    output logic [`BFP_MAG_W-1:0] spill_mag,
    output logic signed [`BFP_BEXP_W-1:0] spill_exp,
    output logic done
);

    localparam int SPILL_FORMAT_W = `BFP_BEXP_W + `BFP_MAG_W;
    localparam int SPILL_INDEX_W = (ACC_W > 0)? $clog2(ACC_W + 1) : 1;
    localparam int ALIGN_MAX_SHIFT = (T_SKIP > T_REPLACE)?
                                     T_SKIP - 1 : T_REPLACE - 1;
    localparam int ALIGN_SHIFT_W = (ALIGN_MAX_SHIFT > 0)?
                                   $clog2(ALIGN_MAX_SHIFT + 1) : 1;
    localparam logic [SPILL_INDEX_W-1:0] SPILL_KEEP_MSB = `BFP_MAG_W - 1;
    localparam logic signed [`BFP_BEXP_W:0] SKIP_THRESHOLD = -T_SKIP;
    localparam logic signed [`BFP_BEXP_W:0] REPLACE_THRESHOLD = T_REPLACE;

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
    //                Accumulator and Eacc State
    //=============================================================
    logic eacc_valid_reg, eacc_valid_next;
    logic signed [`BFP_BEXP_W-1:0] eacc_exp_reg, eacc_exp_next;
    logic signed [ACC_W-1:0] acc_value_reg, acc_value_next;

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

    logic dp_nonzero_work;
    logic load_work, skip_work, replace_work, align_work;
    logic signed [`BFP_BEXP_W:0] delta_work;
    logic [ALIGN_SHIFT_W-1:0] align_shift_work;

    logic [`BFP_SUM_W-1:0] dp_abs_work;
    logic signed [ACC_W-1:0] input_value_work;
    logic shift_sign_work;
    logic signed [ACC_W-1:0] bypass_value_work;
    logic [ACC_W-1:0] shift_mag_work, aligned_mag_work;
    logic signed [ACC_W:0] aligned_value_work, bypass_value_ext_work;
    logic signed [ACC_W:0] candidate_work;
    logic overflow_work;

    logic signed [ACC_W-1:0] skip_mux_value_work;
    logic signed [ACC_W-1:0] replace_mux_value_work;
    logic signed [`BFP_BEXP_W-1:0] align_exp_work;
    logic signed [`BFP_BEXP_W-1:0] replace_mux_exp_work;
    logic replace_mux_valid_work;
    logic [ACC_W-1:0] final_mag_work;

    assign in_ready = !spill_valid_reg;
    assign input_fire = in_valid && in_ready;

    always_comb begin : DEW_UPDATE
        eacc_valid_next = eacc_valid_reg;
        eacc_exp_next = eacc_exp_reg;
        acc_value_next = acc_value_reg;
        spill_push_valid_work = 1'b0;
        spill_push_last_work = 1'b0;
        spill_push_sign_work = 1'b0;
        spill_push_mag_work = '0;
        spill_push_exp_work = '0;
        spill_raw_mag_work = '0;
        spill_raw_exp_work = '0;

        dp_nonzero_work = dp_value != 0;
        delta_work = $signed({blk_exp[`BFP_BEXP_W-1], blk_exp})
                     - $signed({eacc_exp_reg[`BFP_BEXP_W-1], eacc_exp_reg});
        load_work = dp_nonzero_work && !eacc_valid_reg;
        skip_work = dp_nonzero_work
                  && eacc_valid_reg
                  && delta_work <= SKIP_THRESHOLD;
        replace_work = dp_nonzero_work
                     && eacc_valid_reg
                     && delta_work >= REPLACE_THRESHOLD;
        align_work = dp_nonzero_work
                   && eacc_valid_reg
                   && !skip_work
                   && !replace_work;

        dp_abs_work = (dp_value[`BFP_SUM_W-1])?
                      $unsigned(-dp_value) : $unsigned(dp_value);
        input_value_work = $signed({
            {(ACC_W-`BFP_SUM_W){dp_value[`BFP_SUM_W-1]}},
            dp_value
        });

        // Only the smaller-exponent operand uses the shared shifter.
        shift_sign_work = 1'b0;
        shift_mag_work = '0;
        bypass_value_work = '0;
        align_shift_work = '0;
        align_exp_work = eacc_exp_reg;
        if(align_work) begin
            if(delta_work < 0) begin
                shift_sign_work = dp_value[`BFP_SUM_W-1];
                shift_mag_work = {{(ACC_W-`BFP_SUM_W){1'b0}}, dp_abs_work};
                bypass_value_work = acc_value_reg;
                align_shift_work = $unsigned(-delta_work);
                align_exp_work = eacc_exp_reg;
            end
            else begin
                shift_sign_work = acc_value_reg[ACC_W-1];
                shift_mag_work = (acc_value_reg[ACC_W-1])?
                                 $unsigned(-acc_value_reg) :
                                 $unsigned(acc_value_reg);
                bypass_value_work = input_value_work;
                align_shift_work = $unsigned(delta_work);
                align_exp_work = blk_exp;
            end
        end

        aligned_mag_work = shift_mag_work >> align_shift_work;
        aligned_value_work = (shift_sign_work)?
                             -$signed({1'b0, aligned_mag_work}) :
                             $signed({1'b0, aligned_mag_work});
        bypass_value_ext_work = $signed({
            bypass_value_work[ACC_W-1],
            bypass_value_work
        });
        candidate_work = aligned_value_work + bypass_value_ext_work;
        overflow_work = align_work
                      && candidate_work[ACC_W] != candidate_work[ACC_W-1];

        // ALIGN/SKIP mux followed by LOAD/REPLACE mux.
        skip_mux_value_work = (align_work)?
                              candidate_work[ACC_W-1:0] : acc_value_reg;
        replace_mux_value_work = (load_work || replace_work)?
                                 input_value_work : skip_mux_value_work;
        replace_mux_exp_work = (load_work
                                || replace_work
                                || (align_work && delta_work >= 0))?
                               blk_exp : eacc_exp_reg;
        replace_mux_valid_work = eacc_valid_reg || load_work;

        final_mag_work = '0;

        if(input_fire) begin
            eacc_valid_next = replace_mux_valid_work;
            eacc_exp_next = replace_mux_exp_work;
            acc_value_next = replace_mux_value_work;

            if(overflow_work) begin
                spill_push_valid_work = 1'b1;
                spill_push_sign_work = candidate_work[ACC_W];
                spill_raw_mag_work = (candidate_work[ACC_W])?
                                     $unsigned(-candidate_work) :
                                     $unsigned(candidate_work);
                spill_raw_exp_work = align_exp_work;
                eacc_valid_next = 1'b0;
                eacc_exp_next = '0;
                acc_value_next = '0;
            end

            if(in_last) begin
                if(spill_push_valid_work) spill_push_last_work = 1'b1;
                else if(acc_value_next != 0) begin
                    final_mag_work = (acc_value_next[ACC_W-1])?
                                     $unsigned(-acc_value_next) :
                                     $unsigned(acc_value_next);
                    spill_push_valid_work = 1'b1;
                    spill_push_last_work = 1'b1;
                    spill_push_sign_work = acc_value_next[ACC_W-1];
                    spill_raw_mag_work = {1'b0, final_mag_work};
                    spill_raw_exp_work = eacc_exp_next;
                end
                eacc_valid_next = 1'b0;
                eacc_exp_next = '0;
                acc_value_next = '0;
            end
        end

        {spill_push_exp_work, spill_push_mag_work} =
            FORMAT_SPILL(spill_raw_mag_work, spill_raw_exp_work);
    end

    assign done = (input_fire && in_last && !spill_push_valid_work) ||
                  (spill_valid_reg && spill_last_reg);

    //=============================================================
    //                     Sequential State
    //=============================================================
    always_ff @(posedge clk or negedge rst_n) begin : ACC_STATE
        if(!rst_n) begin
            eacc_valid_reg <= 1'b0;
            eacc_exp_reg <= '0;
            acc_value_reg <= '0;
        end
        else if(acc_clear) begin
            eacc_valid_reg <= 1'b0;
            eacc_exp_reg <= '0;
            acc_value_reg <= '0;
        end
        else begin
            eacc_valid_reg <= eacc_valid_next;
            eacc_exp_reg <= eacc_exp_next;
            acc_value_reg <= acc_value_next;
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
            spill_valid_reg <= spill_push_valid_work;
            spill_last_reg <= spill_push_last_work;
            if(spill_push_valid_work) begin
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
