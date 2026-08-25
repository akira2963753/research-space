/******************************************************************************
* Copyright (C) 2026 Marco
*
* File Name:    BG_ACC.sv
* Project:      Bucket Getter BFP Processing Element
* Module:       Parallel-prefix Top-6 adaptive circular bucket accumulator
* Author:       Marco <harry2963753@gmail.com>
*
******************************************************************************/
`include "include.vh"

module BG_ACC(
    input logic clk,
    input logic rst_n,
    input logic i_start,
    input logic i_valid,
    output logic o_ready,
    input logic i_last,
    input logic i_dp_sign,
    input logic [`BFP_MAG_W-1:0] i_dp_mag,
    input logic signed [`BFP_BEXP_W-1:0] i_exp,
    output logic o_spill_valid,
    input logic i_spill_ready,
    output logic o_spill_sign,
    output logic [`BFP_MAG_W-1:0] o_spill_mag,
    output logic signed [`BFP_BEXP_W-1:0] o_spill_exp,
    output logic o_done,
    output logic o_busy
);

    import BG_PKG::*;

    localparam int CARRY_STATE_COUNT = 5;
    localparam logic [2:0] CARRY_ZERO = 3'd2;

    typedef enum logic [1:0] {
        S_ACC,
        S_DRAIN,
        S_WAIT,
        S_DONE
    } state_t;

    state_t state_reg;
    state_t state_next;

    logic signed [`BG_BUCKET_WIDTH-1:0] bucket_reg [0:`BG_BUCKET_COUNT-1];
    logic signed [`BG_BUCKET_WIDTH-1:0] bucket_next [0:`BG_BUCKET_COUNT-1];
    logic [`BG_BUCKET_COUNT-1:0] bucket_valid_reg;
    logic [`BG_BUCKET_COUNT-1:0] bucket_valid_next;
    logic emax_valid_reg;
    logic emax_valid_next;
    logic signed [`BFP_BEXP_W-1:0] emax_base_reg;
    logic signed [`BFP_BEXP_W-1:0] emax_base_next;
    logic [`BG_BUCKET_PTR_W-1:0] front_ptr_reg;
    logic [`BG_BUCKET_PTR_W-1:0] front_ptr_next;
    logic [`BG_BUCKET_PTR_W-1:0] drain_offset_reg;
    logic [`BG_BUCKET_PTR_W-1:0] drain_offset_next;

    logic spill_valid_reg;
    logic spill_sign_reg;
    logic [`BFP_MAG_W-1:0] spill_mag_reg;
    logic signed [`BFP_BEXP_W-1:0] spill_exp_reg;
    logic spill_slot_ready;
    logic spill_push_valid;
    logic spill_push_sign;
    logic [`BFP_MAG_W-1:0] spill_push_mag;
    logic signed [`BFP_BEXP_W-1:0] spill_push_exp;

    logic signed [`BFP_SUM_W-1:0] input_sum_work;
    logic signed [`BFP_BEXP_W-1:0] prepared_base_work;
    logic [`BG_BUCKET_SHIFT_W-1:0] prepared_shift_work;
    logic signed [`BG_WORK_W-1:0] prepared_value_work;
    logic signed [`BG_WORK_W-1:0] quotient_work [0:`BG_WORK_DIGITS];
    logic signed [`BG_BUCKET_WIDTH-1:0] input_radix_digit_work [0:`BG_WORK_DIGITS-1];
    logic signed [`BG_WORK_W-1:0] input_radix_ext_work [0:`BG_WORK_DIGITS-1];
    logic [`BG_WORK_DIGITS-1:0] quotient_nonzero_work;
    logic [`BG_BUCKET_PTR_W-1:0] input_top_offset_work;
    logic signed [`BFP_BEXP_W-1:0] input_top_base_work;
    logic signed [`BFP_BEXP_W-1:0] input_digit_base_work [0:`BG_WORK_DIGITS-1];

    logic signed [`BG_BUCKET_WIDTH-1:0] logical_bucket_work [0:`BG_BUCKET_COUNT-1];
    logic signed [`BG_BUCKET_WIDTH-1:0] rotated_bucket_work [0:`BG_BUCKET_COUNT-1];
    logic signed [`BG_BUCKET_WIDTH-1:0] input_bucket_digit_work [0:`BG_BUCKET_COUNT-1];
    logic signed [`BG_BUCKET_WIDTH-1:0] updated_bucket_work [0:`BG_BUCKET_COUNT-1];
    logic [`BG_BUCKET_COUNT-1:0] updated_bucket_valid_work;
    logic signed [`BFP_BEXP_W-1:0] logical_base_work [0:`BG_BUCKET_COUNT-1];

    logic signed [5:0] input_add_variant [0:`BG_BUCKET_COUNT-1][0:CARRY_STATE_COUNT-1];
    logic signed [`BG_BUCKET_WIDTH-1:0] input_norm_variant [0:`BG_BUCKET_COUNT-1][0:CARRY_STATE_COUNT-1];
    logic input_norm_valid_variant [0:`BG_BUCKET_COUNT-1][0:CARRY_STATE_COUNT-1];
    logic signed [5:0] input_norm_ext_variant [0:`BG_BUCKET_COUNT-1][0:CARRY_STATE_COUNT-1];
    logic signed [2:0] input_carry_variant [0:`BG_BUCKET_COUNT-1][0:CARRY_STATE_COUNT-1];
    logic signed [5:0] bucket_add_variant [0:`BG_BUCKET_COUNT-1][0:CARRY_STATE_COUNT-1];
    logic signed [`BG_BUCKET_WIDTH-1:0] bucket_norm_variant [0:`BG_BUCKET_COUNT-1][0:CARRY_STATE_COUNT-1];
    logic bucket_norm_valid_variant [0:`BG_BUCKET_COUNT-1][0:CARRY_STATE_COUNT-1];
    logic signed [5:0] bucket_norm_ext_variant [0:`BG_BUCKET_COUNT-1][0:CARRY_STATE_COUNT-1];
    logic signed [2:0] bucket_carry_variant [0:`BG_BUCKET_COUNT-1][0:CARRY_STATE_COUNT-1];
    logic signed [3:0] total_carry_variant [0:`BG_BUCKET_COUNT-1][0:CARRY_STATE_COUNT-1];
    logic [2:0] transition_l0 [0:`BG_BUCKET_COUNT-1][0:CARRY_STATE_COUNT-1];
    logic [2:0] transition_l1 [0:`BG_BUCKET_COUNT-1][0:CARRY_STATE_COUNT-1];
    logic [2:0] transition_l2 [0:`BG_BUCKET_COUNT-1][0:CARRY_STATE_COUNT-1];
    logic [2:0] transition_l3 [0:`BG_BUCKET_COUNT-1][0:CARRY_STATE_COUNT-1];
    logic [2:0] carry_in_state_work [0:`BG_BUCKET_COUNT-1];

    logic signed [`BFP_BEXP_W-1:0] active_emax_work;
    logic [`BG_BUCKET_PTR_W-1:0] active_front_ptr_work;
    logic [`BG_BUCKET_PTR_W-1:0] final_front_ptr_work;
    logic signed [`BFP_BEXP_W-1:0] final_emax_work;
    logic signed [8:0] rotate_steps_work;
    logic rotate_all_work;
    logic extra_top_work;
    logic signed [2:0] top_input_carry_work;
    logic signed [2:0] top_bucket_carry_work;
    logic signed [`BG_BUCKET_WIDTH-1:0] top_input_digit_work;
    logic top_input_digit_valid_work;
    logic signed [`BG_BUCKET_WIDTH-1:0] tail_bucket_work;
    logic tail_bucket_valid_work;
    integer drain_ptr_work;
    logic signed [`BFP_BEXP_W-1:0] drain_base_work;

    always_comb begin : p_next_state
        state_next = state_reg;
        bucket_valid_next = bucket_valid_reg;
        emax_valid_next = emax_valid_reg;
        emax_base_next = emax_base_reg;
        front_ptr_next = front_ptr_reg;
        drain_offset_next = drain_offset_reg;

        for(int i = 0; i < `BG_BUCKET_COUNT; i++) begin
            bucket_next[i] = bucket_reg[i];
        end

        o_ready = 1'b0;
        o_spill_valid = spill_valid_reg;
        o_spill_sign = spill_sign_reg;
        o_spill_mag = spill_mag_reg;
        o_spill_exp = spill_exp_reg;
        o_done = 1'b0;
        o_busy = state_reg != S_ACC;

        spill_slot_ready = !spill_valid_reg || i_spill_ready;
        spill_push_valid = 1'b0;
        spill_push_sign = 1'b0;
        spill_push_mag = '0;
        spill_push_exp = '0;

        input_sum_work = $signed({1'b0, i_dp_mag});
        if(i_dp_sign) input_sum_work = -input_sum_work;
        prepared_base_work = EXP_BASE(i_exp);
        prepared_shift_work = i_exp - prepared_base_work;
        prepared_value_work = {
            {(`BG_WORK_W-`BFP_SUM_W){input_sum_work[`BFP_SUM_W-1]}},
            input_sum_work
        };
        prepared_value_work = prepared_value_work <<< prepared_shift_work;

        quotient_work[0] = prepared_value_work;
        for(int i = 0; i < `BG_WORK_DIGITS; i++) begin
            input_radix_digit_work[i] = quotient_work[i][`BG_BUCKET_WIDTH-1:0];
            input_radix_ext_work[i] = {
                {(`BG_WORK_W-`BG_BUCKET_WIDTH){
                    input_radix_digit_work[i][`BG_BUCKET_WIDTH-1]
                }},
                input_radix_digit_work[i]
            };
            quotient_work[i+1] = (quotient_work[i]-input_radix_ext_work[i])
                               >>> `BG_EXP_PER_BUCKET;
            quotient_nonzero_work[i] = quotient_work[i] != 0;
            input_digit_base_work[i] = prepared_base_work
                                     + i*`BG_EXP_PER_BUCKET;
        end

        casez(quotient_nonzero_work)
            6'b1?????: input_top_offset_work = 3'd5;
            6'b01????: input_top_offset_work = 3'd4;
            6'b001???: input_top_offset_work = 3'd3;
            6'b0001??: input_top_offset_work = 3'd2;
            6'b00001?: input_top_offset_work = 3'd1;
            default: input_top_offset_work = '0;
        endcase

        input_top_base_work = prepared_base_work
                            + input_top_offset_work*`BG_EXP_PER_BUCKET;

        for(int i = 0; i < `BG_BUCKET_COUNT; i++) begin
            logical_bucket_work[i] = '0;
            rotated_bucket_work[i] = '0;
            input_bucket_digit_work[i] = '0;
            updated_bucket_work[i] = '0;
            updated_bucket_valid_work[i] = 1'b0;
            logical_base_work[i] = '0;
        end

        case(front_ptr_reg)
            3'd0: begin
                logical_bucket_work[0] = bucket_reg[0];
                logical_bucket_work[1] = bucket_reg[5];
                logical_bucket_work[2] = bucket_reg[4];
                logical_bucket_work[3] = bucket_reg[3];
                logical_bucket_work[4] = bucket_reg[2];
                logical_bucket_work[5] = bucket_reg[1];
            end
            3'd1: begin
                logical_bucket_work[0] = bucket_reg[1];
                logical_bucket_work[1] = bucket_reg[0];
                logical_bucket_work[2] = bucket_reg[5];
                logical_bucket_work[3] = bucket_reg[4];
                logical_bucket_work[4] = bucket_reg[3];
                logical_bucket_work[5] = bucket_reg[2];
            end
            3'd2: begin
                logical_bucket_work[0] = bucket_reg[2];
                logical_bucket_work[1] = bucket_reg[1];
                logical_bucket_work[2] = bucket_reg[0];
                logical_bucket_work[3] = bucket_reg[5];
                logical_bucket_work[4] = bucket_reg[4];
                logical_bucket_work[5] = bucket_reg[3];
            end
            3'd3: begin
                logical_bucket_work[0] = bucket_reg[3];
                logical_bucket_work[1] = bucket_reg[2];
                logical_bucket_work[2] = bucket_reg[1];
                logical_bucket_work[3] = bucket_reg[0];
                logical_bucket_work[4] = bucket_reg[5];
                logical_bucket_work[5] = bucket_reg[4];
            end
            3'd4: begin
                logical_bucket_work[0] = bucket_reg[4];
                logical_bucket_work[1] = bucket_reg[3];
                logical_bucket_work[2] = bucket_reg[2];
                logical_bucket_work[3] = bucket_reg[1];
                logical_bucket_work[4] = bucket_reg[0];
                logical_bucket_work[5] = bucket_reg[5];
            end
            3'd5: begin
                logical_bucket_work[0] = bucket_reg[5];
                logical_bucket_work[1] = bucket_reg[4];
                logical_bucket_work[2] = bucket_reg[3];
                logical_bucket_work[3] = bucket_reg[2];
                logical_bucket_work[4] = bucket_reg[1];
                logical_bucket_work[5] = bucket_reg[0];
            end
            default: begin
                logical_bucket_work[0] = bucket_reg[0];
                logical_bucket_work[1] = bucket_reg[5];
                logical_bucket_work[2] = bucket_reg[4];
                logical_bucket_work[3] = bucket_reg[3];
                logical_bucket_work[4] = bucket_reg[2];
                logical_bucket_work[5] = bucket_reg[1];
            end
        endcase

        active_emax_work = emax_base_reg;
        active_front_ptr_work = front_ptr_reg;
        final_emax_work = emax_base_reg;
        final_front_ptr_work = front_ptr_reg;
        rotate_steps_work = '0;
        rotate_all_work = 1'b0;
        extra_top_work = 1'b0;
        top_input_carry_work = '0;
        top_bucket_carry_work = '0;
        top_input_digit_work = '0;
        top_input_digit_valid_work = 1'b0;
        tail_bucket_work = '0;
        tail_bucket_valid_work = 1'b0;
        drain_ptr_work = 0;
        drain_base_work = '0;

        for(int i = 0; i < `BG_BUCKET_COUNT; i++) begin
            for(int s = 0; s < CARRY_STATE_COUNT; s++) begin
                input_add_variant[i][s] = '0;
                input_norm_variant[i][s] = '0;
                input_norm_valid_variant[i][s] = 1'b0;
                input_norm_ext_variant[i][s] = '0;
                input_carry_variant[i][s] = '0;
                bucket_add_variant[i][s] = '0;
                bucket_norm_variant[i][s] = '0;
                bucket_norm_valid_variant[i][s] = 1'b0;
                bucket_norm_ext_variant[i][s] = '0;
                bucket_carry_variant[i][s] = '0;
                total_carry_variant[i][s] = '0;
                transition_l0[i][s] = CARRY_ZERO;
                transition_l1[i][s] = CARRY_ZERO;
                transition_l2[i][s] = CARRY_ZERO;
                transition_l3[i][s] = CARRY_ZERO;
            end
            carry_in_state_work[i] = CARRY_ZERO;
        end

        case(state_reg)
            S_ACC: begin
                o_ready = spill_slot_ready;

                if(i_valid && o_ready) begin
                    if(input_sum_work != 0) begin
                        if(!emax_valid_reg) begin
                            active_emax_work = input_top_base_work;
                            active_front_ptr_work = front_ptr_reg;
                            for(int i = 0; i < `BG_BUCKET_COUNT; i++) begin
                                rotated_bucket_work[i] = '0;
                            end
                        end
                        else if(input_top_base_work > emax_base_reg) begin
                            rotate_steps_work = (input_top_base_work-emax_base_reg)
                                              >>> `BG_BUCKET_SHIFT_W;
                            active_emax_work = input_top_base_work;

                            if(rotate_steps_work >= `BG_BUCKET_COUNT) begin
                                rotate_all_work = 1'b1;
                                active_front_ptr_work = '0;
                            end
                            else begin
                                case(rotate_steps_work[2:0])
                                    3'd1: active_front_ptr_work = PTR_INC(front_ptr_reg);
                                    3'd2: active_front_ptr_work = PTR_INC(PTR_INC(front_ptr_reg));
                                    3'd3: active_front_ptr_work = PTR_INC(PTR_INC(PTR_INC(front_ptr_reg)));
                                    3'd4: active_front_ptr_work = PTR_INC(PTR_INC(PTR_INC(PTR_INC(front_ptr_reg))));
                                    3'd5: active_front_ptr_work = PTR_INC(PTR_INC(PTR_INC(PTR_INC(PTR_INC(front_ptr_reg)))));
                                    default: active_front_ptr_work = front_ptr_reg;
                                endcase
                            end

                            if(!rotate_all_work) begin
                                for(int i = 0; i < `BG_BUCKET_COUNT; i++) begin
                                    for(int j = 0; j < `BG_BUCKET_COUNT; j++) begin
                                        if(i == j+rotate_steps_work)
                                            rotated_bucket_work[i] = logical_bucket_work[j];
                                    end
                                end
                            end
                        end
                        else begin
                            for(int i = 0; i < `BG_BUCKET_COUNT; i++) begin
                                rotated_bucket_work[i] = logical_bucket_work[i];
                            end
                        end

                        for(int i = 0; i < `BG_BUCKET_COUNT; i++) begin
                            logical_base_work[i] = active_emax_work
                                                 - i*`BG_EXP_PER_BUCKET;
                            for(int j = 0; j < `BG_WORK_DIGITS; j++) begin
                                if(logical_base_work[i] == input_digit_base_work[j])
                                    input_bucket_digit_work[i] = input_radix_digit_work[j];
                            end
                        end

                        for(int i = 0; i < `BG_BUCKET_COUNT; i++) begin
                            for(int s = 0; s < CARRY_STATE_COUNT; s++) begin
                                input_add_variant[i][s] = $signed({
                                    {2{input_bucket_digit_work[i][`BG_BUCKET_WIDTH-1]}},
                                    input_bucket_digit_work[i]
                                }) + $signed(s-2);
                                input_norm_variant[i][s] = input_add_variant[i][s][`BG_BUCKET_WIDTH-1:0];
                                input_norm_valid_variant[i][s] = |input_norm_variant[i][s];
                                input_norm_ext_variant[i][s] = {
                                    {2{input_norm_variant[i][s][`BG_BUCKET_WIDTH-1]}},
                                    input_norm_variant[i][s]
                                };
                                input_carry_variant[i][s] =
                                    (input_add_variant[i][s]-input_norm_ext_variant[i][s])
                                    >>> `BG_EXP_PER_BUCKET;

                                bucket_add_variant[i][s] = $signed({
                                    {2{rotated_bucket_work[i][`BG_BUCKET_WIDTH-1]}},
                                    rotated_bucket_work[i]
                                }) + $signed({
                                    {2{input_norm_variant[i][s][`BG_BUCKET_WIDTH-1]}},
                                    input_norm_variant[i][s]
                                });
                                bucket_norm_variant[i][s] =
                                    bucket_add_variant[i][s][`BG_BUCKET_WIDTH-1:0];
                                bucket_norm_valid_variant[i][s] =
                                    |bucket_norm_variant[i][s];
                                bucket_norm_ext_variant[i][s] = {
                                    {2{bucket_norm_variant[i][s][`BG_BUCKET_WIDTH-1]}},
                                    bucket_norm_variant[i][s]
                                };
                                bucket_carry_variant[i][s] =
                                    (bucket_add_variant[i][s]-bucket_norm_ext_variant[i][s])
                                    >>> `BG_EXP_PER_BUCKET;
                                total_carry_variant[i][s] = input_carry_variant[i][s]
                                                          + bucket_carry_variant[i][s];
                                transition_l0[i][s] = total_carry_variant[i][s]
                                                     + 4'sd2;
                            end
                        end

                        for(int i = 0; i < `BG_BUCKET_COUNT; i++) begin
                            for(int s = 0; s < CARRY_STATE_COUNT; s++) begin
                                if(i < `BG_BUCKET_COUNT-1)
                                    transition_l1[i][s] =
                                        transition_l0[i][transition_l0[i+1][s]];
                                else
                                    transition_l1[i][s] = transition_l0[i][s];
                            end
                        end

                        for(int i = 0; i < `BG_BUCKET_COUNT; i++) begin
                            for(int s = 0; s < CARRY_STATE_COUNT; s++) begin
                                if(i < `BG_BUCKET_COUNT-2)
                                    transition_l2[i][s] =
                                        transition_l1[i][transition_l1[i+2][s]];
                                else
                                    transition_l2[i][s] = transition_l1[i][s];
                            end
                        end

                        for(int i = 0; i < `BG_BUCKET_COUNT; i++) begin
                            for(int s = 0; s < CARRY_STATE_COUNT; s++) begin
                                if(i < `BG_BUCKET_COUNT-4)
                                    transition_l3[i][s] =
                                        transition_l2[i][transition_l2[i+4][s]];
                                else
                                    transition_l3[i][s] = transition_l2[i][s];
                            end
                        end

                        carry_in_state_work[`BG_BUCKET_COUNT-1] = CARRY_ZERO;
                        for(int i = 0; i < `BG_BUCKET_COUNT-1; i++) begin
                            carry_in_state_work[i] = transition_l3[i+1][CARRY_ZERO];
                        end

                        for(int i = 0; i < `BG_BUCKET_COUNT; i++) begin
                            updated_bucket_work[i] =
                                bucket_norm_variant[i][carry_in_state_work[i]];
                            updated_bucket_valid_work[i] =
                                bucket_norm_valid_variant[i][carry_in_state_work[i]];
                        end

                        top_input_carry_work =
                            input_carry_variant[0][carry_in_state_work[0]];
                        top_bucket_carry_work =
                            bucket_carry_variant[0][carry_in_state_work[0]];
                        top_input_digit_work =
                            input_norm_variant[0][carry_in_state_work[0]];
                        top_input_digit_valid_work =
                            input_norm_valid_variant[0][carry_in_state_work[0]];

                        if(top_bucket_carry_work != 0) begin
                            spill_push_valid = rotated_bucket_work[0] != 0;
                            spill_push_sign = rotated_bucket_work[0][`BG_BUCKET_WIDTH-1];
                            spill_push_mag = BUCKET_MAG(rotated_bucket_work[0]);
                            spill_push_exp = active_emax_work;
                            updated_bucket_work[0] = top_input_digit_work;
                            updated_bucket_valid_work[0] = top_input_digit_valid_work;
                        end

                        extra_top_work = top_input_carry_work != 0;
                        tail_bucket_work = updated_bucket_work[`BG_BUCKET_COUNT-1];
                        tail_bucket_valid_work =
                            updated_bucket_valid_work[`BG_BUCKET_COUNT-1];
                        if(extra_top_work) begin
                            tail_bucket_work = {
                                {(`BG_BUCKET_WIDTH-3){top_input_carry_work[2]}},
                                top_input_carry_work
                            };
                            tail_bucket_valid_work = 1'b1;
                            final_emax_work = active_emax_work + `BG_EXP_PER_BUCKET;
                            final_front_ptr_work = PTR_INC(active_front_ptr_work);
                        end
                        else begin
                            final_emax_work = active_emax_work;
                            final_front_ptr_work = active_front_ptr_work;
                        end

                        for(int i = 0; i < `BG_BUCKET_COUNT; i++) begin
                            bucket_next[i] = '0;
                            bucket_valid_next[i] = 1'b0;
                        end

                        case(active_front_ptr_work)
                            3'd0: begin
                                bucket_next[0] = updated_bucket_work[0];
                                bucket_next[1] = tail_bucket_work;
                                bucket_next[2] = updated_bucket_work[4];
                                bucket_next[3] = updated_bucket_work[3];
                                bucket_next[4] = updated_bucket_work[2];
                                bucket_next[5] = updated_bucket_work[1];
                                bucket_valid_next[0] = updated_bucket_valid_work[0];
                                bucket_valid_next[1] = tail_bucket_valid_work;
                                bucket_valid_next[2] = updated_bucket_valid_work[4];
                                bucket_valid_next[3] = updated_bucket_valid_work[3];
                                bucket_valid_next[4] = updated_bucket_valid_work[2];
                                bucket_valid_next[5] = updated_bucket_valid_work[1];
                            end
                            3'd1: begin
                                bucket_next[0] = updated_bucket_work[1];
                                bucket_next[1] = updated_bucket_work[0];
                                bucket_next[2] = tail_bucket_work;
                                bucket_next[3] = updated_bucket_work[4];
                                bucket_next[4] = updated_bucket_work[3];
                                bucket_next[5] = updated_bucket_work[2];
                                bucket_valid_next[0] = updated_bucket_valid_work[1];
                                bucket_valid_next[1] = updated_bucket_valid_work[0];
                                bucket_valid_next[2] = tail_bucket_valid_work;
                                bucket_valid_next[3] = updated_bucket_valid_work[4];
                                bucket_valid_next[4] = updated_bucket_valid_work[3];
                                bucket_valid_next[5] = updated_bucket_valid_work[2];
                            end
                            3'd2: begin
                                bucket_next[0] = updated_bucket_work[2];
                                bucket_next[1] = updated_bucket_work[1];
                                bucket_next[2] = updated_bucket_work[0];
                                bucket_next[3] = tail_bucket_work;
                                bucket_next[4] = updated_bucket_work[4];
                                bucket_next[5] = updated_bucket_work[3];
                                bucket_valid_next[0] = updated_bucket_valid_work[2];
                                bucket_valid_next[1] = updated_bucket_valid_work[1];
                                bucket_valid_next[2] = updated_bucket_valid_work[0];
                                bucket_valid_next[3] = tail_bucket_valid_work;
                                bucket_valid_next[4] = updated_bucket_valid_work[4];
                                bucket_valid_next[5] = updated_bucket_valid_work[3];
                            end
                            3'd3: begin
                                bucket_next[0] = updated_bucket_work[3];
                                bucket_next[1] = updated_bucket_work[2];
                                bucket_next[2] = updated_bucket_work[1];
                                bucket_next[3] = updated_bucket_work[0];
                                bucket_next[4] = tail_bucket_work;
                                bucket_next[5] = updated_bucket_work[4];
                                bucket_valid_next[0] = updated_bucket_valid_work[3];
                                bucket_valid_next[1] = updated_bucket_valid_work[2];
                                bucket_valid_next[2] = updated_bucket_valid_work[1];
                                bucket_valid_next[3] = updated_bucket_valid_work[0];
                                bucket_valid_next[4] = tail_bucket_valid_work;
                                bucket_valid_next[5] = updated_bucket_valid_work[4];
                            end
                            3'd4: begin
                                bucket_next[0] = updated_bucket_work[4];
                                bucket_next[1] = updated_bucket_work[3];
                                bucket_next[2] = updated_bucket_work[2];
                                bucket_next[3] = updated_bucket_work[1];
                                bucket_next[4] = updated_bucket_work[0];
                                bucket_next[5] = tail_bucket_work;
                                bucket_valid_next[0] = updated_bucket_valid_work[4];
                                bucket_valid_next[1] = updated_bucket_valid_work[3];
                                bucket_valid_next[2] = updated_bucket_valid_work[2];
                                bucket_valid_next[3] = updated_bucket_valid_work[1];
                                bucket_valid_next[4] = updated_bucket_valid_work[0];
                                bucket_valid_next[5] = tail_bucket_valid_work;
                            end
                            3'd5: begin
                                bucket_next[0] = tail_bucket_work;
                                bucket_next[1] = updated_bucket_work[4];
                                bucket_next[2] = updated_bucket_work[3];
                                bucket_next[3] = updated_bucket_work[2];
                                bucket_next[4] = updated_bucket_work[1];
                                bucket_next[5] = updated_bucket_work[0];
                                bucket_valid_next[0] = tail_bucket_valid_work;
                                bucket_valid_next[1] = updated_bucket_valid_work[4];
                                bucket_valid_next[2] = updated_bucket_valid_work[3];
                                bucket_valid_next[3] = updated_bucket_valid_work[2];
                                bucket_valid_next[4] = updated_bucket_valid_work[1];
                                bucket_valid_next[5] = updated_bucket_valid_work[0];
                            end
                            default: begin
                                bucket_next[0] = updated_bucket_work[0];
                                bucket_next[1] = tail_bucket_work;
                                bucket_next[2] = updated_bucket_work[4];
                                bucket_next[3] = updated_bucket_work[3];
                                bucket_next[4] = updated_bucket_work[2];
                                bucket_next[5] = updated_bucket_work[1];
                                bucket_valid_next[0] = updated_bucket_valid_work[0];
                                bucket_valid_next[1] = tail_bucket_valid_work;
                                bucket_valid_next[2] = updated_bucket_valid_work[4];
                                bucket_valid_next[3] = updated_bucket_valid_work[3];
                                bucket_valid_next[4] = updated_bucket_valid_work[2];
                                bucket_valid_next[5] = updated_bucket_valid_work[1];
                            end
                        endcase

                        emax_valid_next = 1'b1;
                        emax_base_next = final_emax_work;
                        front_ptr_next = final_front_ptr_work;
                    end

                    if(i_last) begin
                        drain_offset_next = '0;
                        state_next = S_DRAIN;
                    end
                end
            end

            S_DRAIN: begin
                drain_ptr_work = PTR_SUB(front_ptr_reg, drain_offset_reg);
                drain_base_work = emax_base_reg
                                - drain_offset_reg*`BG_EXP_PER_BUCKET;
                spill_push_valid = bucket_valid_reg[drain_ptr_work];
                spill_push_sign = bucket_reg[drain_ptr_work][`BG_BUCKET_WIDTH-1];
                spill_push_mag = BUCKET_MAG(bucket_reg[drain_ptr_work]);
                spill_push_exp = drain_base_work;

                if(!bucket_valid_reg[drain_ptr_work] || spill_slot_ready) begin
                    bucket_next[drain_ptr_work] = '0;
                    bucket_valid_next[drain_ptr_work] = 1'b0;

                    if(drain_offset_reg == `BG_BUCKET_COUNT-1) begin
                        state_next = S_WAIT;
                    end
                    else begin
                        drain_offset_next = drain_offset_reg + 1'b1;
                    end
                end
            end

            S_WAIT: begin
                if(!spill_valid_reg || i_spill_ready) begin
                    o_done = 1'b1;
                    state_next = S_DONE;
                end
            end

            S_DONE: begin
                o_done = 1'b0;
            end

            default: begin
                state_next = S_ACC;
            end
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin : p_bucket_registers
        if(!rst_n) begin
            state_reg <= S_ACC;
            bucket_valid_reg <= '0;
            emax_valid_reg <= 1'b0;
            emax_base_reg <= '0;
            front_ptr_reg <= '0;
            drain_offset_reg <= '0;
            spill_valid_reg <= 1'b0;
            spill_sign_reg <= 1'b0;
            spill_mag_reg <= '0;
            spill_exp_reg <= '0;
            for(int i = 0; i < `BG_BUCKET_COUNT; i++) begin
                bucket_reg[i] <= '0;
            end
        end
        else if(i_start) begin
            state_reg <= S_ACC;
            bucket_valid_reg <= '0;
            emax_valid_reg <= 1'b0;
            emax_base_reg <= '0;
            front_ptr_reg <= '0;
            drain_offset_reg <= '0;
            spill_valid_reg <= 1'b0;
            spill_sign_reg <= 1'b0;
            spill_mag_reg <= '0;
            spill_exp_reg <= '0;
            for(int i = 0; i < `BG_BUCKET_COUNT; i++) begin
                bucket_reg[i] <= '0;
            end
        end
        else begin
            state_reg <= state_next;
            bucket_valid_reg <= bucket_valid_next;
            emax_valid_reg <= emax_valid_next;
            emax_base_reg <= emax_base_next;
            front_ptr_reg <= front_ptr_next;
            drain_offset_reg <= drain_offset_next;
            if(spill_slot_ready) begin
                spill_valid_reg <= spill_push_valid;
                if(spill_push_valid) begin
                    spill_sign_reg <= spill_push_sign;
                    spill_mag_reg <= spill_push_mag;
                    spill_exp_reg <= spill_push_exp;
                end
            end
            for(int i = 0; i < `BG_BUCKET_COUNT; i++) begin
                bucket_reg[i] <= bucket_next[i];
            end
        end
    end

endmodule
