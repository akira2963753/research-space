# Shared RTL numerical verification

This directory owns the trace description shared by the Baseline BFP-PE and
BucketGetter verification environments.

- `trace_metadata.json`: model, quantization format, tensor shape, and trace size.
- `trace_index.csv`: maps each dot product to its token, output channel, and
  Baseline final cycle.
- `verify_baseline_bfp_pe.ipynb`: reconstructs the mathematical G16/BFP4 result
  and compares both RTL implementations.
- `reports/`: generated numerical summaries, tables, and plots.

Each DUT keeps its own `input.dat` and `output.dat` so its VCS testbench remains
independently runnable.
