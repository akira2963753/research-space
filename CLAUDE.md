# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Read First

**`docs/Process.md` is the single source of truth** for research status, numerical contracts,
RTL parameters, result tables, and the phased roadmap. Read it before starting any task, and
update it whenever any of those change.

This file deliberately contains **no research content and no numbers** — only how to operate the
repo. If you find yourself about to state a numerical contract, an experiment status, or a
result here, it belongs in `docs/Process.md` instead. Do not duplicate it.

`docs/non-overlap-ppl-evaluation.md` documents why the PPL protocol is non-overlapping.

## Critical Naming Gotcha

`ob-skip` / `ob_skip` / `obskip` are the **legacy name of DEWA**. They appear in directory names,
notebook filenames, result JSON filenames, and JSON field names (e.g. `ob_skip_rate`,
`ob_skip_config`). The plotting scripts parse those exact paths and field names via regex
(`plot_ob_skip.py:OB_SKIP_PATTERN`). **Do not rename them.** Use "DEWA" in prose and new code,
keep the legacy identifiers in existing data paths.

## Repo Layout

- `model/<MODEL>/` — per-model baseline and BFP notebooks, results under `result/`.
- `ob-skip/LLaMA2-7B/` — DEWA functional notebook and exponent profiler.
- `plot/` — plotting scripts; figures under `plot/output/`.
- `rtl/BFP-PE/` — baseline BFP processing element, testbench, synthesis, gate-level flow.
- `result/overlap/` subdirectories hold **obsolete** overlapping-window results, kept for
  reference only — never compare them against current numbers.

## Commands

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

### RTL flow (server-side EDA: VCS, Design Compiler)

Each `NN_run` is a one-liner into `00_TESTBED/makefile`. The relative paths in the `file.f` lists
assume you are in the corresponding directory, so **the working directory matters**:

```bash
cd rtl/BFP-PE/00_TESTBED && python gen_pattern.py   # regenerate stimulus + golden
cd rtl/BFP-PE/01_RTL     && ./01_run                # behavioral VCS   (make vcs_rtl)
cd rtl/BFP-PE/02_SYN     && ./02_run                # synthesis        (make syn)
cd rtl/BFP-PE/03_GATE    && ./03_run                # gate-level VCS   (make vcs_gate, +define+GATE)
```

`gen_pattern.py` writes `input.dat`/`golden.dat` into the **current working directory**, so it
must be run from `00_TESTBED/`. Those two files in `00_TESTBED/` are the canonical patterns.
Its `GSIZE/MAN_W/EXP_W` constants must be edited to match `include.svh` **by hand** — it is a
bit-exact Python mirror of the RTL, so the two drift silently if you change only one.

`create_run` recreates the empty directory/file skeleton on a fresh machine (structure only).

**Simulation/synthesis artifacts live on the server, not in this repo.** Logs, area reports,
netlists and SDF are intentionally not mirrored locally. Their absence is not evidence that a
flow is unverified — check `docs/Process.md` for which flows are currently valid.

## Conventions

### RTL

- Banner comment block at the top of every `.sv` (Copyright / File Name / Project / Module / Author).
- Section separators: `// ---...---` blocks naming each datapath stage.
- Single-space formatting — do **not** column-align port lists, declarations, or assignments.
- `always_ff @(posedge clk or negedge rst_n)` with active-low async reset; `logic` throughout.
- All widths come from `include.svh` macros, never hardcoded literals.
- Simulation is VCS + Verdi (FSDB waveforms). Do not generate ModelSim `run.do` files.

### Notebooks

Self-contained: frozen dataclass configs with `validate()`, monkey-patched `nn.Linear`
replacement (`replace_linear_layers`), per-layer stat counters, then a JSON dump recording the
full config plus environment versions. Any new experiment should follow the same shape — the
result JSON must be self-describing, because the plotting scripts and the tables in
`docs/Process.md` read it directly.

### Docs

Plain ASCII/Unicode math, not LaTeX.

## Working Rules

1. Do not add DEWA logic to the RTL until the baseline BFP-PE is frozen (see `docs/Process.md`
   for what "frozen" currently requires). Then implement DEWA as a **separate module/config**
   and preserve the baseline as an immutable comparator with identical library, corner, and
   constraints.
2. Never re-run the expensive GPU PPL sweep per `INT_ACC_BITS` — see the "PPL depends only on T"
   argument in `docs/Process.md` and derive the grid from one instrumented pass per T.
3. Always report rates with raw numerators and denominators.
4. When a change invalidates previously recorded results (RTL numerics, evaluation protocol),
   mark the affected entries in `docs/Process.md` as stale rather than deleting them.
