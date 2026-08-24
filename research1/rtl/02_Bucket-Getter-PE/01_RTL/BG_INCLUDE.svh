/******************************************************************************
* Copyright (C) 2026 Marco
*
* File Name:    BG_INCLUDE.svh
* Project:      Bucket Getter BFP Processing Element
* Module:       Global data-format and datapath-width definitions
* Author:       Marco <harry2963753@gmail.com>
*
******************************************************************************/
`ifndef __BG_INCLUDE_SVH__
    `define __BG_INCLUDE_SVH__

    // -----------------------------------------------------------------------
    // Paper preset: MSFP-11 (1 sign, 2 mantissa, 8 shared exponent), G16
    // -----------------------------------------------------------------------
    `ifndef BG_GSIZE
        `define BG_GSIZE 16
    `endif
    `ifndef BG_EXP_W
        `define BG_EXP_W 8
    `endif
    `ifndef BG_MAN_W
        `define BG_MAN_W 2
    `endif
    `ifndef BG_EXP_BIAS
        `define BG_EXP_BIAS 127
    `endif
    `define BG_SIGN_BW `BG_GSIZE
    `define BG_MAN_BW (`BG_GSIZE * `BG_MAN_W)

    // -----------------------------------------------------------------------
    // Integer MAC widths
    // -----------------------------------------------------------------------
    `define BG_PROD_W (2 * `BG_MAN_W)
    `define BG_SPROD_W (`BG_PROD_W + 1)
    `define BG_SUM_W (`BG_SPROD_W + $clog2(`BG_GSIZE))
    `define BG_MAG_W (`BG_SUM_W - 1)
    `define BG_BEXP_W (`BG_EXP_W + 2)

    // -----------------------------------------------------------------------
    // Adaptive circular bucket configuration
    // -----------------------------------------------------------------------
    `ifndef BG_BUCKET_COUNT
        `define BG_BUCKET_COUNT 4
    `endif
    `ifndef BG_BUCKET_WIDTH
        `define BG_BUCKET_WIDTH 128
    `endif
    `ifndef BG_EXP_PER_BUCKET
        `define BG_EXP_PER_BUCKET 4
    `endif
    `define BG_BUCKET_PTR_W $clog2(`BG_BUCKET_COUNT)
    `define BG_BUCKET_SHIFT_W $clog2(`BG_EXP_PER_BUCKET)

    // -----------------------------------------------------------------------
    // FP32 reconstruction format
    // -----------------------------------------------------------------------
    `ifndef BG_FP_EXP_W
        `define BG_FP_EXP_W 8
    `endif
    `ifndef BG_FP_MAN_W
        `define BG_FP_MAN_W 23
    `endif
    `ifndef BG_FP_EXP_BIAS
        `define BG_FP_EXP_BIAS 127
    `endif
    `define BG_FP_W (1 + `BG_FP_EXP_W + `BG_FP_MAN_W)
    `define BG_FP_SIG_W (`BG_FP_MAN_W + 1)
    `define BG_FP_LOD_W $clog2(`BG_FP_MAN_W + 1)
    `define BG_FP_CALC_EXP_W (`BG_BEXP_W + 2)

`endif
