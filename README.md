# Research Workspace

This repository studies Block Floating Point (BFP), Dynamic Exponent-Window
Accumulation (DEWA), activation-outlier routing under a bounded Top-2 cap, and
the corresponding BFP processing-element RTL.

All active work lives under `research1/`.

## Start Here

- `research1/docs/Process.md`: authoritative research status, numerical
  contracts, results, and roadmap. Read this before anything else.
- `research1/docs/non-overlap-ppl-evaluation.md`: why the PPL protocol is
  non-overlapping, and why overlapping-window numbers are not comparable.
- `CLAUDE.md`: repository operating rules, commands, and conventions.

## Directory Layout

```text
research1/
|-- architecture/   editable drawio + exported PNG of the Top-2 / DEWA / FP-ACC datapath
|-- docs/           research process and evaluation documentation
|-- experiments/    01_Baseline .. 09_Hybrid; each stage keeps its Colab Notebook
|                   next to the result JSON files it produced
|-- plot/           01_exponent-profile, 02_outlier-profile, 03_ppl-comparison;
|                   each holds its plotting script and figures/g16|g32/ output
`-- rtl/            baseline BFP-PE plus the parameterized Bucket Getter PE prototype
```

Result JSON files are self-describing: each records its full configuration,
evaluation protocol, environment versions, and raw numerator/denominator counts.
The plotting scripts read them directly and never rerun inference.

## Scope

The Notebooks establish WikiText-2 perplexity under fake quantization with
functional FP32 accumulation, exponent distributions, DEWA decision rates,
activation-outlier occupancy, and an optimistic FP-ACC request-count estimate.

They do not establish fixed-width INT-Acc overflow behavior, decode-phase
activity, cycle-level latency, synthesized DEWA area/timing/power, or measured
energy reduction. See `research1/docs/Process.md` sections 3, 12, and 13.

## Naming

The legacy identifiers `ob-skip`, `ob_skip`, `obskip`, and the directory names
`04_DEW` / `05_DEW_Outlier_Profile` are historical names of DEWA. They remain in
Notebook filenames, result filenames, and JSON fields, and the plotting scripts
parse them; do not rename them. New prose uses the formal name DEWA.

`T` is the exponent-difference threshold, not the INT accumulator bit width.
