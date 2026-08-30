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

    //=============================================================
    //                  Block Floating Point Format
    //=============================================================
    `define BFP_GSIZE 16
    `define BFP_EXP_W 5
    `define BFP_MAN_W 3
    `define BFP_MAN_BW (`BFP_GSIZE * `BFP_MAN_W)
    `define BFP_SIGN_BW `BFP_GSIZE
    `define OI_W $clog2(`BFP_GSIZE)

    //=============================================================
    //                   Integer MAC Data Widths
    //=============================================================
    `define BFP_PROD_W (2 * `BFP_MAN_W)
    `define BFP_SPROD_W (`BFP_PROD_W + 1)
    `define BFP_SPROD_BW (`BFP_GSIZE * `BFP_SPROD_W)
    `define BFP_SUM_W (`BFP_SPROD_W + $clog2(`BFP_GSIZE))
    `define BFP_MAG_W (`BFP_SUM_W - 1)
    `define BFP_LOD_W $clog2(`BFP_MAG_W)
    `define BFP_EXP_BIAS 15
    `define BFP_BEXP_W 8

    //=============================================================
    //                    FP Accumulator Format
    //=============================================================
    `define FPACC_EXP_W 8
    `define FPACC_MAN_W 23
    `define FPACC_EXP_BIAS 127
    `define FPACC_W (1 + `FPACC_EXP_W + `FPACC_MAN_W)
    `define FPACC_LOD_W $clog2(`FPACC_MAN_W + 1)
    `define FPACC_CALC_EXP_W (`FPACC_EXP_W + 2)

`endif
