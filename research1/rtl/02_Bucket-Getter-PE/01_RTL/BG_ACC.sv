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
    output logic done,
    output logic busy,
    output logic profile_fifo_full,
    output logic profile_bucket_update,
    output logic profile_carry_event,
    output logic profile_carry_hop,
    output logic profile_multi_hop,
    output logic profile_fp_flush,
    output logic profile_oob_drop,
    output logic [2:0] profile_carry_depth
);

    import BG_PKG::*;

    typedef enum logic [1:0] {
        S_ACC,
        S_DRAIN,
        S_WAIT,
        S_DONE
    } state_t;

    state_t state_reg;
    state_t state_next;

    //=============================================================
    //                    Circular Bucket Bank
    //=============================================================
    logic signed [`BG_BUCKET_WIDTH-1:0] bucket_reg [0:`BG_BUCKET_COUNT-1];
    logic signed [`BG_BUCKET_WIDTH-1:0] bucket_next [0:`BG_BUCKET_COUNT-1];
    logic [`BG_BUCKET_COUNT-1:0] bucket_valid_reg;
    logic [`BG_BUCKET_COUNT-1:0] bucket_valid_next;
    logic [`BG_BUCKET_COUNT-1:0] active_valid_work;

    logic emax_valid_reg;
    logic emax_valid_next;
    logic signed [`BFP_BEXP_W-1:0] emax_base_reg;
    logic signed [`BFP_BEXP_W-1:0] emax_base_next;
    logic [`BG_BUCKET_PTR_W-1:0] front_ptr_reg;
    logic [`BG_BUCKET_PTR_W-1:0] front_ptr_next;

    //=============================================================
    //                       Psum FIFO Depth 2
    //=============================================================
    logic signed [`BG_WORK_W-1:0] fifo_data_reg [0:`BG_FIFO_DEPTH-1];
    logic signed [`BG_WORK_W-1:0] fifo_data_next [0:`BG_FIFO_DEPTH-1];
    logic signed [`BFP_BEXP_W-1:0] fifo_base_reg [0:`BG_FIFO_DEPTH-1];
    logic signed [`BFP_BEXP_W-1:0] fifo_base_next [0:`BG_FIFO_DEPTH-1];
    logic signed [`BFP_BEXP_W-1:0] fifo_top_base_reg [0:`BG_FIFO_DEPTH-1];
    logic signed [`BFP_BEXP_W-1:0] fifo_top_base_next [0:`BG_FIFO_DEPTH-1];
    logic fifo_last_reg [0:`BG_FIFO_DEPTH-1];
    logic fifo_last_next [0:`BG_FIFO_DEPTH-1];
    logic [`BG_FIFO_PTR_W-1:0] fifo_rd_ptr_reg;
    logic [`BG_FIFO_PTR_W-1:0] fifo_rd_ptr_next;
    logic [`BG_FIFO_PTR_W-1:0] fifo_wr_ptr_reg;
    logic [`BG_FIFO_PTR_W-1:0] fifo_wr_ptr_next;
    logic [`BG_FIFO_COUNT_W-1:0] fifo_count_reg;
    logic [`BG_FIFO_COUNT_W-1:0] fifo_count_next;
    logic last_queued_reg;
    logic last_queued_next;
    logic drain_pending_reg;
    logic drain_pending_next;

    //=============================================================
    //                       FP Spill Slot
    //=============================================================
    logic spill_valid_reg;
    logic spill_sign_reg;
    logic [`BFP_MAG_W-1:0] spill_mag_reg;
    logic signed [`BFP_BEXP_W-1:0] spill_exp_reg;
    logic spill_slot_ready;
    logic spill_push_valid;
    logic spill_push_sign;
    logic [`BFP_MAG_W-1:0] spill_push_mag;
    logic signed [`BFP_BEXP_W-1:0] spill_push_exp;

    //=============================================================
    //                    Input Mapping Stage
    //=============================================================
    logic signed [`BFP_SUM_W-1:0] input_sum_work;
    logic signed [`BFP_BEXP_W-1:0] input_base_work;
    logic [`BG_BUCKET_SHIFT_W-1:0] input_shift_work;
    logic signed [`BG_WORK_W-1:0] input_aligned_work;
    logic quant_found_work;
    logic [`BFP_MAG_W-1:0] quant_mag_candidate_work;
    logic signed [`BFP_BEXP_W-1:0] quant_exp_candidate_work;
    logic [`BG_BUCKET_SHIFT_W-1:0] quant_offset_candidate_work;
    logic [`BFP_MAG_W+`BG_EXP_PER_BUCKET-1:0]
        quant_aligned_candidate_work;
    logic [`BFP_MAG_W-1:0] input_quant_mag_work;
    logic signed [`BFP_BEXP_W-1:0] input_quant_exp_work;
    logic [`BG_BUCKET_SHIFT_W-1:0] input_quant_offset_work;
    logic [`BG_LOGICAL_BUCKET_WIDTH-1:0] input_quant_aligned_mag_work;
    integer input_quant_shift_work;
    integer input_top_offset_work;
    logic signed [`BFP_BEXP_W-1:0] input_top_base_work;

    //=============================================================
    //                    Scheduler and Update
    //=============================================================
    logic fifo_push_work;
    logic fifo_pop_work;
    logic service_valid_work;
    logic service_last_work;
    logic signed [`BG_WORK_W-1:0] service_data_work;
    logic signed [`BFP_BEXP_W-1:0] service_base_work;
    logic signed [`BFP_BEXP_W-1:0] service_top_base_work;

    logic signed [`BFP_BEXP_W-1:0] active_emax_work;
    logic signed [`BFP_BEXP_W-1:0] active_rear_base_work;
    logic [`BG_BUCKET_PTR_W-1:0] active_front_ptr_work;
    integer advance_steps_work;
    integer skip_digits_work;

    logic selected_in_bound_work;
    logic selected_is_max_work;
    logic [`BG_BUCKET_PTR_W-1:0] selected_offset_work;
    logic [`BG_BUCKET_PTR_W-1:0] selected_ptr_work;
    logic signed [`BFP_BEXP_W-1:0] selected_base_work;
    logic signed [`BG_WORK_W-1:0] selected_data_work;
    logic signed [`BG_BUCKET_WIDTH-1:0] selected_bucket_work;
    logic signed [`BG_UPDATE_W-1:0] selected_sum_work;
    logic signed [`BG_BUCKET_WIDTH-1:0] selected_result_work;
    logic signed [`BG_UPDATE_W-1:0] selected_result_ext_work;
    logic signed [`BG_UPDATE_W-1:0] selected_carry_work;
    logic [`BG_UPDATE_W-1:0] selected_mag_work;

    //=============================================================
    //                 Parallel Carry/Borrow Prefix
    //=============================================================
    logic [`BG_BUCKET_COUNT-2:0] chain_full_work;
    logic [`BG_BUCKET_COUNT-2:0] chain_empty_work;
    logic [`BG_BUCKET_COUNT-2:0] chain_carry_in_work;
    logic [`BG_BUCKET_COUNT-2:0] chain_zero_work;
    logic [`BG_BUCKET_COUNT-2:0] chain_fill_work;
    logic [`BG_BUCKET_COUNT-2:0] chain_inc_work;
    logic [`BG_BUCKET_COUNT-2:0] chain_dec_work;
    logic [`BG_BUCKET_PTR_W-1:0] chain_ptr_work [0:`BG_BUCKET_COUNT-2];
    logic carry_positive_work;
    logic carry_negative_work;
    logic carry_reaches_top_work;
    logic [2:0] carry_depth_work;
    logic prefix_supported_work;
    logic signed [`BG_UPDATE_W-1:0] prefix_spill_value_work;

    logic [`BG_BUCKET_PTR_W-1:0] drain_offset_reg;
    logic [`BG_BUCKET_PTR_W-1:0] drain_offset_next;
    logic [`BG_BUCKET_PTR_W-1:0] drain_ptr_work;
    logic signed [`BFP_BEXP_W-1:0] drain_base_work;

    always_comb begin : p_next_state
        state_next = state_reg;
        bucket_valid_next = bucket_valid_reg;
        emax_valid_next = emax_valid_reg;
        emax_base_next = emax_base_reg;
        front_ptr_next = front_ptr_reg;
        fifo_rd_ptr_next = fifo_rd_ptr_reg;
        fifo_wr_ptr_next = fifo_wr_ptr_reg;
        fifo_count_next = fifo_count_reg;
        last_queued_next = last_queued_reg;
        drain_pending_next = drain_pending_reg;
        drain_offset_next = drain_offset_reg;

        for(int i = 0; i < `BG_BUCKET_COUNT; i++) begin
            bucket_next[i] = bucket_reg[i];
            active_valid_work[i] = bucket_valid_reg[i];
        end
        for(int i = 0; i < `BG_FIFO_DEPTH; i++) begin
            fifo_data_next[i] = fifo_data_reg[i];
            fifo_base_next[i] = fifo_base_reg[i];
            fifo_top_base_next[i] = fifo_top_base_reg[i];
            fifo_last_next[i] = fifo_last_reg[i];
        end

        spill_valid = spill_valid_reg;
        spill_sign = spill_sign_reg;
        spill_mag = spill_mag_reg;
        spill_exp = spill_exp_reg;
        done = 1'b0;
        busy = state_reg != S_ACC
             || fifo_count_reg != 0
             || drain_pending_reg;

        spill_slot_ready = !spill_valid_reg || spill_ready;
        spill_push_valid = 1'b0;
        spill_push_sign = 1'b0;
        spill_push_mag = '0;
        spill_push_exp = '0;

        profile_fifo_full = fifo_count_reg == `BG_FIFO_DEPTH;
        profile_bucket_update = 1'b0;
        profile_carry_event = 1'b0;
        profile_carry_hop = 1'b0;
        profile_multi_hop = 1'b0;
        profile_fp_flush = 1'b0;
        profile_oob_drop = 1'b0;
        profile_carry_depth = '0;

        quant_found_work = dp_mag == 0;
        quant_mag_candidate_work = '0;
        quant_exp_candidate_work = blk_exp;
        quant_offset_candidate_work = '0;
        quant_aligned_candidate_work = '0;
        input_quant_mag_work = '0;
        input_quant_exp_work = blk_exp;
        input_quant_offset_work = '0;
        input_quant_aligned_mag_work = '0;
        input_quant_shift_work = 0;

        for(int i = 0; i < `BFP_MAG_W; i++) begin
            quant_mag_candidate_work = dp_mag >> i;
            quant_exp_candidate_work = blk_exp + i;
            quant_offset_candidate_work = quant_exp_candidate_work[
                `BG_BUCKET_SHIFT_W-1:0
            ];
            quant_aligned_candidate_work = quant_mag_candidate_work
                                           << quant_offset_candidate_work;
            if(!quant_found_work
               && quant_mag_candidate_work != 0
               && quant_aligned_candidate_work
               <= {`BG_LOGICAL_BUCKET_WIDTH{1'b1}}) begin
                quant_found_work = 1'b1;
                input_quant_mag_work = quant_mag_candidate_work;
                input_quant_exp_work = quant_exp_candidate_work;
                input_quant_offset_work = quant_offset_candidate_work;
                input_quant_aligned_mag_work =
                    quant_aligned_candidate_work[
                        `BG_LOGICAL_BUCKET_WIDTH-1:0
                    ];
                input_quant_shift_work = i;
            end
        end

        input_sum_work = $signed({1'b0, input_quant_aligned_mag_work});
        if(dp_sign) input_sum_work = -input_sum_work;
        input_base_work = EXP_BASE(input_quant_exp_work);
        input_shift_work = input_quant_offset_work;
        input_aligned_work = {
            {(`BG_WORK_W-`BFP_SUM_W){input_sum_work[`BFP_SUM_W-1]}},
            input_sum_work
        };
        input_top_offset_work = WORK_TOP_OFFSET(input_aligned_work);
        input_top_base_work = input_base_work
                            + input_top_offset_work*`BG_EXP_PER_BUCKET;

        fifo_pop_work = state_reg == S_ACC
                      && spill_slot_ready
                      && fifo_count_reg != 0;
        in_ready = state_reg == S_ACC
                && !last_queued_reg
                && (fifo_count_reg < `BG_FIFO_DEPTH || fifo_pop_work);
        fifo_push_work = in_valid && in_ready;

        if(fifo_push_work) begin
            fifo_data_next[fifo_wr_ptr_reg] = input_aligned_work;
            fifo_base_next[fifo_wr_ptr_reg] = input_base_work;
            fifo_top_base_next[fifo_wr_ptr_reg] = input_top_base_work;
            fifo_last_next[fifo_wr_ptr_reg] = in_last;
            fifo_wr_ptr_next = fifo_wr_ptr_reg + 1'b1;
            if(in_last)
                last_queued_next = 1'b1;
        end

        if(fifo_pop_work)
            fifo_rd_ptr_next = fifo_rd_ptr_reg + 1'b1;

        case({fifo_push_work, fifo_pop_work})
            2'b10: fifo_count_next = fifo_count_reg + 1'b1;
            2'b01: fifo_count_next = fifo_count_reg - 1'b1;
            default: fifo_count_next = fifo_count_reg;
        endcase

        service_valid_work = 1'b0;
        service_last_work = 1'b0;
        service_data_work = '0;
        service_base_work = '0;
        service_top_base_work = '0;

        if(state_reg == S_ACC && spill_slot_ready) begin
            if(fifo_count_reg != 0) begin
                service_valid_work = 1'b1;
                service_data_work = fifo_data_reg[fifo_rd_ptr_reg];
                service_base_work = fifo_base_reg[fifo_rd_ptr_reg];
                service_top_base_work = fifo_top_base_reg[fifo_rd_ptr_reg];
                service_last_work = fifo_last_reg[fifo_rd_ptr_reg];
            end
        end

        active_emax_work = emax_base_reg;
        active_rear_base_work = emax_base_reg
                              - (`BG_BUCKET_COUNT-1)*`BG_EXP_PER_BUCKET;
        active_front_ptr_work = front_ptr_reg;
        advance_steps_work = 0;
        skip_digits_work = 0;

        selected_in_bound_work = 1'b0;
        selected_is_max_work = 1'b0;
        selected_offset_work = '0;
        selected_ptr_work = '0;
        selected_base_work = service_base_work;
        selected_data_work = service_data_work;
        selected_bucket_work = '0;
        selected_sum_work = '0;
        selected_result_work = '0;
        selected_result_ext_work = '0;
        selected_carry_work = '0;
        selected_mag_work = '0;
        chain_full_work = '0;
        chain_empty_work = '0;
        chain_carry_in_work = '0;
        chain_zero_work = '0;
        chain_fill_work = '0;
        chain_inc_work = '0;
        chain_dec_work = '0;
        carry_positive_work = 1'b0;
        carry_negative_work = 1'b0;
        carry_reaches_top_work = 1'b0;
        carry_depth_work = '0;
        prefix_supported_work = 1'b0;
        prefix_spill_value_work = '0;
        for(int i = 0; i < `BG_BUCKET_COUNT-1; i++)
            chain_ptr_work[i] = '0;

        drain_ptr_work = '0;
        drain_base_work = '0;

        case(state_reg)
            S_ACC: begin
                if(service_valid_work) begin
                    if(service_data_work != 0) begin
                        if(!emax_valid_reg) begin
                            active_emax_work = service_top_base_work;
                            active_front_ptr_work = front_ptr_reg;
                            active_valid_work = '0;
                        end
                        else if(service_top_base_work > emax_base_reg) begin
                            advance_steps_work =
                                (service_top_base_work-emax_base_reg)
                                >>> `BG_BUCKET_SHIFT_W;
                            active_emax_work = service_top_base_work;

                            if(advance_steps_work >= `BG_BUCKET_COUNT) begin
                                active_valid_work = '0;
                            end
                            else begin
                                active_front_ptr_work = PTR_ADD(
                                    front_ptr_reg,
                                    advance_steps_work
                                );
                                for(int i = 0; i < `BG_BUCKET_COUNT; i++) begin
                                    if(i < advance_steps_work)
                                        active_valid_work[
                                            PTR_SUB(active_front_ptr_work, i)
                                        ] = 1'b0;
                                end
                            end
                        end

                        active_rear_base_work = active_emax_work
                                              - (`BG_BUCKET_COUNT-1)
                                              * `BG_EXP_PER_BUCKET;
                        selected_in_bound_work = service_top_base_work
                                               >= active_rear_base_work;

                        if(selected_in_bound_work
                           && service_base_work < active_rear_base_work) begin
                            skip_digits_work =
                                (active_rear_base_work-service_base_work)
                                >>> `BG_BUCKET_SHIFT_W;
                            selected_base_work = active_rear_base_work;
                            selected_data_work = service_data_work
                                               >>> (skip_digits_work
                                               * `BG_EXP_PER_BUCKET);
                        end

                        emax_valid_next = 1'b1;
                        emax_base_next = active_emax_work;
                        front_ptr_next = active_front_ptr_work;
                        bucket_valid_next = active_valid_work;
                    end

                    if(service_data_work != 0 && !selected_in_bound_work)
                        profile_oob_drop = 1'b1;

                    if(selected_in_bound_work && selected_data_work != 0) begin
                        selected_offset_work =
                            (active_emax_work-selected_base_work)
                            >>> `BG_BUCKET_SHIFT_W;
                        selected_ptr_work = PTR_SUB(
                            active_front_ptr_work,
                            selected_offset_work
                        );
                        selected_is_max_work = selected_offset_work == 0;

                        if(active_valid_work[selected_ptr_work])
                            selected_bucket_work = bucket_reg[selected_ptr_work];
                        else
                            selected_bucket_work = '0;

                        selected_sum_work = $signed({
                            {(`BG_UPDATE_W-`BG_BUCKET_WIDTH){
                                selected_bucket_work[`BG_BUCKET_WIDTH-1]
                            }},
                            selected_bucket_work
                        }) + $signed({
                            {(`BG_UPDATE_W-`BG_WORK_W){
                                selected_data_work[`BG_WORK_W-1]
                            }},
                            selected_data_work
                        });
                        selected_result_work =
                            selected_sum_work[`BG_BUCKET_WIDTH-1:0];
                        selected_result_ext_work = {
                            {(`BG_UPDATE_W-`BG_BUCKET_WIDTH){
                                selected_result_work[`BG_BUCKET_WIDTH-1]
                            }},
                            selected_result_work
                        };
                        selected_carry_work =
                            (selected_sum_work-selected_result_ext_work)
                            >>> `BG_EXP_PER_BUCKET;

                        bucket_next[selected_ptr_work] = selected_result_work;
                        bucket_valid_next[selected_ptr_work] =
                            |selected_result_work;
                        profile_bucket_update = 1'b1;

                        if(selected_carry_work != 0) begin
                            if(selected_is_max_work) begin
                                selected_mag_work = selected_sum_work[
                                    `BG_UPDATE_W-1
                                ] ? -selected_sum_work : selected_sum_work;
                                spill_push_valid = 1'b1;
                                spill_push_sign = selected_sum_work[
                                    `BG_UPDATE_W-1
                                ];
                                spill_push_mag = selected_mag_work[
                                    `BFP_MAG_W-1:0
                                ];
                                spill_push_exp = selected_base_work;
                                bucket_next[selected_ptr_work] = '0;
                                bucket_valid_next[selected_ptr_work] = 1'b0;
                                profile_fp_flush = 1'b1;
                            end
                            else begin
                                carry_positive_work = selected_carry_work == 1;
                                carry_negative_work = selected_carry_work == -1;
                                prefix_supported_work = carry_positive_work
                                                      || carry_negative_work;
                                profile_carry_event = prefix_supported_work;

                                for(int i = 0; i < `BG_BUCKET_COUNT-1; i++) begin
                                    chain_ptr_work[i] = PTR_ADD(
                                        selected_ptr_work,
                                        i+1
                                    );
                                    if(i < selected_offset_work) begin
                                        chain_full_work[i] =
                                            active_valid_work[chain_ptr_work[i]]
                                            && bucket_reg[chain_ptr_work[i]]
                                            == $signed({1'b0, {
                                                (`BG_BUCKET_WIDTH-1){1'b1}
                                            }});
                                        chain_empty_work[i] =
                                            active_valid_work[chain_ptr_work[i]]
                                            && bucket_reg[chain_ptr_work[i]]
                                            == $signed({1'b1, {
                                                (`BG_BUCKET_WIDTH-1){1'b0}
                                            }});
                                        chain_carry_in_work[i] = 1'b1;
                                        for(int j = 0; j < `BG_BUCKET_COUNT-1; j++) begin
                                            if(j < i) begin
                                                if(carry_positive_work)
                                                    chain_carry_in_work[i] =
                                                        chain_carry_in_work[i]
                                                        && chain_full_work[j];
                                                else if(carry_negative_work)
                                                    chain_carry_in_work[i] =
                                                        chain_carry_in_work[i]
                                                        && chain_empty_work[j];
                                                else
                                                    chain_carry_in_work[i] = 1'b0;
                                            end
                                        end

                                        chain_zero_work[i] = carry_positive_work
                                                           && chain_carry_in_work[i]
                                                           && chain_full_work[i];
                                        chain_fill_work[i] = carry_negative_work
                                                           && chain_carry_in_work[i]
                                                           && chain_empty_work[i];
                                        chain_inc_work[i] = carry_positive_work
                                                          && chain_carry_in_work[i]
                                                          && !chain_full_work[i];
                                        chain_dec_work[i] = carry_negative_work
                                                          && chain_carry_in_work[i]
                                                          && !chain_empty_work[i];

                                        if(chain_carry_in_work[i])
                                            carry_depth_work = i+1;
                                        if(chain_zero_work[i]) begin
                                            bucket_next[chain_ptr_work[i]] = {
                                                1'b1,
                                                {(`BG_BUCKET_WIDTH-1){1'b0}}
                                            };
                                            bucket_valid_next[chain_ptr_work[i]] = 1'b1;
                                        end
                                        else if(chain_fill_work[i]) begin
                                            bucket_next[chain_ptr_work[i]] = {
                                                1'b0,
                                                {(`BG_BUCKET_WIDTH-1){1'b1}}
                                            };
                                            bucket_valid_next[chain_ptr_work[i]] = 1'b1;
                                        end
                                        else if(chain_inc_work[i]) begin
                                            bucket_next[chain_ptr_work[i]] =
                                                (active_valid_work[chain_ptr_work[i]])?
                                                    bucket_reg[chain_ptr_work[i]] + 1'b1 :
                                                    {{(`BG_BUCKET_WIDTH-1){1'b0}}, 1'b1};
                                            bucket_valid_next[chain_ptr_work[i]] = 1'b1;
                                        end
                                        else if(chain_dec_work[i]) begin
                                            bucket_next[chain_ptr_work[i]] =
                                                (active_valid_work[chain_ptr_work[i]])?
                                                    bucket_reg[chain_ptr_work[i]] - 1'b1 :
                                                    {`BG_BUCKET_WIDTH{1'b1}};
                                            bucket_valid_next[chain_ptr_work[i]] = 1'b1;
                                        end

                                        if(i == selected_offset_work-1) begin
                                            carry_reaches_top_work =
                                                (carry_positive_work
                                                 && chain_carry_in_work[i]
                                                 && chain_full_work[i])
                                                || (carry_negative_work
                                                 && chain_carry_in_work[i]
                                                 && chain_empty_work[i]);
                                        end
                                    end
                                end

                                profile_carry_hop = prefix_supported_work;
                                profile_carry_depth = carry_depth_work;
                                profile_multi_hop = carry_depth_work > 1;

                                if(carry_reaches_top_work) begin
                                    spill_push_valid = 1'b1;
                                    spill_push_sign = carry_negative_work;
                                    spill_push_mag = {{(`BFP_MAG_W-1){1'b0}}, 1'b1};
                                    spill_push_exp = active_emax_work
                                                   + `BG_EXP_PER_BUCKET;
                                    profile_fp_flush = 1'b1;
                                end
                                else if(!prefix_supported_work) begin
                                    prefix_spill_value_work = selected_sum_work;
                                    selected_mag_work = prefix_spill_value_work[
                                        `BG_UPDATE_W-1
                                    ] ? -prefix_spill_value_work
                                      : prefix_spill_value_work;
                                    spill_push_valid = 1'b1;
                                    spill_push_sign = prefix_spill_value_work[
                                        `BG_UPDATE_W-1
                                    ];
                                    spill_push_mag = selected_mag_work[
                                        `BFP_MAG_W-1:0
                                    ];
                                    spill_push_exp = selected_base_work;
                                    bucket_next[selected_ptr_work] = '0;
                                    bucket_valid_next[selected_ptr_work] = 1'b0;
                                    profile_fp_flush = 1'b1;
                                end
                            end
                        end
                    end

                    if(service_last_work)
                        drain_pending_next = 1'b1;
                end

                if(drain_pending_next
                   && fifo_count_next == 0) begin
                    drain_offset_next = '0;
                    state_next = S_DRAIN;
                end
            end

            S_DRAIN: begin
                drain_ptr_work = PTR_SUB(front_ptr_reg, drain_offset_reg);
                drain_base_work = emax_base_reg
                                - drain_offset_reg*`BG_EXP_PER_BUCKET;
                spill_push_valid = bucket_valid_reg[drain_ptr_work];
                spill_push_sign = bucket_reg[drain_ptr_work][
                    `BG_BUCKET_WIDTH-1
                ];
                spill_push_mag = BUCKET_MAG(bucket_reg[drain_ptr_work]);
                spill_push_exp = drain_base_work;

                if(!bucket_valid_reg[drain_ptr_work] || spill_slot_ready) begin
                    bucket_valid_next[drain_ptr_work] = 1'b0;
                    if(drain_offset_reg == `BG_BUCKET_COUNT-1)
                        state_next = S_WAIT;
                    else
                        drain_offset_next = drain_offset_reg + 1'b1;
                end
            end

            S_WAIT: begin
                if(!spill_valid_reg || spill_ready) begin
                    done = 1'b1;
                    state_next = S_DONE;
                end
            end

            S_DONE: begin
                done = 1'b0;
            end

            default: begin
                state_next = S_ACC;
            end
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin : p_registers
        if(!rst_n) begin
            state_reg <= S_ACC;
            bucket_valid_reg <= '0;
            emax_valid_reg <= 1'b0;
            emax_base_reg <= '0;
            front_ptr_reg <= '0;
            fifo_rd_ptr_reg <= '0;
            fifo_wr_ptr_reg <= '0;
            fifo_count_reg <= '0;
            last_queued_reg <= 1'b0;
            drain_pending_reg <= 1'b0;
            drain_offset_reg <= '0;
            spill_valid_reg <= 1'b0;
            spill_sign_reg <= 1'b0;
            spill_mag_reg <= '0;
            spill_exp_reg <= '0;
            for(int i = 0; i < `BG_BUCKET_COUNT; i++) begin
                bucket_reg[i] <= '0;
            end
            for(int i = 0; i < `BG_FIFO_DEPTH; i++) begin
                fifo_data_reg[i] <= '0;
                fifo_base_reg[i] <= '0;
                fifo_top_base_reg[i] <= '0;
                fifo_last_reg[i] <= 1'b0;
            end
        end
        else if(acc_clear) begin
            state_reg <= S_ACC;
            bucket_valid_reg <= '0;
            emax_valid_reg <= 1'b0;
            emax_base_reg <= '0;
            front_ptr_reg <= '0;
            fifo_rd_ptr_reg <= '0;
            fifo_wr_ptr_reg <= '0;
            fifo_count_reg <= '0;
            last_queued_reg <= 1'b0;
            drain_pending_reg <= 1'b0;
            drain_offset_reg <= '0;
            spill_valid_reg <= 1'b0;
            spill_sign_reg <= 1'b0;
            spill_mag_reg <= '0;
            spill_exp_reg <= '0;
            for(int i = 0; i < `BG_BUCKET_COUNT; i++) begin
                bucket_reg[i] <= '0;
            end
            for(int i = 0; i < `BG_FIFO_DEPTH; i++) begin
                fifo_data_reg[i] <= '0;
                fifo_base_reg[i] <= '0;
                fifo_top_base_reg[i] <= '0;
                fifo_last_reg[i] <= 1'b0;
            end
        end
        else begin
            state_reg <= state_next;
            bucket_valid_reg <= bucket_valid_next;
            emax_valid_reg <= emax_valid_next;
            emax_base_reg <= emax_base_next;
            front_ptr_reg <= front_ptr_next;
            fifo_rd_ptr_reg <= fifo_rd_ptr_next;
            fifo_wr_ptr_reg <= fifo_wr_ptr_next;
            fifo_count_reg <= fifo_count_next;
            last_queued_reg <= last_queued_next;
            drain_pending_reg <= drain_pending_next;
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
            for(int i = 0; i < `BG_FIFO_DEPTH; i++) begin
                fifo_data_reg[i] <= fifo_data_next[i];
                fifo_base_reg[i] <= fifo_base_next[i];
                fifo_top_base_reg[i] <= fifo_top_base_next[i];
                fifo_last_reg[i] <= fifo_last_next[i];
            end
        end
    end

endmodule
