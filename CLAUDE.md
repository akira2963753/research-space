# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Read First

**`research1/docs/Process.md` is the single source of truth** for research status, numerical
contracts, RTL parameters, result tables, and the phased roadmap. Read it before starting any
task, and update it whenever any of those change.

This file deliberately contains **no research content and no numbers** — only how to operate the
repo. If you are about to state a numerical contract, an experiment status, or a result here, it
belongs in `research1/docs/Process.md` instead.

`research1/docs/non-overlap-ppl-evaluation.md` explains why the PPL protocol is non-overlapping
and why overlapping-window numbers must never be compared against current results.

The root `README.md` is a short orientation page only. When it and `Process.md` disagree,
`Process.md` §2 wins — and fix the README.

## Naming Gotcha

`ob-skip` / `ob_skip` / `obskip` and the directory names `04_DEW` / `05_DEW_Outlier_Profile` are
the **legacy names of DEWA** (Dynamic Exponent-Window Accumulation). They appear in notebook
filenames, result JSON filenames, and JSON field names (e.g. `ob_skip_rate`, `ob_skip_config`).
Plot scripts and result discovery parse those exact paths and field names. **Do not rename them.**
Use "DEWA" in prose and new code, keep the legacy identifiers in existing data paths.

Likewise, `T` is the **exponent-difference threshold**, never the INT accumulator bit width
(`INT_ACC_BITS`). Filenames like `...-t9-...` mean T = 9.

## Layout

Everything active lives under `research1/`:

- `experiments/NN_<Stage>/<model>/` — one self-contained Colab notebook plus the result JSON it
  produced, kept together. Stages run 01_Baseline → 09_Hybrid; later stages build on earlier
  contracts, so read the stage table in `Process.md` before adding one.
- `plot/NN_<topic>/plot_*.py` + `figures/g16|g32/` — paper-facing plotting scripts and output.
- `rtl/01_Baseline-BFP-PE/` — baseline BFP processing element, testbench, synthesis, gate flow.
- `architecture/` — editable drawio + exported PNG of the Top-2 / DEWA / FP-ACC datapath.
- `docs/` — the two documents above.

## Commands

### Python interpreter

Use an **absolute path to a real interpreter**:

```
C:/Users/harry/AppData/Local/Programs/Python/Python313/python.exe
```

Do not use `python3` (Microsoft Store App Execution Alias — a reparse point that fails under a
sandboxed agent's filesystem policy) and do not provision one with `uv`. If Python is unavailable
and a task depended on running it, **say so explicitly** rather than reporting the task verified.
`.../Python310/python.exe` also exists as a fallback.

### Plotting

Scripts read the committed JSON and never rerun inference. They resolve inputs relative to the
script's own location (`Path(__file__).parents[2]` → `research1/`), so the working directory does
not matter. All accept `--output-dir`; output is IEEE-style PNG written to
`plot/<topic>/figures/g<G>/` by default.

```bash
python research1/plot/01_exponent-profile/plot_exponent_profile.py   # --group-size {16,32} (default 32), --formats, --profile-dir
python research1/plot/02_outlier-profile/plot_outlier_profile.py     # --group-size {16,32} (default 16), --input, --include-lm-head
python research1/plot/03_ppl-comparison/plot_ppl_comparison.py       # --group-size (default 16), --experiments-dir
```

`plot_ppl_comparison.py` intentionally warns that the LM Head scope is inconsistent across
methods — that warning is a known open item (Process.md §7.2, Priority 1), not a bug to silence.

### Experiment notebooks

Notebooks are **Colab-first and GPU-required**; they are not runnable on this machine. Each one:
pins `%pip install "transformers==5.13.1" "datasets==4.0.0"`, reads `HF_TOKEN` from env /
`google.colab.userdata` / prompt, defines frozen dataclass configs with `validate()`, replaces
decoder `nn.Linear` modules with a fake-quantizing module (later stages use a fused Triton
kernel), asserts expected block/token/layer/value counts, then dumps a self-describing JSON plus
environment versions and zips results for download.

Any new experiment must follow the same shape — the result JSON is read directly by the plotting
scripts and by the tables in `Process.md`, so it must carry its own full config and raw
numerator/denominator counts.

### RTL flow (server-side EDA: VCS, Design Compiler)

Each `NN_run` is a one-liner into `00_TESTBED/makefile`. The relative paths in the `file.f` lists
assume you are in the corresponding directory, so **the working directory matters**:

```bash
cd research1/rtl/01_Baseline-BFP-PE/00_TESTBED && python gen_pattern.py   # regenerate stimulus + golden
cd ../01_RTL && ./01_run                                                 # behavioral VCS  (make vcs_rtl)
cd ../02_SYN && ./02_run                                                 # synthesis       (make syn)
cd ../03_GATE && ./03_run                                                # gate-level VCS  (make vcs_gate, +define+GATE)
```

`gen_pattern.py` writes `input.dat`/`golden.dat` into the **current working directory**, so it
must be run from `00_TESTBED/`. Those two files there are the canonical patterns. Its
`GSIZE/MAN_W/EXP_W/FPACC_*` constants must be edited to match `01_RTL/include.svh` **by hand** —
it is a bit-exact Python mirror of `INT_MAC` + `BFP_PKG` (LOD/NORM/FP_ADD, truncation,
flush-to-zero, saturation), so the two drift silently if you change only one side.

`create_run` recreates the empty directory/file skeleton on a fresh machine (structure only).

**VCS, Design Compiler, N16ADFP libraries, and the gate-level model exist only on the server.**
Do not invoke them locally. Simulation and synthesis artifacts are not mirrored into this repo;
their absence is not evidence that a flow is unverified — check `Process.md` §11.4 for which
flows are currently valid.

## Conventions

### RTL

- Banner comment block at the top of every `.sv` (Copyright / File Name / Project / Module / Author).
- Section separators: `// ---...---` blocks naming each datapath stage.
- Single-space formatting — do **not** column-align port lists, declarations, or assignments.
- `always_ff @(posedge clk or negedge rst_n)` with active-low async reset; `logic` throughout.
- All widths come from `include.svh` macros, never hardcoded literals. Note that several width
  comments in `include.svh` are stale G16 text while the macros elaborate from `BFP_GSIZE=32`.
- Simulation is VCS + Verdi (FSDB waveforms). Do not generate ModelSim `run.do` files.

### Docs

Plain ASCII/Unicode math, not LaTeX. `Process.md` is English; the PPL protocol note is 繁體中文.

## Working Rules

1. Do not add DEWA logic to the RTL until the baseline BFP-PE is frozen (see `Process.md` §13
   Priority 2/5 for what "frozen" currently requires). Then implement DEWA as a **separate
   module/config** and preserve the baseline as an immutable comparator with identical library,
   corner, and constraints.
2. Never re-run the expensive GPU PPL sweep per `INT_ACC_BITS` — under exact FP32 fallback, PPL
   depends only on T. Derive the grid from one instrumented pass per T and validate the
   assumption with a single end-to-end run.
3. Always report rates with raw numerators and denominators, in the JSON and in prose.
4. Distinguish measured results from functional estimates. The FP-ACC request-count reduction is
   an optimistic upper bound (unbounded FP32 normal path, no fixed-width overflow fallback) and
   must never be stated as measured power, energy, area, or speedup.
5. When a change invalidates previously recorded results (RTL numerics, evaluation protocol,
   quantization scope), mark the affected entries in `Process.md` as stale rather than deleting
   them.
