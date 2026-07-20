# Research Process

Last updated: 2026-07-20

## Project Layout

- `model/`: baseline and BFP notebooks/results for each language model.
- `ob-skip/`: DEWA functional notebooks and profiling results; directory name is legacy.
- `plot/`: plotting scripts and generated figures under `plot/output/`.
- `docs/`: research process and evaluation-protocol notes.
- `rtl/BFP-PE/`: baseline BFP processing-element RTL, testbench, synthesis, and gate-level flow.

## Research Goal

Evaluate hardware-friendly Block Floating Point (BFP) inference and Dynamic Exponent-Window
Accumulation (**DEWA**, previously called OB-Skip) on language models. The software experiments
currently establish numerical behavior and WikiText-2 perplexity (PPL). Baseline BFP-PE RTL is
now in progress; DEWA RTL, fixed-width overflow activity, area, power, and cycle-level results
are not complete.

## Handoff Snapshot

| Work item | Status | Handoff note |
|---|---|---|
| Four-model FP16 baseline | Complete | LLaMA-2-7B/13B, LLaMA-3.1-8B, and OPT-6.7B |
| Four-model fake BFP8-BFP4 sweep | Complete | G = 32, shared E5, non-overlapping WikiText-2 protocol |
| LLaMA-2-7B DEWA T sweep | Complete | Legacy notebook/result names still use `ob_skip` / `obskip` |
| Partial-sum exponent profiling | Complete | BFP8-BFP4 JSON and eight local PNG figures |
| Baseline BFP-PE RTL | **In progress; RTL flow passes** | Current active task; VCS/synthesis artifacts are on the server |
| Fixed-width INT-Acc overflow model | Not implemented | Required before claiming FP-Acc activation reduction |
| DEWA RTL PE | Not implemented | Start only after the baseline BFP-PE numerical contract is frozen |
| Baseline simulation/synthesis/gate flow | **Pass (user-confirmed)** | Logs, area reports, netlist/SDF, and related artifacts remain on the server, not in this local workspace |

## Method Terminology

- Formal working name: **Dynamic Exponent-Window Accumulation (DEWA)**.
- Legacy directories, notebooks, JSON fields, and plotting scripts retain `ob-skip`, `ob_skip`,
  and `obskip`. Do not rename them casually because plotting and result parsing depend on the
  existing paths and field names.
- At accumulation step `t`, define `delta = E_new - E_acc(t)`. The normal window is
  `-T < delta < T`, or `[E_acc(t)-T+1, E_acc(t)+T-1]` for integer exponents.
- `delta <= -T`: discard New. `delta >= T`: discard the previous accumulator and replace it
  with New. Otherwise, align and accumulate.
- T fixes the window width at `2T-1` exponent levels. **The width is fixed during one run; the
  window position moves online with the running accumulator exponent.**
- `E_acc(t)` is the exponent of the current numeric accumulator, not the historical maximum
  exponent. Cancellation can reduce it.
- WinAcc uses AutoWin with weight/activation data to select tensor/layer WinFloat width and bias,
  then uses a runtime-stationary absolute exponent window. DEWA instead uses an online,
  accumulator-relative moving window and does not require offline window profiling.
- Future outlier handling is not yet designed. Keep DEWA as the core mechanism; use a temporary
  variant label such as `DEWA-OS` only after the outlier definition, detector, data path, and
  numerical behavior are specified.

## Immediate Handoff Checklist

1. Continue the **baseline BFP-PE** first. Do not add DEWA until the baseline format,
   accumulator semantics, behavioral simulation, and synthesis reference are frozen.
2. Treat `rtl/BFP-PE/00_TESTBED/input.dat` and `golden.dat` as the canonical pattern files.
   The duplicate `.dat` files directly under `rtl/BFP-PE/` may have been generated from a
   different working directory/configuration and are not read by the current testbench.
3. `gen_pattern.py` writes into the current working directory. Until it is changed to use its
   own script directory, run it from `rtl/BFP-PE/00_TESTBED/` and confirm its G/M/E constants
   match `01_RTL/include.svh`.
4. Run `01_run`, `02_run`, and `03_run` from `01_RTL/`, `02_SYN/`, and `03_GATE/` respectively;
   their relative paths assume those working directories. VCS, Design Compiler, the TSMC 90-nm
   libraries, and the Verilog library model are required in the EDA environment.
5. The user has confirmed that behavioral VCS, synthesis/area, and gate-related checks pass on
   the server. Their logs/reports are intentionally not mirrored locally; absence from this
   workspace must not be interpreted as an unverified flow. Use the server artifacts as the
   source of truth and record final configuration/metric summaries here when they are frozen.
6. After the baseline passes, preserve it as an immutable comparator and implement DEWA as a
   separate module/configuration. Compare both using identical numeric and synthesis settings.
7. Preserve the existing non-overlapping evaluation protocol and legacy result JSON filenames/
   fields. The plotting scripts parse them directly.
8. Update this document whenever a numerical contract, RTL parameter, experiment status, or
   result interpretation changes. In Markdown, prefer plain ASCII/Unicode math over LaTeX.

## Common Evaluation Protocol

- Dataset: `Salesforce/wikitext`, `wikitext-2-raw-v1`, test split.
- Context length: **2048 tokens**.
- Stride: **2048 tokens**.
- Protocol: `non_overlapping_2048_drop_remainder`.
- The incomplete final block is dropped.
- Baseline model weights and inference dtype: **FP16** without quantization.
- PPL is computed by next-token prediction over every complete non-overlapping block.
- Earlier overlapping-window results are retained under `result/overlap/` for reference only and must not be compared directly with the current non-overlapping results.
- The reason for using non-overlapping evaluation is documented in [non-overlap-ppl-evaluation.md](non-overlap-ppl-evaluation.md).

## Prefill vs Decode Evaluation Scope

The current WikiText-2 PPL and DEWA sweeps are **teacher-forced full-sequence evaluations**.
Each complete 2048-token block is passed to the model in one forward call with
`use_cache=False`, and logits for all causal positions are computed in parallel. This workload
has a Linear shape and computational pattern similar to **prefill**, but it is not a complete
serving prefill benchmark because it does not build a KV cache.

The current experiments do **not** evaluate autoregressive decode. A decode experiment must run
one new token at a time with `use_cache=True` and reuse `past_key_values`. Prefill and decode must
be reported separately because they have different activation distributions and Linear shapes:

- Prefill-like full sequence: `M = batch_size * sequence_length` (currently `1 * 2048`).
- Single-token decode: `M = batch_size` (typically `1`).

Therefore, the existing PPL results establish the numerical feasibility of DEWA under a
prefill-like activation workload. They do not yet establish decode-phase DEWA decision rate, INT-Acc
success rate, FP-Acc activation rate, latency, or energy. The current Triton setting
`BLOCK_M = 32` is also designed for larger M and must not be treated as a representative decode
kernel when `M = 1`.

## Implemented Workflows

### FP16 Baseline

Baseline notebooks and full WikiText-2 results are complete for:

- LLaMA-2-7B
- LLaMA-2-13B
- LLaMA-3.1-8B
- OPT-6.7B

### Fake W/A BFP Quantization

- Linear-layer weights and activations are fake-quantized to BFP and dequantized before `F.linear`.
- Other model operations and Linear outputs remain FP16.
- Default block size: **G = 32**.
- Shared exponent width: **5 bits**.
- Rounding: nearest.
- Evaluated formats: **BFP8, BFP7, BFP6, BFP5, and BFP4**.
- Each `bfp.ipynb` sweeps BFP8 through BFP4 in one execution.
- This implementation evaluates numerical error and PPL only. It does not implement packed BFP storage, native BFP GEMM, or hardware speedup.

### Baseline BFP-PE RTL (Current Active Work)

The baseline hardware implementation is under `rtl/BFP-PE/`. It is intended to provide the
area/timing/energy reference before adding DEWA logic.

Current source structure:

- `01_RTL/BFP_PE.sv`: weight-stationary top level. `preload` loads one packed weight block and
  clears the accumulator; every non-preload clock accumulates one activation block.
- `01_RTL/INT_MAC.sv`: per-lane sign XOR and unsigned mantissa multiplication followed by a
  signed Group-N reduction.
- `01_RTL/BFP_PKG.sv`: leading-one detection, fixed-point-to-FP16 normalization, and a custom
  FP16 add function.
- `01_RTL/FP_ACC.sv`: converts each Group-N integer dot product to FP16 and accumulates it in one
  FP16 register.
- `00_TESTBED/gen_pattern.py`: seeded bit-exact Python golden generator.
- `00_TESTBED/PATTERN.sv` / `TESTBED.sv`: file-driven RTL checker.
- `02_SYN/syn90.tcl`: Synopsys Design Compiler flow for the TSMC 90-nm library at a nominal
  **10-ns clock period**.
- `03_GATE/`: gate-level VCS flow using the synthesized netlist and SDF.

Current RTL configuration from `01_RTL/include.svh`:

| Parameter | Current value | Notebook main experiment |
|---|---:|---:|
| Group size | 16 | 32 |
| Shared exponent width | 5 | 5 |
| Per-value sign width | 1 | 1 |
| Per-value magnitude mantissa width | 3 | 7 for BFP8 |
| Running accumulator | Custom FP16 | FP32 in the DEWA functional model |

For the current **G16/E5/M3** RTL, the derived widths are 6-bit magnitude products, 7-bit
signed products, an 11-bit signed dot-product sum, and a 10-bit output magnitude. The comments
in `include.svh` that mention 96-bit mantissa/32-bit sign buses and 12/11-bit sum/magnitude are
stale; the macros actually elaborate to 48-bit mantissa and 16-bit sign buses with 11/10-bit
sum/magnitude.

Verification status:

| Stage | Status |
|---|---|
| Python stimulus/golden generation | Present: 45 groups, 243 cycles, seed `20260720` |
| Behavioral RTL source and file list | Present |
| Behavioral VCS simulation | **Pass on server (user-confirmed); log is server-only** |
| Synthesis/area flow | **Pass on server (user-confirmed); reports/artifacts are server-only** |
| Gate-level flow | **Pass on server (user-confirmed); log/artifacts are server-only** |

Baseline BFP-PE decisions that must be resolved before the baseline is frozen or compared with DEWA:

1. Decide whether the baseline PE should remain **G16/E5/M3** or be changed to match the main
   experiment **G32/E5/M7**. Do not compare a G16/M3 PE directly against G32/BFP8 PPL results.
2. Freeze the BFP mantissa encoding and scale convention, then prove that the RTL integer dot
   product and normalization match the notebook fake-BFP definition on shared test vectors.
3. Freeze accumulator semantics. The RTL currently accumulates in custom FP16, whereas the DEWA
   functional model uses FP32 partials/accumulation and casts the Linear output to FP16.
4. Decide IEEE behavior for subnormals, rounding, overflow, Inf, and NaN. Current RTL truncates
   mantissas, flushes underflow to zero, and uses an all-ones exponent/mantissa code on overflow;
   this is not yet proven equivalent to PyTorch FP16.
5. Add or explicitly waive `valid`/clock-enable behavior. The current PE accumulates on every
   non-preload cycle and has no ready/valid interface.
6. Keep the server-side behavioral, synthesis, area/timing, netlist/SDF, and gate artifacts as the
   authoritative records. When the final baseline configuration is selected, copy their key tool
   versions, constraints, corner, area/timing/power numbers, and server paths into this document.

### DEWA Functional Model (legacy OB-Skip)

The current implementation is available in `ob-skip/LLaMA2-7B/ob_skip.ipynb`.

- Model: LLaMA-2-7B.
- Quantization: the same fake W/A BFP method as the BFP baseline.
- Partial-dot granularity: **Group 32**.
- Kernel: fused Triton Group-32 dot product.
- Threshold sweep: **T = 8, 9, 10, 11, 12** in one execution for a fixed BFP format.
- Decision rule for `delta = E_new - E_acc(t)`:
  - `delta <= -T`: discard New.
  - `delta >= T`: discard Old and replace it with New.
  - Otherwise: align and accumulate.
- Group partials and the current functional accumulator use FP32.
- The window position follows the current running accumulator exponent; it is not centered on a
  pre-profiled absolute exponent or a historical maximum.
- The Linear output is converted back to FP16.
- Hardware rounding, fixed-width overflow, and saturation are not currently modeled.
- Completed full evaluations currently cover **BFP8 through BFP4**, each with T = 8 through 12.

### Partial-Sum Exponent Profiling

- `ob-skip/LLaMA2-7B/profile_exponent.ipynb` profiles per-layer Group-32 partial-sum exponent histograms for BFP8 through BFP4.
- Eight complete WikiText-2 blocks are sampled uniformly across the full test split and reused for every BFP format.
- Raw per-layer histograms and sampling metadata are stored in JSON; plotting is performed locally without rerunning inference.
- Completed BFP8 through BFP4 profiler JSON files are stored in `ob-skip/LLaMA2-7B/result/exponent_profile/`.
- All five formats contain the same **225 Linear layers**: 32 Transformer blocks x 7 projections plus the LM Head.
- `W90`, `W95`, and `W99` are the shortest contiguous exponent intervals containing 90%, 95%, and 99% of nonzero partial sums.
- `Full span = Emax - Emin`, where `Emin` and `Emax` are the smallest and largest observed nonzero partial-sum exponents.
- The per-format median W90 spans from BFP8 through BFP4 are **5, 5, 5, 5, and 4** exponent steps.
- The per-format median W95 spans are **6, 6, 6, 6, and 5** exponent steps.
- The per-format median W99 spans are **9, 9, 9, 8, and 7** exponent steps.
- Across the 224 block-indexed Linear layers, the observed full-span statistics are:

| Format | Minimum | Median | Mean | Maximum |
|---|---:|---:|---:|---:|
| BFP8 | 20 | 25 | 24.79 | 33 |
| BFP7 | 18 | 23 | 23.02 | 32 |
| BFP6 | 16 | 21 | 21.16 | 29 |
| BFP5 | 15 | 20 | 19.81 | 28 |
| BFP4 | 12 | 18 | 18.08 | 26 |

### Exponent-Profile Visualization

`plot/plot_exponent_profile.py` reads the profiler JSON files and generates eight IEEE-style, 600-DPI PNG figures without rerunning model inference:

- `exponent_coverage_width.png`: per-layer W90/W95/W99 distributions across BFP formats.
- `per_layer_w95_heatmap.png`: W95 span for all 32 blocks x 7 Linear projections.
- `per_layer_full_span_heatmap.png`: observed full span for all 32 blocks x 7 Linear projections.
- `bfp8_exponent_distribution.png` through `bfp4_exponent_distribution.png`: representative-layer exponent histograms with `Emin`, `Emax`, full span, and mode.
- The heatmaps use a shared sequential light-to-dark blue scale so layers and BFP formats can be compared directly.
- IEEE-style PNG figures are stored in `plot/output/exponent_profile/`.

Current interpretation:

- Most nonzero partial sums are concentrated within a much narrower central interval than their observed full span.
- The difference between W95 and full span exposes sparse exponent tails/outliers and supports investigating an outlier-separation mechanism later.
- W95 and full span describe the marginal per-layer distribution of `E(partial_sum)`; they do **not** directly predict the DEWA bypass rate.
- Direct DEWA evidence still requires profiling `delta = E_new - E_acc(t)` along the runtime accumulation trajectory.

## Current PPL Results

### FP16 and Fake BFP

| Model | FP16 | BFP8 | BFP7 | BFP6 | BFP5 | BFP4 |
|---|---:|---:|---:|---:|---:|---:|
| LLaMA-2-7B | 5.472103 | 5.477353 | 5.490250 | 5.541911 | 5.731690 | 6.656973 |
| LLaMA-2-13B | 4.883702 | 4.885530 | 4.895086 | 4.921851 | 5.055231 | 5.557759 |
| LLaMA-3.1-8B | 6.237492 | 6.249961 | 6.273705 | 6.387770 | 6.842219 | 9.018817 |
| OPT-6.7B | 10.860297 | 10.866770 | 10.840898 | 10.892377 | 11.249532 | 14.359394 |

The small negative PPL difference for OPT-6.7B BFP7 is possible measurement variation and must not be interpreted as a guaranteed accuracy improvement.

### LLaMA-2-7B DEWA Sweep (legacy OB-Skip results)

Each cell shows `PPL (DEWA bypass rate)`. Existing JSON/plot fields call this `ob_skip_rate`;
the rate includes both discarded New values and replaced Old values.

| Format | T = 8 | T = 9 | T = 10 | T = 11 | T = 12 |
|---|---:|---:|---:|---:|---:|
| BFP8 | 5.612470 (4.935%) | 5.498691 (2.546%) | 5.480791 (1.295%) | 5.478265 (0.651%) | 5.477838 (0.322%) |
| BFP7 | 5.626352 (4.878%) | 5.513119 (2.497%) | 5.493500 (1.253%) | 5.491188 (0.613%) | 5.491904 (0.289%) |
| BFP6 | 5.673964 (4.706%) | 5.562028 (2.342%) | 5.543608 (1.117%) | 5.540475 (0.498%) | 5.539459 (0.200%) |
| BFP5 | 5.864675 (4.165%) | 5.749307 (1.883%) | 5.736951 (0.762%) | 5.733291 (0.265%) | 5.735013 (0.081%) |
| BFP4 | 6.847038 (2.772%) | 6.696692 (0.958%) | 6.665656 (0.289%) | 6.665513 (0.090%) | 6.671859 (0.031%) |

Current observations:

- Reducing T increases the DEWA bypass rate but also increases PPL degradation.
- T = 10 through 12 generally preserves PPL much better than T = 8.
- Lower BFP precision reduces the observed DEWA bypass rate at the same T; BFP4 is notably lower than BFP8 through BFP6.
- These results demonstrate the numerical effect of DEWA, not the actual FP-Acc activation reduction.
- The current `normal_add` path still uses an FP32 functional accumulator, so it cannot yet distinguish successful INT-Acc operations from INT-Acc overflows.

## Important Design Decisions

- **T is an exponent-difference threshold, not an accumulator bit width.**
- `T = 8` does not imply a 9-bit signed INT accumulator.
- T determines the accepted exponent window and maximum normal-path alignment shift of `T - 1`.
- `INT_ACC_BITS` independently determines the signed accumulator range and overflow probability.
- With BFP format and Group Size fixed, the next main design space is **T x INT_ACC_BITS**.
- The intended hardware behavior is to use shift plus INT-Acc normally and activate FP-Acc only when the fixed-width INT-Acc cannot represent the aligned result.
- This is conceptually related to Bucket Getter's trade-off between bucket register width and FP-Acc activity, but DEWA uses a simpler runtime moving-window decision rather than a multi-bucket accumulator.

## Feasibility Validation Roadmap

Goal: show that DEWA can replace most FP-Acc activity with a fixed-width INT-Acc at an
acceptable PPL cost. The final deliverable is a trade-off / Pareto analysis over the design
space **T x INT_ACC_BITS** with BFP format and Group Size fixed (start BFP8, G = 32).
The current baseline RTL is G16/E5/M3 and must be reconciled with this target first.

The three result axes come from three different sources, not one big sweep:

| Axis | Source | Status |
|---|---|---|
| PPL | Existing T-sweep (`ob-skip/LLaMA2-7B/result`) | done, reuse as-is |
| FP-Acc activation rate | Functional fixed-width model, one pass per T | to build |
| PE area / timing / power | Baseline BFP-PE, then parameterized DEWA RTL | baseline source in progress; no reports |
| Energy | Combine synthesis cost with activation rate | to build |

### Key result under exact fallback: PPL depends only on T, not on INT_ACC_BITS

DEWA's only current approximation is the exponent-window decision (`delta <= -T` discard New,
`delta >= T` replace Old), which depends solely on `E_acc(t)`, `E_new`, and T. INT_ACC_BITS only
decides whether a given `normal_add` runs in INT-Acc or falls back to FP-Acc; because the
fallback is lossless (no saturation, no wraparound), the arithmetic result is identical either
way. Therefore PPL is a function of T alone and the existing T-sweep already covers the PPL
axis. **Do not re-run the (expensive) GPU PPL evaluation per INT_ACC_BITS.**

This holds only under two assumptions, which the plan must keep true:

1. FP-Acc is modeled at >= the current FP32 accumulator precision. If the eventual hardware
   FP-Acc is narrower (FP16 / bf16 / custom), PPL must be re-checked.
2. Fallback is exact: no INT saturation, no wraparound, no bit loss beyond FP32 rounding.

Because INT accumulation and step-by-step FP32 accumulation round in different orders, "equal"
holds only up to FP32 rounding (below PPL noise, not a bit-level theorem). Confirm with one
validation run (see Phase 1).

### Phase 1: Functional fixed-width INT-Acc + FP-Acc activation

- [ ] Define the exact signed integer representation of each Group-32 partial dot product.
- [ ] Define whether `INT_ACC_BITS` includes the sign bit (recommended: it does).
- [ ] Derive the minimum lossless signed partial-dot width from unsigned magnitude mantissa
      width M and Group Size: `2M + ceil(log2(G)) + 1` bits for the straightforward worst-case
      bound including sign. Accumulation/alignment may require additional guard bits; do not
      equate the partial-dot width directly with `INT_ACC_BITS`.
- [ ] Replace the normal FP32 accumulation path with a functional fixed-width shift + INT-Acc
      model; detect overflow before committing; on overflow fall back to FP-Acc without INT
      saturation or wraparound. Keep `delta <= -T` discard New and `delta >= T` replace Old.
- [ ] **Single-pass optimization:** since the true accumulation trajectory is independent of
      INT_ACC_BITS, run one instrumented pass per T that logs the aligned intermediate
      magnitude at each `normal_add`; derive the FP-Acc activation rate for *every* candidate
      INT_ACC_BITS in post-analysis (count values exceeding `2^(INT_ACC_BITS-1)`). This
      collapses the T x INT_ACC_BITS grid into a per-T sweep.
- [ ] Add aggregate and per-layer counters: successful INT-Acc ops, INT-Acc overflow events,
      FP-Acc fallback events, discarded New, replaced Old, zero-value decisions.
- [ ] Report both `fp_acc_activation_rate = fp_acc_fallback_events / total_nonzero_decisions`
      and `normal_path_overflow_rate = fp_acc_fallback_events / normal_add_attempts`, always with
      raw numerators and denominators.
- [ ] **Validation run:** pick one config (e.g. BFP8, T = 10, small INT_ACC_BITS) and confirm
      the fixed-width + fallback path reproduces the existing FP32 T-sweep PPL, pinning down
      assumptions 1 and 2 above.

### Phase 1B: Separate Prefill and Decode Profiling

- [ ] Build a phase-aware evaluation path with `use_cache=True`: run prompt prefill first, reset
      or snapshot counters at the phase boundary, and then run single-token decode with reused
      `past_key_values`.
- [ ] Use fixed prompts and fixed continuation tokens for the primary activity comparison so
      every BFP, T, and INT_ACC_BITS configuration receives identical token inputs. Keep free-running
      greedy or sampled generation as a separate serving experiment because sequences may diverge.
- [ ] Record prefill and decode counters separately: discarded New, replaced Old, normal adds,
      successful INT-Acc operations, INT-Acc overflow events, and FP-Acc fallback events.
- [ ] Report phase-specific DEWA bypass rate (legacy field `ob_skip_rate`) and
      `fp_acc_activation_rate` with raw numerators and
      denominators. Do not combine prefill and decode into one rate without also reporting the
      number of processed prompt and decode tokens.
- [ ] Evaluate representative prompt lengths and decode lengths; record batch size, prompt length,
      generated/continuation length, KV-cache setting, and layer/kernel configuration in every
      result file.
- [ ] Use separate performance implementations or kernel configurations for prefill GEMM and
      decode GEMV / small-M execution. The current `BLOCK_M = 32` Triton kernel may still be used
      for numerical checking, but its decode latency and utilization are not representative.
- [ ] Compare the prefill/decode layer-wise exponent-gap distributions and identify whether the
      T x INT_ACC_BITS Pareto configuration selected from prefill remains valid for decode.
- [ ] Re-run PPL only if the cached sequential path changes numerical behavior. Otherwise reuse
      the existing full-sequence PPL sweep for the accuracy axis and use the phase-aware runs for
      activity and performance characterization.

### Phase 2A: Freeze and Verify the Baseline BFP-PE (in progress)

- [x] Create the weight-stationary BFP-PE RTL hierarchy, Python golden generator, file-driven
      testbench, synthesis script, and gate-level flow under `rtl/BFP-PE/`.
- [ ] Resolve the **G16/E5/M3 vs. G32/E5/M7** mismatch and align the Python, RTL, and notebook
      numerical contracts.
- [ ] Add independent cross-check vectors generated from the notebook/PyTorch definition; the
      current Python golden intentionally mirrors the RTL algorithm and proves internal bit-level
      consistency, not equivalence to the software experiment.
- [x] Run behavioral VCS on the server. User confirmed PASS; the complete log remains server-only.
- [ ] Freeze FP accumulator precision and rounding/subnormal/overflow behavior before using this
      PE as the area or energy baseline.
- [x] Run the synthesis/area flow on the server. User confirmed PASS; reports and implementation
      artifacts remain server-only.
- [ ] Add activity-based `report_power` or an equivalent power flow if it is not already part of
      the server flow; the local `syn90.tcl` only writes timing and area reports.
- [x] Run the gate-level flow on the server. User confirmed PASS; logs/artifacts remain server-only.
- [ ] Record the final server tool versions, numeric configuration, constraints, corner, area,
      timing, and power summary here once the baseline configuration is frozen.

### Phase 2B: Parameterized DEWA RTL PE + synthesis

- [ ] Starting from the frozen baseline, add a parameterized DEWA PE with `T` and
      `INT_ACC_BITS` as synthesis parameters.
      Mapping: INT_ACC_BITS -> INT accumulator register + adder width; T -> aligner/shifter
      width (max shift `T-1`) + exponent-window compare logic. The Group-32 integer MAC tree is
      fixed by BFP M and G, not by these knobs; hold it constant or count it as baseline.
- [ ] **Decide FP-Acc placement first**, because it determines whether the benefit is area or
      energy: per-PE FP-Acc -> FP-Acc area is a fixed cost, benefit shows up as energy; shared
      FP-Acc across PEs -> lower activation rate reduces FP-Acc unit count, benefit shows up as
      area. Pick one architecture before reading the synthesis area curves.
- [ ] Synthesize across the T x INT_ACC_BITS grid; record PE area, critical path, and power per
      config. Baseline and DEWA must use the same G/M/E format, accumulator precision, library,
      corner, clock constraint, I/O assumptions, pipeline/throughput target, and synthesis effort.

### Phase 3: Energy model, Pareto, and baseline comparison

- [ ] Combine synthesis cost with the functional activation rate:
      `E ~= E_int_path + fp_acc_activation_rate * E_fp_acc`.
- [ ] Use the frozen baseline BFP-PE (full FP-Acc, no DEWA) as the mandatory reference. Add
      Bucket Getter only if its numeric format, technology, throughput, and synthesis assumptions
      can be normalized fairly.
- [ ] Build the Pareto view: x = PE area or energy, y = FP-Acc activation rate, with PPL as a
      constraint (filter `delta_PPL <= budget`, e.g. 0.05) or as a third dimension / color. Note
      the trade-off is 3D: a large T with large INT_ACC_BITS degenerates to baseline BFP with an
      oversized accumulator (no skip, no overflow), so PPL must stay an explicit constraint.
- [ ] State the claim relative to the baseline, e.g. "at delta_PPL <= budget, DEWA uses X%
      area/energy for a Y% reduction in FP-Acc activation."

### Phase 4: Generalization

- [ ] Validate selected Pareto configs on other BFP formats and models after the LLaMA-2-7B
      pipeline is stable.
- [ ] Later extend synthesis to cycle-accurate modeling for real power, rounding, saturation,
      and throughput.

## Current Scope Limitation

The project currently supports conclusions about PPL and prefill-like DEWA bypass decision
frequency. It does not yet support a quantitative claim about decode-phase behavior, actual
FP-Acc activation, accelerator area, energy reduction, or speedup. Those claims require the
phase-aware evaluation, fixed-width overflow model, and eventual hardware synthesis or
equivalent hardware modeling described above.
