/******************************************************************************
* Copyright (C) 2026 Marco
*
* File Name:    include.vh
* Project:      Dynamic Exponent Window Accumulation Based PE
* Module:       Global data-format / datapath-width definitions
* Author:       Marco <harry2963753@gmail.com>
*
******************************************************************************/
`ifndef __DEW_INCLUDE_VH__
    `define __DEW_INCLUDE_VH__

    // ---------------------------------------------------------------------------
    // Block Floating Point Data Format
    // ---------------------------------------------------------------------------
    `define BFP_GSIZE 16
    `define BFP_EXP_W 5
    `define BFP_MAN_W 3
    `define BFP_MAN_BW (`BFP_GSIZE * `BFP_MAN_W) // 48-bit packed mantissa bus
    `define BFP_SIGN_BW `BFP_GSIZE // 16-bit packed sign bus
    `define OI_W $clog2(`BFP_GSIZE)





    // ---------------------------------------------------------------------------
    // Derived Integer-MAC datapath widths
    // ---------------------------------------------------------------------------
    `define BFP_PROD_W (2 * `BFP_MAN_W) // 6 lane magnitude product
    `define BFP_SPROD_W (`BFP_PROD_W + 1) // 7 signed lane product
    `define BFP_SUM_W (`BFP_SPROD_W + $clog2(`BFP_GSIZE)) // 11-bit signed adder-tree sum
    `define BFP_MAG_W (`BFP_SUM_W - 1) // 10-bit unsigned |sum|
    `define BFP_LOD_W $clog2(`BFP_MAG_W) // 4-bit LOD_MAG result

    // Product block exponent = w_exp + a_exp - BFP_EXP_BIAS (biased by 15).
    // Signed, range -15..47 -> 8 bits is comfortably enough.
    `define BFP_EXP_BIAS 15
    `define BFP_BEXP_W 8

    // ---------------------------------------------------------------------------
    // FP Accumulator Data Format (FP accumulator / output)
    // ---------------------------------------------------------------------------
    `define FPACC_EXP_W 8
    `define FPACC_MAN_W 23
    `define FPACC_EXP_BIAS 127
    `define FPACC_W (1 + `FPACC_EXP_W + `FPACC_MAN_W) // 32-bit accumulator word
    `define FPACC_LOD_W $clog2(`FPACC_MAN_W + 1) // 5-bit LOD_SIG result
    `define FPACC_CALC_EXP_W (`FPACC_EXP_W + 2) // 10-bit signed NORM exponent, range 97..168

`endif // __BFP_INCLUDE_VH__
