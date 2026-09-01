# DEW-ACC Bit-Width / Overflow Profiler 實作規劃

## 1. 研究目標

本實驗先以 **LLaMA2-7B** 為對象，量測固定 `T_skip=9`、`T_replace=3` 時，不同 `DEW_ACC_W` 對所有 decoder `nn.Linear` output dot-product 的 overflow 行為。

本階段只回答下列問題:

1. 每一個 `DEW_ACC_W` 會產生多少 overflow events。
2. 有多少 output dot products 曾經發生至少一次 overflow。
3. Overflow 集中在哪些 Linear layer types 與 transformer layers。
4. 將 overflow 結果與已完成的 synthesis Area sweep 合併後，bit-width / overflow / Area 的 trade-off 為何。

本階段不重新做 PPL sweep、不估算 switching power，也不將 outlier FP-ACC requests 混入 overflow rate。Outlier 與 final spill 可保留原始 count，供後續 FP-ACC activity 分析使用。

## 2. Frozen Experiment Contract

### 2.1 Model 與 Dataset

- Model: `meta-llama/Llama-2-7b-hf`
- Dataset: `Salesforce/wikitext`, `wikitext-2-raw-v1`, `test`
- Context length: `2048`
- Stride: `2048`
- Evaluation: non-overlapping contexts, drop remainder
- Expected contexts: `166`
- Expected loss tokens: `339,802`
- Attention implementation: `eager`
- `use_cache=False`
- Model dtype: FP16

### 2.2 Quantized Scope

量化所有 32 個 decoder blocks 中的 224 個 `nn.Linear`:

- `self_attn.q_proj`
- `self_attn.k_proj`
- `self_attn.v_proj`
- `self_attn.o_proj`
- `mlp.gate_proj`
- `mlp.up_proj`
- `mlp.down_proj`

`lm_head` 維持 FP16，不納入 overflow 統計。Attention internal matmul、Softmax 與 RMSNorm 不納入。

### 2.3 Quantization 與 DEW Policy

- Weight: W-BFP4, G16, signed E5, 3-bit magnitude
- Activation: Top-2-capped T2A-BiE4, G16
- Threshold: signed `mean(X) + 3 * population_std(X)`
- Candidate rule: `abs(x) > threshold`
- Top-2 tie-break: smaller K/lane index first
- Normal DEW policy: sticky block exponent
- `T_skip=9`
- `T_replace=3`
- Sweep widths: `DEW_ACC_W = 12, 13, ..., 32`

Profiler 的 `Enew` 必須對齊目前 RTL:

```text
Enew = Ew + Ea_normal
```

其中只需要 exponent difference，因此 software 內可使用 unbiased step exponent。不得沿用現有 PPL notebook 的 `floor(log2(abs(Psum)))` 作為 `Enew`，也不得加入 Psum LOD。

## 3. Notebook 與輸出位置

新增獨立 Experiment 11 notebook:

```text
experiments/11_DEW_ACC_Bitwidth_Overflow/llama2-7b/
    dew_acc_bitwidth_overflow_profile.ipynb
```

本次只輸出一份 machine-readable JSON:

```text
results/dew-acc-bitwidth-overflow/llama2-7b/
    dew_acc_bitwidth_overflow.json
```

JSON 內同時保存 experiment metadata、per-width aggregate、per-layer raw counts、Area sweep、validation summary 與 runtime information。Notebook 可在 cell output 顯示簡短執行摘要，但不產生 CSV、圖表或 ZIP。

Notebook 直接整合 quantization、profiler、validation 與 JSON export，不另外建立 Python module。

## 4. Profiler Architecture

### 4.1 Reuse Boundary

從下列 notebook 複製並縮減必要元件:

```text
experiments/09_Hybrid/llama2-7b/
    top2_bie_sticky_emax_dewa_fpacc_t9_r3.ipynb
```

保留:

- Hugging Face credential bootstrap
- W-BFP4 weight quantization
- T2A-BiE4 activation quantization
- Top-2 selection 與 packed tags
- Linear replacement flow
- WikiText-2 non-overlapping evaluation
- Per-layer stats export framework

不直接沿用:

- Floating-point `normal_acc`
- `_leading_exponent(normal_partial)` DEWA decision
- 既有 unbounded FP32 normal accumulation stats

這些部分改成與 `DEW_ACC.sv` 相同的 fixed-width integer state machine。

### 4.2 Frozen Activation Stream

一次 model evaluation 只建立一份 quantized activation stream。所有 bit-width profiler 使用相同的 quantized input、weight 與 outlier tags，避免 21 次 end-to-end model evaluation 造成 runtime 過高及不同 activation feedback 混入 bit-width 比較。

主模型 output 維持目前 sticky-Emax functional path；sidecar profiler 只收集 overflow，不改變 model output。此實驗因此是 **同一 activation stream 下的 hardware-width sensitivity profile**，不是 21 組獨立 PPL 結果。

### 4.3 Integer Partial Reconstruction

現有 fake-quantized weight/activation 以 FP16 power-of-two scaled values儲存。Profiler 在每個 G16 重新取得:

1. Weight block exponent 與 signed 3-bit mantissas。
2. Activation normal exponent 與 signed 3-bit mantissas。
3. 依 packed outlier tags 排除 exception lanes。
4. 使用 integer mantissa product 形成 `normal_psum`。
5. 使用 weight/activation step exponents 形成 `Enew`。

```text
normal_psum = sum(w_mantissa[i] * a_mantissa[i]) for normal lanes
Enew        = weight_step_exp + normal_activation_step_exp
```

Zero normal partial 不建立或更新 Eacc state。

### 4.4 Per-Width State

每個 output dot product、每個 width 維護:

```text
valid
eacc_exp
acc_value
overflowed_once
overflow_event_count
```

State update 完全對齊 RTL:

```text
normal_psum == 0:
    ZERO

valid == 0:
    LOAD normal_psum, Enew

delta = Enew - Eacc

delta <= -9:
    SKIP_NEW

delta >= +3:
    REPLACE_OLD with normal_psum, Enew

-9 < delta < +3:
    align smaller-exponent operand toward zero
    candidate = shifted_operand + bypass_operand
```

對 width `W`:

```text
minimum = -(1 << (W - 1))
maximum =  (1 << (W - 1)) - 1
overflow = candidate < minimum or candidate > maximum
```

Overflow 發生時先計數，再依 RTL 清除 accumulator state。後續 G16 blocks 從 invalid state重新 LOAD，因此 exact event count 允許同一 output dot product 發生多次 overflow。

### 4.5 GPU Execution Strategy

Sidecar Triton profiler 使用下列 optimized execution:

- 每個 program instance 同時維護 8 個 `DEW_ACC_W` state。
- W12-W32 分成 3 個 width batches，取代原本 21 個獨立 width programs。
- 同一 batch 內共用 weight/activation exponent、mantissa、`normal_psum` 與 `Enew`。
- 使用 `BLOCK_M=2`、`BLOCK_N=16`，將 output tile reshape 成 rank-2 `[output, width]` state，避免 rank-3 compiler 路徑。
- G16 dot 使用 K32 zero padding 以符合 Triton Tensor Core 的 minimum K constraint；padding lanes 固定為 0，不改變 integer result。
- 不寫 intermediate output tensor，只 atomic-add raw counters。
- 每個 context 完成後輸出 JSON checkpoint，重新啟動時恢復所有 per-layer counters。
- `PROFILE_CONTEXTS` 可先設為 4 量測速度，正式結果再設為 166。

不得為了速度改變 G16 processing order 或 DEW state semantics。

## 5. Metrics Definition

### 5.1 Raw Counts

每個 width、每個 Linear layer 記錄:

- `total_group_output_slots`
- `normal_zero_slots`
- `normal_load_count`
- `normal_skip_count`
- `normal_replace_count`
- `normal_align_attempt_count`
- `overflow_event_count`
- `overflowed_output_count`
- `total_output_count`
- `final_nonzero_count`
- `outlier_nonzero_request_count`，只保留供後續分析

### 5.2 Primary Rates

主要 bit-width/overflow 圖使用:

```text
overflowed_output_rate
    = overflowed_output_count / total_output_count
```

它表示有多少 output dot products 至少發生一次 overflow。

同時報告:

```text
overflow_event_rate_per_align
    = overflow_event_count / normal_align_attempt_count

overflow_traffic_rate
    = overflow_event_count / total_group_output_slots
```

第一個反映 DEW alignment addition 本身的 overflow 機率；第二個可在後續轉換成 FP-ACC overflow traffic。

### 5.3 Aggregation Rule

Whole-model rate 必須先加總 raw counts 再相除:

```text
global_overflow_rate
    = sum(layer_overflow_count) / sum(layer_denominator)
```

禁止直接平均 224 個 layer percentages，因為不同 Linear shapes 的 output/G16 slot 數量不同。

Per-layer-type 另外聚合:

- `q_proj`
- `k_proj`
- `v_proj`
- `o_proj`
- `gate_proj`
- `up_proj`
- `down_proj`

Per-transformer-layer 保留 `model.layers.0` 至 `model.layers.31`，用於定位 overflow hotspots。

## 6. Area Integration

讀取已完成的 synthesis sweep:

```text
rtl/03_DEW-PE/02_SYN/Sweep_Report/W12/area.rpt
...
rtl/03_DEW-PE/02_SYN/Sweep_Report/W32/area.rpt
```

以及各自的 `area_h.rpt`，解析:

- `total_pe_area`
- `dew_acc_area`
- `combinational_area`
- `noncombinational_area`

以 `acc_width` merge overflow results，並寫入同一份 `dew_acc_bitwidth_overflow.json` 的 `area_by_width` 欄位。若 Colab 找不到 local synthesis reports，notebook 允許上傳一個包含 `Sweep_Report` 的 ZIP 作為輸入；缺少任一 W12-W32 時必須 fail，不做 silent interpolation。

## 7. Validation Plan

### 7.1 Unit Tests

PyTorch reference 必須覆蓋:

- Positive/negative LOAD
- Positive/negative alignment
- Shift toward zero
- Exact signed minimum/maximum boundary
- Positive overflow
- Negative overflow
- Overflow state clear and following LOAD
- SKIP 不改 state
- REPLACE 不產生 overflow event
- Zero partial 不改 state
- 同一 output 多次 overflow

### 7.2 PyTorch / Triton Parity

使用小型 synthetic Linear shapes，比對 W12-W32:

- Raw counters 完全相同
- Per-width `overflowed_once` mask 完全相同
- Per-layer aggregate 完全相同

本項採 bit-exact integer counter comparison，不使用 tolerance。

### 7.3 RTL Trace Cross-Check

使用 Experiment 10 的 Layer 16 `mlp.down_proj` 256-dot trace，確認 profiler 的 RTL-exact state machine得到:

- W24 overflow events: `0`
- W12-W32 overflow events: `0`，依目前 trace 的已知結果
- W24 `skip=0`
- W24 `replace=6`

此 cross-check 用來防止 profiler 誤用 Psum LOD、錯誤 exponent bias 或 Python negative right-shift semantics。

### 7.4 Dataset Closure

Full run 驗收:

- Quantized Linear layers: `224`
- Evaluated contexts: `166`
- Loss tokens: `339,802`
- 每個 width 都有完整 raw counters
- `overflowed_output_count <= total_output_count`
- `overflow_event_count <= normal_align_attempt_count`
- `overflowed_output_rate` 隨 width 增加不得上升
- JSON aggregate 等於 per-layer raw count sum

## 8. Notebook Execution Flow

Notebook cell 順序:

1. Imports、constants、width sweep。
2. Hugging Face token bootstrap。
3. Quantization helpers。
4. RTL-exact PyTorch DEW profiler reference。
5. Sidecar Triton profiler kernel。
6. Synthetic unit tests。
7. PyTorch/Triton parity tests。
8. Load WikiText-2 test tokens。
9. Load FP16 LLaMA2-7B and replace 224 Linear layers。
10. Pilot run runtime/memory check。
11. Configurable-context profiling run and per-context checkpoint。
12. Validation and layer aggregation。
13. Parse/merge Area reports。
14. 建立並驗證最終 JSON schema。
15. Export `dew_acc_bitwidth_overflow.json`。

## 9. JSON Schema

最終 JSON 頂層至少包含:

```text
experiment
quantization
widths
global_by_width
layer_type_by_width
transformer_layer_by_width
per_linear_layer
area_by_width
validation
runtime
```

所有 rate 都必須同時保留 numerator、denominator 與計算後的 floating-point value，避免後續分析無法重新聚合。若某一段 widths 的 overflow 全為 0，JSON 必須保存真實的 `0`，不得使用 epsilon 或其他顯示用替代值。

本次不實作 plotting，不輸出 PNG、SVG、PDF、CSV 或 notebook 內嵌圖表。後續需要繪圖時，再由這份 JSON 建立獨立分析程式。

## 10. Acceptance Criteria

- 使用 LLaMA2-7B 全部 224 個 decoder Linear layers。
- 使用完整 WikiText-2 test non-overlapping 2048-token protocol。
- W12-W32 每一個 width 都有 raw counts 與 rates。
- Overflow state machine 與目前 `DEW_ACC.sv` 的 block-exponent、shift、overflow-clear semantics一致。
- 不使用 Psum LOD 計算 `Enew`。
- PyTorch/Triton synthetic parity bit-exact。
- Experiment 10 trace cross-check 通過。
- Whole-model aggregate 由 raw counts 加總，不平均 layer percentages。
- 成功產生且可重新載入唯一的 `dew_acc_bitwidth_overflow.json`。
- JSON 包含完整 raw counts、rates、per-layer results、Area data 與 validation summary。
- 本次不建立任何圖表或額外分析檔案。
- 本次不修改 RTL、不重新跑 PPL、不宣稱 switching power reduction。

## 11. Implementation Order

1. 從既有 sticky-Emax notebook 建立獨立 Experiment 11 notebook。
2. 先完成 RTL-exact PyTorch reference 與 synthetic tests。
3. 完成 Experiment 10 trace cross-check。
4. 實作 sidecar Triton profiler，完成 small-shape parity。
5. 以 1/4/16 contexts 做 pilot profiling。
6. 完整執行 166 contexts。
7. Merge W12-W32 Area reports，驗證 schema 後輸出單一 JSON。
