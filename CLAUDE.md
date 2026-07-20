# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Read First

`docs/Process.md` is the single source of truth for research status, numerical contracts,
result tables, and the phased roadmap. Read it before starting any task, and update it whenever
a numerical contract, RTL parameter, experiment status, or result interpretation changes.
`docs/non-overlap-ppl-evaluation.md` documents why the PPL protocol is non-overlapping.

## What This Project Is

Research on **Dynamic Exponent-Window Accumulation (DEWA)** for Block Floating Point (BFP)
LLM inference. Two halves that must stay numerically reconciled:

- **Software (Python/Jupyter/Triton)**: fake-quantized BFP Linear layers, WikiText-2 PPL, DEWA
  threshold sweeps, partial-sum exponent profiling.
- **Hardware (SystemVerilog)**: a weight-stationary BFP processing element under `rtl/BFP-PE/`,
  currently the baseline (no DEWA logic) used as the area/timing/energy reference.

The central claim under construction: DEWA replaces most FP-Acc activity with a fixed-width
INT-Acc at acceptable PPL cost, evaluated as a Pareto trade-off over **T x INT_ACC_BITS**.

## Critical Naming Gotcha

`ob-skip` / `ob_skip` / `obskip` are the **legacy name of DEWA**. They appear in directory
names, notebook filenames, result JSON filenames, and JSON field names (e.g. `ob_skip_rate`,
`ob_skip_config`). The plotting scripts parse those exact paths and field names via regex
(`plot_ob_skip.py:OB_SKIP_PATTERN`). **Do not rename them.** Use "DEWA" in prose and new code,
keep the legacy identifiers in existing data paths.

## Software Side

### Layout

- `model/<MODEL>/baseline.ipynb` — FP16 baseline PPL. `model/<MODEL>/bfp.ipynb` — sweeps
  BFP8→BFP4 in one execution. Models: LLaMA2-7B, LLaMA2-13B, LLaMA3.1-8B, OPT-6.7B.
- `ob-skip/LLaMA2-7B/ob_skip.ipynb` — DEWA functional model, fused Triton Group-32 kernel,
  sweeps T = 8..12 in one execution.
- `ob-skip/LLaMA2-7B/profile_exponent.ipynb` — per-layer Group-32 partial-sum exponent histograms.
- Results are JSON under each `result/` dir; `result/overlap/` holds **obsolete** overlapping-window
  results kept for reference only — never compare them against current numbers.

### Notebook conventions

Notebooks are self-contained: frozen dataclass configs (`BFPConfig`, `OBSkipConfig`,
`TritonKernelConfig`) with `validate()`, monkey-patched `nn.Linear` replacement
(`replace_linear_layers`), per-layer stat counters, then a JSON dump that records the full
config plus environment versions (gpu/cuda/python/pytorch/transformers/datasets). Any new
experiment should follow the same shape — the result JSON must be self-describing because
the plotting scripts and `docs/Process.md` tables read them directly.

### Evaluation protocol (fixed — do not change silently)

`Salesforce/wikitext` / `wikitext-2-raw-v1` / test split, context 2048, stride 2048,
`non_overlapping_2048_drop_remainder`, FP16 weights, `use_cache=False`. Current results are
**prefill-like teacher-forced** evaluation; they say nothing about decode.

### Plotting

Scripts read the committed JSON and never rerun inference. Run from anywhere; defaults resolve
relative to the script location.

```bash
python plot/plot_ppl.py                # -> plot/output/ppl_delta_plot.png
python plot/plot_ob_skip.py            # -> plot/output/ob_skip_dual_axis_plot.png
python plot/plot_exponent_profile.py   # -> plot/output/exponent_profile/*.png (8 figures)
```

All accept `--output-dir`; `plot_ob_skip.py` accepts `--group-size/--threshold-min/--threshold-max`,
`plot_exponent_profile.py` accepts `--group-size/--formats`. Output is IEEE-style 600-DPI PNG.

## Hardware Side (`rtl/BFP-PE/`)

### Module hierarchy

```
BFP_PE.sv      weight-stationary top: preload latches one packed weight block + clears acc;
               every non-preload cycle accumulates one activation block. No valid/ready.
 ├─ INT_MAC.sv per-lane sign XOR + unsigned mantissa multiply -> signed adder-tree reduction
 └─ FP_ACC.sv  Group-N integer dot product -> FP16, accumulated in one FP16 register
BFP_PKG.sv     LOD (leading-one detect), fixed-point->FP16 NORM, custom FP16_ADD
include.svh    all format/width macros; everything else is derived from GSIZE/MAN_W/EXP_W
```

Current config is **G16 / E5 / M3**, whereas the software main experiment is **G32 / E5 / M7
(BFP8)**. This mismatch is unresolved — never compare G16/M3 RTL against G32/BFP8 PPL.

The comments in `include.svh` (96-bit mantissa bus, 32-bit sign bus, 12/11-bit sum/mag) are
**stale**; at G16/M3 the macros elaborate to 48-bit mantissa, 16-bit sign, 11-bit sum, 10-bit mag.

### Pattern generation

`00_TESTBED/gen_pattern.py` is a **bit-exact Python re-implementation of INT_MAC + BFP_PKG**
(truncation, flush-to-zero, saturation included). It proves RTL↔model internal consistency,
**not** equivalence to the PyTorch fake-BFP definition. Its `GSIZE/MAN_W/EXP_W` constants must
be edited to match `include.svh` by hand.

It writes `input.dat`/`golden.dat` into the **current working directory**, so run it from
`00_TESTBED/`. Those two files in `00_TESTBED/` are the canonical patterns.

### Flow (server-side EDA: VCS, Design Compiler, TSMC 90nm)

Each `NN_run` is a one-liner into `00_TESTBED/makefile`; the relative paths in the `file.f`
lists assume you are in the corresponding directory.

```bash
cd rtl/BFP-PE/00_TESTBED && python gen_pattern.py   # regenerate stimulus + golden
cd rtl/BFP-PE/01_RTL     && ./01_run                # behavioral VCS   (make vcs_rtl)
cd rtl/BFP-PE/02_SYN     && ./02_run                # DC synthesis     (make syn -> syn90.tcl)
cd rtl/BFP-PE/03_GATE    && ./03_run                # gate-level VCS   (make vcs_gate, +define+GATE)
```

`02_SYN/syn90.tcl` (TSMC 90nm, `CYCLE = 10` ns) is the active script; `syn16.tcl` targets the
N16ADFP flow and is not the current baseline. Synthesis writes `Netlist/`, `Report/`, `Work/`,
which `03_GATE/file.f` then consumes.

**Simulation/synthesis artifacts live on the server, not in this repo.** Logs, area reports,
netlists, and SDF are intentionally not mirrored locally. Their absence is not evidence the flow
is unverified — behavioral, synthesis, and gate flows are user-confirmed passing.

`create_run` recreates the empty directory/file skeleton on a fresh machine (structure only).

### RTL conventions

- Banner comment block at the top of every `.sv` (Copyright / File Name / Project / Module / Author).
- Section separators: `// ---...---` blocks naming each datapath stage.
- Single-space formatting — do **not** column-align port lists, declarations, or assignments.
- `always_ff @(posedge clk or negedge rst_n)` with active-low async reset; `logic` throughout.
- All widths come from `include.svh` macros, never hardcoded literals.
- Simulation is VCS + Verdi (FSDB waveforms). Do not generate ModelSim `run.do` files.

## Working Rules

1. Do not add DEWA logic to the RTL until the baseline BFP-PE format, accumulator semantics,
   and synthesis reference are frozen. Then implement DEWA as a **separate module/config** and
   preserve the baseline as an immutable comparator with identical library/corner/constraints.
2. PPL depends only on **T**, not on **INT_ACC_BITS** (the INT-Acc fallback is exact). Never
   re-run the expensive GPU PPL sweep per INT_ACC_BITS; derive the whole grid from one
   instrumented pass per T.
3. Always report rates with raw numerators and denominators.
4. Markdown docs use plain ASCII/Unicode math, not LaTeX.
