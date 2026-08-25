# Research Process

Last updated: 2026-08-25

## 1. Purpose and Authority

This file is the single source of truth for the current research workspace. It records:

- the active directory layout;
- numerical and evaluation contracts;
- completed experiments and canonical results;
- claims supported by the current evidence;
- unresolved hardware and experimental work.

All active files are under `research1/`. Paths in this document are relative to the repository
root. The former top-level `model/`, `ob-skip/`, `plot/`, and `rtl/BFP-PE/` layouts are no longer
active.

Legacy identifiers `ob-skip`, `ob_skip`, and `obskip` remain in historical Notebook names,
filenames, and JSON fields. Do not rename them unless every dependent parser is updated. New
prose uses the formal method name **Dynamic Exponent-Window Accumulation (DEWA)**.

## 2. Workspace Layout

```text
research1/
|-- architecture/
|   |-- top2_dewa_fpacc_architecture.drawio
|   `-- top2_dewa_fpacc_architecture.png
|-- docs/
|   |-- Process.md
|   `-- non-overlap-ppl-evaluation.md
|-- experiments/
|   |-- 01_Baseline/
|   |-- 02_Vanilla_BFP/
|   |-- 03_Exponent_Profile/
|   |-- 04_DEW/
|   |-- 05_DEW_Outlier_Profile/
|   |-- 06_BiE/
|   |-- 07_ActivationBiE/
|   |-- 08_ActivationBiETop2/
|   |-- 09_Hybrid/
|   `-- 10_RTL_Trace/
|-- plot/
|   |-- 01_exponent-profile/
|   |-- 02_outlier-profile/
|   `-- 03_ppl-comparison/
`-- rtl/
    |-- 00_verification/
    |-- 01_Baseline-BFP-PE/
    `-- 02_Bucket-Getter-PE/
```

Each experiment directory keeps its producer Notebook and result JSON files together. A JSON
file is canonical only when its protocol metadata agrees with the contracts in this document.

Current inventory:

| Stage | Producer Notebooks | Result JSON files | Status |
|---|---:|---:|---|
| `01_Baseline` | 4 | 4 | Complete |
| `02_Vanilla_BFP` | 4 | 40 | G16 and G32 complete for four models |
| `03_Exponent_Profile` | 1 | 10 | G16 and G32 complete |
| `04_DEW` | 2 | 25 | G16/G32 producers retained; recorded BFP4-BFP8, T8-T12 sweep complete |
| `05_DEW_Outlier_Profile` | 1 | 2 | G16 and G32 complete |
| `06_BiE` | 1 | 5 | BiE4-BiE8 complete |
| `07_ActivationBiE` | 1 | 5 | BFP4/BiE4 through BFP8/BiE8 complete |
| `08_ActivationBiETop2` | 1 | 1 | BFP4/BiE4 Top-2 complete |
| `09_Hybrid` | 2 | 20 | Symmetric T3-T12; conditional asymmetric T_replace=2-4; direct-FP-ACC asymmetric T_replace=2-8 recorded |
| `10_RTL_Trace` | 1 | 2 | LLaMA-2-7B layer-16 down_proj G16/BFP4 trace complete |

The abandoned W/A-BiE + DEWA stage produced no canonical PPL JSON and was intentionally not
retained in the active workspace. Obsolete overlapping-window results and the old
`mean(abs(X)) + 3 * std(abs(X))` threshold ablation are also not part of `research1/`.

## 3. Research Objective

The project studies whether a hardware-friendly BFP processing element can reduce expensive
floating-point accumulation activity by combining:

1. Block Floating Point quantization;
2. Dynamic Exponent-Window Accumulation;
3. activation-only dual-exponent encoding;
4. Top-2 bounded outlier routing;
5. a shared FP accumulator for exception partials and final accumulation.

The software experiments currently establish:

- WikiText-2 PPL under fake quantization and functional FP32 accumulation;
- exponent-distribution behavior;
- DEWA skip/replace decision frequency;
- activation-outlier occupancy and routing scope;
- an optimistic functional FP-ACC request-count estimate.

The current results do **not** establish:

- fixed-width INT-Acc overflow or exact FP-ACC fallback rate;
- decode-phase behavior;
- cycle-level latency or throughput;
- synthesized DEWA area, timing, or power;
- measured energy reduction.

## 4. Common Evaluation Protocol

All canonical PPL results use the same non-overlapping WikiText-2 protocol.

| Field | Contract |
|---|---|
| Dataset | `Salesforce/wikitext` |
| Dataset configuration | `wikitext-2-raw-v1` |
| Split | `test` |
| Text joining | `"\n\n".join(dataset["text"])` |
| Context length | 2048 |
| Stride | 2048 |
| Drop remainder | `True` |
| Protocol name | `non_overlapping_2048_drop_remainder` |
| Evaluation blocks | 166 |
| Used input tokens | 339,968 |
| Loss tokens per block | 2,047 |
| Evaluated loss tokens | 339,802 |
| Inference dtype | FP16 unless explicitly quantized |
| KV cache | `use_cache=False` |

Perplexity is computed from token-weighted negative log likelihood:

```text
total_nll += block_loss * 2047
mean_nll = total_nll / 339802
PPL = exp(mean_nll)
```

The incomplete final token block is dropped. Results from a sliding-window or overlapping
protocol must not be compared with these results.

### 4.1 Prefill and Decode Scope

The current PPL runs are teacher-forced full-sequence evaluations. Each 2048-token block is
processed in one forward call with `use_cache=False`. This is a prefill-like Linear workload,
but it is not a complete serving prefill benchmark because no KV cache is built.

Autoregressive decode is not evaluated. A decode study must process one new token at a time with
`use_cache=True` and reused `past_key_values`. Prefill and decode counters must be reported
separately because their activation distributions and GEMM/GEMV shapes differ.

## 5. Numerical Contracts

### 5.1 Block Floating Point

- Shared exponent width: signed/encoded E5.
- Per-value private format: one sign bit plus `mantissa_bits` magnitude bits.
- BFP4 therefore means 1 sign bit + 3 magnitude bits.
- Group size is G16 or G32 as stated by each experiment.
- Shared exponent selection uses the maximum absolute value in each contiguous K-dimension group.
- Mantissas use nearest rounding.
- Fake-quantized values are dequantized before `F.linear`.
- Packed BFP storage, native BFP arithmetic, and hardware speedup are not modeled by the
  Notebooks.

### 5.2 Dynamic Exponent-Window Accumulation

At accumulation step `t`, let:

```text
delta = E_new - E_acc(t)
```

`E_acc(t)` is the leading exponent of the **current numeric accumulator**, not a historical
maximum. Cancellation can reduce it.

The decision rule is:

```text
delta <= -T  : discard New
delta >=  T  : discard Old and replace it with New
otherwise    : align and accumulate
```

The accepted exponent window is:

```text
[E_acc(t) - T + 1, E_acc(t) + T - 1]
```

Its width is fixed at `2T - 1` exponent levels, but its location moves online with the current
accumulator.

T is an exponent-difference threshold. It is **not** the INT accumulator bit width.

### 5.3 BiE Threshold and Encoding

The active BiE-family experiments use:

```text
threshold(X) = mean(X) + 3 * std(X)
outlier(x)   = abs(x) > threshold(X)
```

The mean and population standard deviation are computed over the signed tensor values. This is
the signed `mu + 3 sigma` threshold used as a hardware-oriented research rule. It is not a
reproduction of the original BiE Bayesian threshold search or Oiso's final MSE-optimized
threshold selection.

For weights, one threshold is computed per complete weight tensor before row chunking. For
activations, one threshold is computed per complete Linear input tensor on each forward call.

BiE uses:

- one normal shared exponent per group;
- one outlier shared exponent per group;
- one type bit per value selecting the exponent.

### 5.4 Activation-Only BiE

The activation-only design uses:

- weights: single-exponent BFP;
- activations: dual-exponent BiE;
- `lm_head`: FP16;
- attention-internal matmul, Softmax, LayerNorm, and non-Linear operations: FP16.

For BFP4/BiE4 G16, the encoded costs excluding tensor-threshold metadata are:

| Operand | Logical cost |
|---|---:|
| Weight | `4 + 5/16 = 4.3125` bits/value |
| Activation | `4 + 1 + 10/16 = 5.625` bits/value |

These costs do not include packed sparse indices or control overhead.

### 5.5 Top-2 Activation Cap

For each contiguous G16 activation block:

1. compute all `abs(x) > mu + 3 sigma` candidates;
2. retain at most the two candidates with the largest absolute magnitudes;
3. break equal-magnitude ties by the lower K index;
4. demote all remaining candidates into the normal set;
5. compute the normal exponent after demotion;
6. compute the outlier exponent from the retained zero-to-two values.

Demoted candidates are quantized with the normal exponent; they are not discarded. The encoded
outlier count is therefore structurally bounded at two per G16 block.

### 5.6 Current Hybrid Accumulation

The current canonical hybrid experiment is:

```text
W-BFP4 / Top-2 A-BiE4 / G16 / asymmetric DEWA / direct exception FP-ACC
```

For each G16 group and output element:

- `P_N` is the partial sum from normal activation lanes;
- `P_O` is the partial sum from zero-to-two encoded outlier lanes.

Normal path:

```text
A_old == 0 and P_N != 0        : load P_N
E(P_N) - E(A_old) <= -T_skip   : skip P_N
E(P_N) - E(A_old) >= +T_replace: replace A_old with P_N
otherwise                      : align and accumulate
```

Exception path:

```text
P_O == 0                       : no FP-ACC update
P_O != 0                       : send P_O directly to shared FP-ACC
```

There is no exception-side exponent comparison, `T_exc`, or exception skip in the canonical
path. The older conditional exception-skip implementation is retained only as an ablation.
The current asymmetric sweep fixes `T_skip = 9` and varies only `T_replace` from 8 through 2.

The final Linear result is functionally:

```text
FP16(DEWA_normal_acc + FP32_exception_acc + bias)
```

This remains a floating-point functional model. Fixed-width normal accumulation and overflow
fallback are not yet modeled.

## 6. Current Status Summary

| Work item | Status | Main result or limitation |
|---|---|---|
| Four-model FP16 baseline | Complete | Common non-overlapping protocol |
| Four-model BFP4-BFP8 G32 | Complete | Fake W/A BFP; LM Head included |
| LLaMA-2-7B BFP4-BFP8 G16 | Complete | LM Head included; not scope-matched to BiE-family results |
| G16/G32 exponent profile | Complete | BFP4-BFP8, 225 recorded Linear layers |
| Original DEWA G32 sweep | Complete | BFP4-BFP8, T8-T12 |
| DEWA outlier profile | Complete | G16 and G32, BFP4, T8-T12, no PPL |
| W/A BiE4-BiE8 G16 | Complete | Decoder Linear layers; LM Head FP16 |
| W-BFP/A-BiE G16 | Complete | BFP4/BiE4 through BFP8/BiE8 |
| Top-2 W-BFP4/A-BiE4 | Complete | Only the BFP4/BiE4 design point |
| Top-2 hybrid sweeps | Complete | Symmetric T3-T12; conditional `(8, 2-4, 8)` ablation; direct-FP-ACC `T_skip=9`, `T_replace=2-8` |
| IEEE-style plots | In progress | Exponent, outlier, and PPL comparison plots exist |
| Baseline BFP-PE RTL | Implemented and trace-verified | G16/E5/M3 with custom FP32 accumulation; 256/256 final results exact |
| Fixed-width INT-Acc model | Not implemented | Required for real FP-ACC fallback activity |
| Decode profiler | Not implemented | Existing activity is prefill-like only |
| DEWA RTL | Not implemented | Must follow a frozen baseline RTL contract |
| Bucket Getter RTL prototype | Implemented and trace-verified | Top-6 x 4-bit, four exponent levels per bucket; server VCS produces 256/256 bit-exact results |
| 90 nm synthesis and power | Rerun required | Existing Bucket Getter reports predate the three-module RTL refactor and are superseded |
| Gate-level verification | Unconfirmed | Gate flow files exist, but no checked-in pass report establishes completion |

## 7. PPL Results

### 7.1 FP16 and Vanilla BFP G32

These are the completed four-model reference results. Vanilla BFP includes the LM Head in its
quantized Linear scope.

| Model | FP16 | BFP8 | BFP7 | BFP6 | BFP5 | BFP4 |
|---|---:|---:|---:|---:|---:|---:|
| LLaMA-2-7B | 5.472103 | 5.477353 | 5.490250 | 5.541911 | 5.731690 | 6.656973 |
| LLaMA-2-13B | 4.883702 | 4.885530 | 4.895086 | 4.921851 | 5.055231 | 5.557759 |
| LLaMA-3.1-8B | 6.237492 | 6.249961 | 6.273705 | 6.387770 | 6.842219 | 9.018817 |
| OPT-6.7B | 10.860297 | 10.866770 | 10.840898 | 10.892377 | 11.249532 | 14.359394 |

The small OPT-6.7B BFP7 decrease is measurement variation and must not be presented as a
guaranteed accuracy improvement.

### 7.2 LLaMA-2-7B G16 Format Comparison

Each cell is `PPL (delta versus FP16 5.472103)`.

| Data format | Vanilla BFP | W/A BiE | W-BFP / A-BiE | Top-2 W-BFP / A-BiE |
|---|---:|---:|---:|---:|
| BFP4/BiE4 | 6.282530 (+0.810427) | 5.973909 (+0.501806) | 6.013385 (+0.541282) | 6.015556 (+0.543453) |
| BFP5/BiE5 | 5.667681 (+0.195578) | 5.602792 (+0.130689) | 5.606311 (+0.134208) | Not run |
| BFP6/BiE6 | 5.527787 (+0.055684) | 5.506629 (+0.034525) | 5.509122 (+0.037019) | Not run |
| BFP7/BiE7 | 5.486825 (+0.014722) | 5.482515 (+0.010412) | 5.482368 (+0.010264) | Not run |
| BFP8/BiE8 | 5.475262 (+0.003159) | 5.473536 (+0.001433) | 5.473857 (+0.001754) | Not run |

Important scope warning:

- G16 Vanilla BFP results use `quantize_lm_head=True`.
- BiE, Activation BiE, and Top-2 results keep `lm_head` in FP16.

The current comparison plot is therefore provisional. A paper-quality method comparison should
rerun LLaMA-2-7B G16 Vanilla BFP4-BFP8 with `quantize_lm_head=False`, or explicitly label and
justify the different scope.

### 7.3 Original DEWA G32 Sweep

Each cell is `PPL (DEWA OOW decision rate)`. The legacy JSON field is `ob_skip_rate`; it includes
both skipped New and replaced Old decisions.

| Format | T8 | T9 | T10 | T11 | T12 |
|---|---:|---:|---:|---:|---:|
| BFP8 | 5.612470 (4.935%) | 5.498691 (2.546%) | 5.480791 (1.295%) | 5.478265 (0.651%) | 5.477838 (0.322%) |
| BFP7 | 5.626352 (4.878%) | 5.513119 (2.497%) | 5.493500 (1.253%) | 5.491188 (0.613%) | 5.491904 (0.289%) |
| BFP6 | 5.673964 (4.706%) | 5.562028 (2.342%) | 5.543608 (1.117%) | 5.540475 (0.498%) | 5.539459 (0.200%) |
| BFP5 | 5.864675 (4.165%) | 5.749307 (1.883%) | 5.736951 (0.762%) | 5.733291 (0.265%) | 5.735013 (0.081%) |
| BFP4 | 6.847038 (2.772%) | 6.696692 (0.958%) | 6.665656 (0.289%) | 6.665513 (0.090%) | 6.671859 (0.031%) |

Smaller T increases approximation and DEWA OOW decisions. Lower BFP precision also reduces the
observed OOW rate at the same T.

## 8. Profiling Results

### 8.1 Partial-Sum Exponent Full Span

`Full Span = Emax - Emin` over observed nonzero Group partial sums. The table excludes the LM
Head and contains 224 decoder Linear layers.

| Group | Format | Minimum | Median | Mean | Maximum |
|---:|---:|---:|---:|---:|---:|
| 16 | BFP4 | 13 | 19 | 18.97 | 27 |
| 16 | BFP5 | 16 | 21 | 20.70 | 29 |
| 16 | BFP6 | 17 | 22 | 22.20 | 31 |
| 16 | BFP7 | 19 | 24 | 23.91 | 33 |
| 16 | BFP8 | 21 | 26 | 25.70 | 34 |
| 32 | BFP4 | 12 | 18 | 18.08 | 26 |
| 32 | BFP5 | 15 | 20 | 19.81 | 28 |
| 32 | BFP6 | 16 | 21 | 21.16 | 29 |
| 32 | BFP7 | 18 | 23 | 23.02 | 32 |
| 32 | BFP8 | 20 | 25 | 24.79 | 33 |

Full Span is a marginal layer-level distribution metric. It does not directly measure the
online DEWA range because DEWA depends on `E_new - E_acc(t)` along the actual accumulation
trajectory.

### 8.2 Activation-Outlier Removal and DEWA Trajectories

The profiler compares two shadow paths using the same input and BFP4 weight:

- Raw: quantize the original activation.
- Clean: zero values satisfying `abs(raw_fp16_activation) > mu + 3 sigma`, then quantize.

The model forward continues along the Raw path. The Clean path is diagnostic only and does not
produce an end-to-end PPL result.

Scope warning: the two tables below are the profiler's top-level `aggregate`, which spans **225**
layers and therefore **includes the LM Head**. Section 8.1 and the section 10.2 figure both use
the 224 decoder Linear layers instead. The two scopes agree to roughly three decimal places, but
they are not the same population, and a paper-facing table should pick one. Aligning this is part
of the section 13 Priority 1 LM Head scope cleanup.

G32:

| T | Raw OOW | Clean OOW | Relative OOW reduction | Net normal-admission gain |
|---:|---:|---:|---:|---:|
| 8 | 3.256188% | 2.240361% | 31.197% | +1.024778% |
| 9 | 1.184024% | 0.638755% | 46.052% | +0.548797% |
| 10 | 0.382288% | 0.127242% | 66.716% | +0.256119% |
| 11 | 0.124250% | 0.020132% | 83.797% | +0.104446% |
| 12 | 0.042756% | 0.003119% | 92.704% | +0.039749% |

G16:

| T | Raw OOW | Clean OOW | Relative OOW reduction | Net normal-admission gain |
|---:|---:|---:|---:|---:|
| 8 | 5.663504% | 3.971439% | 29.877% | +1.702634% |
| 9 | 2.324713% | 1.350239% | 41.918% | +0.979136% |
| 10 | 0.852444% | 0.351345% | 58.784% | +0.502775% |
| 11 | 0.300786% | 0.071436% | 76.250% | +0.229908% |
| 12 | 0.110875% | 0.013124% | 88.163% | +0.097952% |

Routing scope:

| Group | Outlier activation lanes | Affected activation groups |
|---:|---:|---:|
| 16 | 195,707,316 / 18,723,373,056 = 1.045257% | 157,184,414 / 1,170,210,816 = 13.432145% |
| 32 | 196,282,747 / 18,723,373,056 = 1.048330% | 141,270,188 / 585,105,408 = 24.144400% |

G16 approximately halves whole-group routing scope while preserving the roughly 1.05% lane-level
outlier rate. Sparse lane/product routing is still preferable to routing every affected group.

Measured FP32 exact-absorption counters are zero. The observed T8-T12 decisions are
model-tolerated approximate skips, not additions proven to be swallowed exactly by FP32.

### 8.3 Activation BiE Occupancy

For W-BFP4/A-BiE4 G16:

- PPL: 6.013385.
- Activation outliers:
  `3,534,374,849 / 387,117,481,984 = 0.912998%`.
- Affected G16 blocks:
  `2,757,105,306 / 24,194,842,624 = 11.395426%`.
- Mean outliers per affected block: 1.281915.
- Exactly one outlier in 86.103862% of affected blocks.
- Global maximum: 16 outliers in one G16 block.
- All-16 blocks:
  `2,324 / 24,194,842,624 = 0.000009605%`.
- All-block percentiles: P99 = 2, P99.9 = 7, P99.99 = 11.
- Affected-block percentiles: P95 = 3, P99 = 6, P99.9 = 10, P99.99 = 13.

The high-occupancy tail is concentrated in `o_proj`. The global maximum should therefore not be
used to size a uniform exception-lane count.

### 8.4 Top-2 Cap

The Top-2 run produced:

- PPL: 6.015556.
- Delta versus uncapped Activation BiE: +0.002171.
- Candidate values:
  `3,534,537,129 / 387,117,481,984 = 0.913040%`.
- Encoded outlier values:
  `3,140,349,995 / 387,117,481,984 = 0.811214%`.
- Demoted candidates:
  `394,187,134 / 3,534,537,129 = 11.152440%`.
- Cap-triggered blocks:
  `141,953,953 / 24,194,842,624 = 0.586712%`.
- Encoded maximum: exactly 2.
- Encoded histogram mass above 2: zero.

`o_proj` contributes 96.275301% of all demoted values. Top-2 capping removes the need for a
`count > 2` replay in the encoded stream while causing negligible additional PPL degradation at
the BFP4/BiE4 point.

## 9. Hybrid Results

The direct accuracy baseline is the Top-2 PPL 6.015556. Every run uses 166 blocks, 339,802 loss
tokens, and 224 decoder Linear layers.

### 9.1 Symmetric DEWA Sweep

The symmetric sweep ties `T_skip = T_replace = T_exc = T`.

| T | PPL | Delta vs. Top-2 | DEWA OOW decisions | Skipped nonzero exception partials |
|---:|---:|---:|---:|---:|
| 3 | 111064.515625 | +111058.500069 | 74.607851% | 67.629739% |
| 4 | 38574.753906 | +38568.738350 | 53.717147% | 50.418180% |
| 5 | 45052.847656 | +45046.832100 | 33.201828% | 22.554519% |
| 6 | 18.640917 | +12.625361 | 18.046213% | 7.367138% |
| 7 | 6.554883 | +0.539327 | 8.665787% | 1.540732% |
| 8 | 6.067444 | +0.051888 | 3.618757% | 0.173865% |
| 9 | 6.020282 | +0.004726 | 1.209671% | 0.011773% |
| 10 | 6.018442 | +0.002886 | 0.304615% | 0.000573% |
| 11 | 6.014049 | -0.001507 | 0.060443% | 0.000018% |
| 12 | 6.010732 | -0.004824 | 0.011008% | 0.000001% |

T8 is the minimum usable symmetric setting, while T9 is the smallest symmetric setting with a
delta PPL below 0.01. The slightly lower PPL at T11 and T12 is a small approximate-arithmetic
perturbation and must not be described as a guaranteed accuracy improvement.

### 9.2 Archived Conditional Exception-Skip Asymmetric Sweep

The first asymmetric sweep fixed `T_skip = 8` and `T_exc = 8`, then varied only the high-side
replacement threshold. It is retained as an ablation; its exception-side skip is not used by the
current direct-FP-ACC design. The normal addition windows are inclusive integer ranges.

| (T_skip, T_replace, T_exc) | Normal addition DeltaE | PPL | Delta vs. Top-2 | OOW | skip_new | replace_old |
|---|---|---:|---:|---:|---:|---:|
| (8, 4, 8) | -7 to +3 | 6.074332 | +0.058776 | 4.087864% | 3.616699% | 0.471165% |
| (8, 3, 8) | -7 to +2 | 6.072722 | +0.057166 | 4.661762% | 3.616192% | 1.045570% |
| (8, 2, 8) | -7 to +1 | 6.097021 | +0.081465 | 5.790578% | 3.608664% | 2.181914% |

### 9.3 Direct Exception FP-ACC Sweep (`T_skip = 9`)

Every nonzero exception partial is now sent directly to the shared FP-ACC; there is no `T_exc`.
Only the high-side normal-path replacement threshold changes. The normal addition window is
`-8 <= DeltaE <= T_replace - 1`.

| (T_skip, T_replace) | Normal addition DeltaE | PPL | Delta vs. Top-2 | OOW | skip_new | replace_old | Total FP-ACC requests |
|---|---|---:|---:|---:|---:|---:|---:|
| (9, 8) | -8 to +7 | 6.024103 | +0.008547 | 1.212345% | 1.210310% | 0.002035% | 8.770158% |
| (9, 7) | -8 to +6 | 6.027493 | +0.011938 | 1.224655% | 1.210135% | 0.014519% | 8.770114% |
| (9, 6) | -8 to +5 | 6.023166 | +0.007610 | 1.274233% | 1.210470% | 0.063763% | 8.770060% |
| (9, 5) | -8 to +4 | 6.025974 | +0.010418 | 1.402145% | 1.210569% | 0.191576% | 8.770514% |
| (9, 4) | -8 to +3 | 6.024700 | +0.009144 | 1.681520% | 1.210330% | 0.471190% | 8.769903% |
| (9, 3) | -8 to +2 | 6.025145 | +0.009589 | 2.255690% | 1.210383% | 1.045307% | 8.769415% |
| (9, 2) | -8 to +1 | 6.049443 | +0.033887 | 3.388306% | 1.207333% | 2.180973% | 8.769214% |

`T_replace = 3` is the preferred observed trade-off. Relative to `(9, 4)`, it raises
replace-old from 0.471190% to 1.045307% (2.22x) for only +0.000445 PPL. `T_replace = 2`
further doubles replacement activity but costs +0.024298 PPL relative to `(9, 3)`. The PPL
spread among `T_replace = 8` through `3` is only 0.004327, so those points should not be used to
claim a strict accuracy ranking. Relative to the archived conditional `(8, 3, 8)` point, the
current `(9, 3)` result improves PPL by 0.047577 and reduces skip-new by 2.405808 percentage
points while preserving essentially the same replace-old rate; this comparison changes both
`T_skip` and the exception policy, so the improvement must not be attributed to either factor
alone.

### 9.4 Exception FP-ACC Traffic and Design Decision

Conditional exception skipping is not an effective FP-ACC reduction mechanism at `T_exc = 8`.
For the archived `(8, 3, 8)` point, it skips only 0.173757% of nonzero exception partials, while
the estimated total FP-ACC request rate is 8.785446% of Group-output slots. In the direct
`T_skip = 9` sweep, the implementation validates that every nonzero exception partial reaches
FP-ACC. Its exception FP-ACC request rate is 8.433362%-8.434619% and total request rate is
8.769214%-8.770514%. These ranges are not evidence that direct routing saves FP-ACC traffic,
because the normal policy changes downstream activations; the design decision is made for the
simpler exception datapath and the negligible observed filtering opportunity.

All FP-ACC request rates are functional operation-count estimates, not measured power reduction:
the normal accumulator remains unbounded FP32 and the model has no fixed-width INT-Acc overflow
fallback.

## 10. Plot Artifacts

### 10.1 Exponent Profile

Producer:

```text
research1/plot/01_exponent-profile/plot_exponent_profile.py
```

Inputs:

```text
research1/experiments/03_Exponent_Profile/llama2-7b/g16/
research1/experiments/03_Exponent_Profile/llama2-7b/g32/
```

Outputs per group:

- `bfp4_exponent_distribution.png` through `bfp8_exponent_distribution.png`;
- `per_layer_full_span_heatmap.png`.

### 10.2 DEWA Outlier Profile

Producer:

```text
research1/plot/02_outlier-profile/plot_outlier_profile.py
```

Outputs:

```text
research1/plot/02_outlier-profile/figures/g16/in_window_rate.png
research1/plot/02_outlier-profile/figures/g32/in_window_rate.png
```

Each figure compares the Raw and activation-outlier-separated paths using:

```text
In-window Rate
    = normal_add decisions / total nonzero decisions
    = 1 - OOW Rate
```

This is the most direct reader-facing interpretation: a higher rate means that more nonzero
partial-sum updates remain inside the DEWA accumulator window and follow the normal-add path.
The plots use the **224 decoder Linear layers**, exclude the LM Head by default, and share the
same linear percentage scale. Routing-scope and paired-transition figures are not part of the
paper-facing output; their source counters remain in the profiler JSON files.

### 10.3 PPL Comparison

Primary producer:

```text
research1/plot/03_ppl-comparison/ppl_comparison.ipynb
```

Outputs:

```text
research1/plot/03_ppl-comparison/figures/g16/ppl_delta_comparison.png
research1/plot/03_ppl-comparison/figures/g16/hybrid_symmetric_ppl_log_zoom_t3-12.png
research1/plot/03_ppl-comparison/figures/g16/hybrid_tskip_treplace_delta_ppl.png
research1/plot/03_ppl-comparison/figures/g16_g32/vanilla_bfp_delta_ppl_g16.png
research1/plot/03_ppl-comparison/figures/g16_g32/vanilla_bfp_delta_ppl_g32.png
```

The plot compares Vanilla BFP, BiE, Activation BiE, and Activation BiE Top-2 against the FP16
baseline. The Top-2 series currently contains only BFP4/BiE4. The figure remains provisional
until the Vanilla BFP LM Head scope is aligned.

The `(T_skip, T_replace)` gallery is `(8, 8)`, then `(9, 9)` through `(9, 2)`, then `(10, 10)`.
Equal-threshold points come from the symmetric JSON files; `(9, 8)` through `(9, 2)` come from
the direct exception FP-ACC sweep. The figure labels only `(T_skip, T_replace)`.

## 11. Baseline PE and Bucket Getter RTL

Active paths:

| Path | Role |
|---|---|
| `research1/rtl/00_verification/` | Shared trace metadata, mathematical reconstruction, and comparison reports |
| `research1/rtl/01_Baseline-BFP-PE/` | Weight-stationary Baseline PE with a custom FP32 running accumulator |
| `research1/rtl/02_Bucket-Getter-PE/` | Bucket Getter PE with adaptive integer buckets and FP32 spill accumulation |

The Bucket Getter is an independent accumulator prototype. It is not the RTL implementation of
the Top-2 activation dispatcher and asymmetric DEWA architecture described in section 5.6.

### 11.1 Common Comparison Configuration

The trace and synthesis comparison compile both designs with the same BFP input format:

| Parameter | Value |
|---|---:|
| Group size | 16 |
| Shared exponent width and bias | E5, bias 15 |
| Magnitude mantissa width | 3 |
| Per-value format | BFP4: 1 sign bit + 3 magnitude bits |
| Packed sign input | 16 bits |
| Packed mantissa input | 48 bits |
| Signed integer dot-product sum | 11 bits |
| FP accumulator | custom FP32: 1 sign / 8 exponent / 23 mantissa |

`02_Bucket-Getter-PE/01_RTL/include.vh` is the single configuration source for the Bucket Getter
project. It selects G16/E5/M3 and Top-6 x 4-bit buckets with four exponent levels per bucket.
The RTL, synthesis, and gate file lists contain no configuration `+define` overrides.

### 11.2 Datapath Roles

The Baseline PE performs one 16-lane signed integer dot product for each valid BFP block, converts
the partial sum into the custom FP32 representation, and updates `FP_ACC` directly. Its registered
weight follows weight-stationary timing: a same-cycle `weight_load` is visible on the following
cycle.

The Bucket Getter hierarchy is `BG_PE -> INT_MAC + BG_ACC + FP_ACC`. `INT_MAC` and `FP_ACC`
use the same arithmetic contract as the Baseline modules. `BG_ACC` decomposes each signed 11-bit
dot-product sum into radix-16 digits and accumulates those digits in six signed 4-bit circular
buckets. Each bucket covers four exponent levels, so the active window covers 24 exponent levels.
Non-max bucket overflow propagates to the adjacent higher-exponent bucket; max-bucket overflow
and final drain emit raw sign, magnitude, and exponent spill terms. The common `FP_ACC` performs
the same normalization, FP addition, and registered accumulation used by the Baseline. `BG_PE`
is the simulation and synthesis top level; FP-Acc sharing is intentionally outside this version.

### 11.3 Model-Derived Trace and Numerical Verification

The canonical input comes from:

```text
research1/experiments/10_RTL_Trace/llama2-7b/
    llama2_layer16_down_proj_g16_bfp4/
```

It captures LLaMA-2-7B layer 16 `mlp.down_proj` after upstream G16/BFP4 fake quantization. The
trace selects 16 contiguous token positions and 16 evenly spaced output channels:

| Field | Value |
|---|---:|
| Dot products | 256 |
| G16 blocks per dot product | 688 |
| Valid data rows | 176,128 |
| Setup plus valid input rows | 176,384 |
| Reporting relative tolerance | 1e-6 |

The Baseline and Bucket Getter testbeds use byte-identical `input.dat` files. The three-module
Top-6 x 4-bit Bucket Getter was rerun with VCS S-2021.09 on the lab server on 2026-08-25 after
the `BG_PE -> INT_MAC + BG_ACC + FP_ACC` refactor. All 176,384 input rows completed, and its
256 output words match the pre-refactor bit-exact reference line by line:

| Check | Result |
|---|---:|
| Baseline exact final matches | 256 / 256 |
| Baseline maximum cycle relative error | 0 |
| Bucket Getter bit-exact matches versus Baseline | 256 / 256 |
| Bucket Getter zero-error final results versus reference | 256 / 256 |

This result validates the selected trace. It does not yet establish full corner-case coverage or
a checked-in gate-level pass report.

### 11.4 RTL Execution Rules

Run each script from its own stage directory because the file lists use relative paths:

```text
cd research1/rtl/01_Baseline-BFP-PE/01_RTL
./01_run
cd ../02_SYN
./02_run
cd ../03_GATE
./03_run

cd research1/rtl/02_Bucket-Getter-PE/01_RTL
./01_run
cd ../02_SYN
./02_run
cd ../03_GATE
./03_run
```

The trace producer is the Colab-oriented `extract_llama2_g16_bfp4.ipynb`. VCS, Design Compiler,
the TSMC 90 nm libraries, and the gate-level Verilog model are available only on the server.

### 11.5 Superseded Pre-Refactor Synthesis Comparison

The checked-in `Report-BFP4` reports use Synopsys Design Compiler O-2018.06, the TSMC 90 nm
`slow` library, 0.9 V, and a 10 ns clock constraint. They describe the Top-6 x 4-bit design before
the `BG_PE -> INT_MAC + BG_ACC + FP_ACC` refactor. The old hierarchy split normalization,
FP addition, and the accumulator register across different modules, so its `u_fp_acc` row is not
comparable with the Baseline `FP_ACC`. These reports are retained only as pre-refactor history.

| Power metric | Baseline PE | Bucket Getter PE | Bucket Getter change |
|---|---:|---:|---:|
| FP-Acc hierarchy row | 1.972 mW | 0.00999 mW | Invalid module-boundary comparison |
| FP-Acc share of design total | 67.8% | 2.4% | Invalid module-boundary comparison |
| Total dynamic power | 2.8162 mW | 0.3789804 mW | Vectorless only |
| Cell leakage power | 0.0931646 mW | 0.0446088 mW | Pre-refactor |
| Design total power | 2.9093 mW | 0.4236 mW | Pre-refactor |

The Bucket Getter `u_fp_acc` row contains only the old stateless FP adder. Its accumulator register
was counted under `u_pe_core`, while bucket-to-FP conversion was counted under the bucket bank.
All Bucket Getter PPA values must therefore be regenerated for the three-module hierarchy.

The corresponding synthesis reports are:

```text
research1/rtl/01_Baseline-BFP-PE/02_SYN/Report/power.rpt
research1/rtl/01_Baseline-BFP-PE/02_SYN/Report/power_h.rpt
research1/rtl/02_Bucket-Getter-PE/02_SYN/Report-BFP4/power.rpt
research1/rtl/02_Bucket-Getter-PE/02_SYN/Report-BFP4/power_h.rpt
```

### 11.6 Interpretation Limits

The superseded reports use low-effort zero-delay switching-activity propagation. The checked-in synthesis
scripts do not annotate trace-derived SAIF, VCD, or FSDB activity, and the reports do not include
clock-network power or net-interconnect area. The reported reduction is therefore a vectorless
power estimate, not measured workload energy.

The two microarchitectures also have different acceptance, rotation, spill, and drain behavior.
The stale power values are not normalized by cycles per dot product or throughput. A paper
claim about energy efficiency requires the same trace-derived switching activity and an
`energy_per_dot_product = average_power * execution_time` comparison, together with area and
latency. The last pre-refactor cell-area reports show 18,273.63 for Baseline and 15,636.10 for
Bucket Getter, but the Bucket Getter value does not describe the current three-module RTL.

## 12. Current Interpretation

The evidence supports the following statements:

1. BiE materially improves low-bit PPL relative to single-exponent BFP at G16, although the
   current Vanilla BFP comparison includes the LM Head and must be scope-aligned.
2. Keeping weights single-exponent and applying BiE only to activations costs little relative to
   W/A BiE.
3. Top-2 capping bounds the encoded exception occupancy at two values per G16 block with only
   +0.002171 PPL versus uncapped activation-only BiE4.
4. Removing activation outliers admits more partial sums into the normal DEWA window.
5. G16 reduces affected-group routing scope from 24.144400% to 13.432145% compared with G32.
6. T9 is the best tested accuracy/DEWA-decision knee for the final hybrid.
7. Skipping small outlier partials contributes almost no additional FP-ACC request reduction.
8. The current request-count estimate is optimistic because fixed-width normal-path overflow is
   not modeled.

The evidence does not yet support claims about actual FP-ACC power reduction, speedup, or silicon
area improvement for the current Top-6 x 4-bit Bucket Getter. The Design Compiler reports in
section 11.5 are superseded and must not be used for the replacement RTL.

## 13. Required Next Steps

### Priority 1: Align the Software Baseline

- Rerun LLaMA-2-7B Vanilla BFP4-BFP8 G16 with `quantize_lm_head=False`.
- Regenerate the PPL comparison figure.
- Keep the old LM-Head-quantized JSON only if it is clearly labeled as an ablation.

### Priority 2: Freeze the BFP Numerical Contract

- Decide whether the hardware baseline is G16/E5/M3 or G32/E5/M3.
- Align RTL, generator, PPL experiments, and architecture diagrams to the selected group size.
- Correct stale `include.vh` comments.
- Add cross-check vectors derived independently from the PyTorch fake-BFP definition.
- Decide the exact mantissa scale, rounding, subnormal, overflow, Inf, and NaN contracts.
- Decide where FP32-to-FP16 output conversion occurs.
- The baseline PE now uses independent `acc_clear`, `weight_load`, and `in_valid` controls.
  `in_valid` accumulates with the currently registered weight; a same-cycle `weight_load`
  becomes visible on the following cycle.

### Priority 3: Implement the Fixed-Width INT-Acc Model

- Define `INT_ACC_BITS`, including whether it includes the sign bit.
- Model shift-and-add in a fixed-width signed integer accumulator.
- Detect overflow before commit.
- Fall back exactly to FP32 without saturation or wraparound.
- Record successful INT-Acc operations, overflow events, FP-ACC fallbacks, skips, replacements,
  and zero decisions.
- Report:

```text
fp_acc_activation_rate
    = fp_acc_fallback_events / total_nonzero_decisions

normal_path_overflow_rate
    = fp_acc_fallback_events / normal_add_attempts
```

Under exact fallback, PPL should depend on T, not on `INT_ACC_BITS`. Validate this assumption with
one end-to-end run.

### Priority 4: Separate Prefill and Decode

- Use `use_cache=True` for the phase-aware path.
- Reset or snapshot counters between prompt prefill and single-token decode.
- Reuse fixed prompts and fixed continuation tokens across configurations.
- Report prompt length, decode length, batch size, phase-specific counters, and kernel shape.
- Do not treat the current `BLOCK_M=32` Triton kernel as representative for `M=1` decode latency.

### Priority 5: Complete the RTL Measurement Methodology

- Rerun synthesis, timing, hierarchical area, and vectorless power for the Top-6 x 4-bit Bucket
  Getter; replace the superseded Top-4 x 128-bit report values.
- Rerun and record gate-level verification for both designs.
- Generate trace-derived SAIF or equivalent switching activity from the same input workload.
- Record accepted-input cycles, stall cycles, spill cycles, drain cycles, and total cycles per
  dot product for both designs.
- Report average power, latency, throughput, and energy per dot product together with cell area.

### Priority 6: Implement and Compare DEWA RTL

- Add parameterized T and `INT_ACC_BITS`.
- Decide whether FP-ACC is per PE or shared across PEs.
- Hold BFP format, group size, FP precision, technology, clock, and throughput constant.
- Sweep T and `INT_ACC_BITS`.
- Build a Pareto view over PPL, FP-ACC activation rate, area, timing, and energy.

### Priority 7: Generalization

- Validate selected Pareto points on additional formats and models.
- Extend only after the LLaMA-2-7B numerical and RTL contracts are stable.

## 14. Reproducibility Checklist

Before accepting a new result:

1. Confirm model checkpoint, tokenizer, dataset variant, and split.
2. Confirm context length 2048, stride 2048, and `drop_remainder=True`.
3. Confirm 166 blocks and 339,802 evaluated loss tokens for LLaMA-2-7B.
4. Confirm quantized operation scope and `quantize_lm_head`.
5. Confirm group size, shared exponent width, mantissa bits, and rounding.
6. Confirm signed `mean(X) + 3 * std(X)` threshold semantics for BiE-family experiments.
7. Confirm T and `T_exc` from both filename and JSON metadata.
8. Preserve raw numerators and denominators for every published rate.
9. Run Notebook syntax and synthetic validation cells.
10. Regenerate plots from repository-relative paths.
11. Update this file whenever a path, numerical contract, result, or status changes.
