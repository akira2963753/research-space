/******************************************************************************
* Copyright (C) 2026 Marco
*
* File Name:    include.vh
* Project:      Bucket Getter BFP Processing Element
* Module:       Global data-format and datapath-width definitions
* Author:       Marco <harry2963753@gmail.com>
*
******************************************************************************/
`ifndef __BG_INCLUDE_VH__
    `define __BG_INCLUDE_VH__

    // -----------------------------------------------------------------------
    // Common G16/BFP4 Input Format
    // -----------------------------------------------------------------------
    `define BFP_GSIZE 16
    `define BFP_EXP_W 5
    `define BFP_MAN_W 3
    `define BFP_EXP_BIAS 15
    `define BFP_SIGN_BW `BFP_GSIZE
    `define BFP_MAN_BW (`BFP_GSIZE * `BFP_MAN_W)

    // -----------------------------------------------------------------------
    // Common Integer-MAC Widths
    // -----------------------------------------------------------------------
    `define BFP_PROD_W (2 * `BFP_MAN_W)
    `define BFP_SPROD_W (`BFP_PROD_W + 1)
    `define BFP_SUM_W (`BFP_SPROD_W + $clog2(`BFP_GSIZE))
    `define BFP_MAG_W (`BFP_SUM_W - 1)
    `define BFP_LOD_W $clog2(`BFP_MAG_W)
    `define BFP_BEXP_W 8

    // -----------------------------------------------------------------------
    // Common FP32 Accumulator Format
    // -----------------------------------------------------------------------
    `define FPACC_EXP_W 8
    `define FPACC_MAN_W 23
    `define FPACC_EXP_BIAS 127
    `define FPACC_W (1 + `FPACC_EXP_W + `FPACC_MAN_W)
    `define FPACC_LOD_W $clog2(`FPACC_MAN_W + 1)
    `define FPACC_CALC_EXP_W (`BFP_BEXP_W + 2)

    //=============================================================
    //       Top-6 Adaptive Circular Bucket Configuration
    //=============================================================
    `define BG_BUCKET_COUNT 6
    `define BG_BUCKET_WIDTH 4
    `define BG_LOGICAL_BUCKET_WIDTH `BG_BUCKET_WIDTH
    `define BG_EXP_PER_BUCKET `BG_BUCKET_WIDTH
    `define BG_BUCKET_PTR_W $clog2(`BG_BUCKET_COUNT)
    `define BG_BUCKET_SHIFT_W $clog2(`BG_EXP_PER_BUCKET)
    `define BG_FIFO_DEPTH 2
    `define BG_FIFO_PTR_W $clog2(`BG_FIFO_DEPTH)
    `define BG_FIFO_COUNT_W $clog2(`BG_FIFO_DEPTH + 1)
    `define BG_WORK_W (`BFP_SUM_W + `BG_EXP_PER_BUCKET + 2)
    `define BG_UPDATE_W (`BG_WORK_W + 1)
    `define BG_WORK_DIGITS ((`BG_WORK_W + `BG_EXP_PER_BUCKET - 1) / `BG_EXP_PER_BUCKET + 1)

`endif
