# LLaMA WikiText-2 PPL Evaluation Protocol

## 目的

這份文件記錄 LLaMA2-7B 與 LLaMA2-13B 在 WikiText-2 上評估 PPL 時，overlap 與 non-overlap protocol 造成的差異。未來新增模型、BFP 格式或 OB-Skip 實驗時，必須先確認 evaluation protocol 完全一致，否則 PPL 不能直接比較。

## 曾經遇到的問題

最初的 notebook 使用：

- **`context_length = 2048`**
- **`stride = 512`**
- sliding-window overlap evaluation

得到的 FP16 PPL 明顯低於 BiLLM、AMoVE、Harmonia 等工作常見的 LLaMA2-7B WikiText-2 PPL 約 5.47。當時的結果本身不代表模型或程式損壞，而是使用了不同的 evaluation protocol。

目前已改成：

- **`context_length = 2048`**
- **`stride = 2048`**
- **`drop_remainder = True`**
- **`evaluation_protocol = "non_overlapping_2048_drop_remainder"`**

修改後，LLaMA2-7B FP16 PPL 為 **5.472103**，與上述論文常見結果一致。

## 為什麼 overlap 的 PPL 比較低

PPL 不只取決於模型與資料集，也取決於每個 target token 在預測時可以看到多少 preceding context。

當 **`context_length = 2048`**、**`stride = 512`** 時，相鄰視窗重疊 1536 tokens。若正確遮罩已經作為 context 的重疊部分，只計算每次新增的 tokens，後續 target tokens 通常能取得較長的 preceding context，因此任務相對容易，PPL 會降低。

當 **`stride = context_length = 2048`** 時，每個 block 完全獨立。每個 block 開頭附近的 token 只有較短的 context，因此整體 PPL 通常高於 sliding-window overlap evaluation。

因此：

- overlap evaluation 不是必然錯誤，但它代表另一種 protocol。
- overlap 與 non-overlap 的 PPL **不能直接互相比較**。
- 若論文採用 non-overlapping 2048 blocks，我們也必須使用相同方式才能公平比較。
- 若 overlap 實作沒有遮罩重疊區域，還會重複計算部分 tokens，使結果更加無法比較。

## 目前採用的標準設定

| 項目 | 設定 |
|---|---|
| Model | `meta-llama/Llama-2-{7b,13b}-hf` |
| Dataset | `Salesforce/wikitext` |
| Dataset config | `wikitext-2-raw-v1` |
| Split | `test` |
| Text joining | `"\n\n".join(dataset["text"])` |
| Context length | **2048** |
| Stride | **2048** |
| Drop remainder | **True** |
| Protocol name | `non_overlapping_2048_drop_remainder` |
| Attention implementation | `eager` |
| KV cache during PPL | `use_cache=False` |
| FP baseline dtype | `float16` |

對目前 tokenizer 產生的 WikiText-2 test sequence：

| Token 統計 | 數量 |
|---|---:|
| Source input tokens | 341,469 |
| Used input tokens | 339,968 |
| Dropped remainder | 1,501 |
| Evaluated blocks | 166 |
| Loss tokens per block | 2,047 |
| Total evaluated tokens | 339,802 |

計算關係：

```text
used_input_tokens = floor(341469 / 2048) * 2048
                  = 166 * 2048
                  = 339968

evaluated_tokens = 166 * (2048 - 1)
                 = 339802
```

每個 block 的第一個 token 沒有位於該 block 內的 previous token，因此 causal language modeling loss 實際計算 **2047** 個 target tokens。

## PPL 計算方式

每個 block 的 loss 必須依實際 loss token 數加權，最後再計算整體 mean NLL 與 PPL：

```python
loss = model(batch, labels=batch, use_cache=False).loss
loss_tokens = batch[:, 1:].numel()

total_nll += loss.float().item() * loss_tokens
total_loss_tokens += loss_tokens

mean_nll = total_nll / total_loss_tokens
perplexity = exp(mean_nll)
```

不要直接平均各 block 的 loss，除非可以確定每個 block 的有效 loss token 數完全相同。現在因為使用完整的 2048-token blocks，兩者數值會相同，但保留 token-weighted 寫法比較安全。

## 實測差異

| Model | 舊 overlap, stride 512 | 現行 non-overlap, stride 2048 |
|---|---:|---:|
| LLaMA2-7B FP16 | 4.859511 | **5.472103** |
| LLaMA2-13B FP16 | 4.350224 | **4.883702** |

13B 的兩次實驗使用相同 GPU 與主要套件版本，結果仍有相同方向的差距，進一步確認主要差異來自 evaluation protocol。

舊 overlap 結果目前保留在：

- `archive/results/overlap/llama2-7b/`
- `archive/results/overlap/llama2-13b/`

現行 non-overlap 結果位於：

- `results/ppl/baseline-bfp/llama2-7b/`
- `results/ppl/baseline-bfp/llama2-13b/`

## Notebook 中的防呆條件

現行 evaluator 應保留以下檢查：

```python
if stride != context_length:
    raise ValueError("Non-overlapping evaluation requires stride == context_length.")

if not drop_remainder:
    raise ValueError("Paper-compatible evaluation requires drop_remainder=True.")
```

這些條件可以避免未來只修改 **`stride`** 或 **`drop_remainder`**，卻仍把結果誤認為相同 protocol。

## 比較 Baseline、BFP 與 OB-Skip 的規則

同一張 PPL 表格內的所有結果必須一致使用：

- 相同 model checkpoint。
- 相同 tokenizer。
- 相同 WikiText-2 variant 與 split。
- 相同 text joining 方法。
- 相同 **`context_length`**。
- 相同 **`stride`**。
- 相同 remainder 處理方式。
- 相同 evaluated token 範圍。

BFP JSON 中的 **`baseline_perplexity`** 必須引用同一種 protocol 的 FP16 baseline。不能用 overlap baseline 計算 non-overlap BFP 的 **`delta_perplexity`**，反之亦然。

硬體、執行時間與 throughput 可以不同；只要數值運算設定沒有改變，GPU 型號本身通常不應造成這種幅度的 PPL 差距。不過套件版本、dtype、attention backend 與 TF32 設定仍應記錄在 JSON 中，方便追蹤 reproducibility。

## 每次執行前的檢查清單

1. 確認 **`CONTEXT_LENGTH == 2048`**。
2. 確認 **`STRIDE == CONTEXT_LENGTH`**。
3. 確認 **`DROP_REMAINDER is True`**。
4. 確認 dataset 為 `wikitext-2-raw-v1` 的 `test` split。
5. 確認 evaluator 沒有對 block 使用 sliding-window overlap。
6. 確認 JSON 包含 `evaluation_protocol`、`context_length`、`stride` 與 `drop_remainder`。
7. 確認 token 統計為 **166 blocks** 與 **339,802 evaluated tokens**。
8. 確認 BFP 或 OB-Skip 使用的 baseline PPL 來自相同 protocol。
9. 比較結果時讀取 JSON metadata，不要只相信檔名。
10. 若 PPL 突然接近舊值 4.86 或 4.35，優先檢查是否不小心恢復成 **`stride = 512`**。

## 最重要的結論

本專案對 WikiText-2 PPL 的正式比較一律採用 **non-overlapping 2048-token blocks、stride 2048、drop remainder**。Overlap 結果只保留作歷史紀錄，不應與目前的 FP16、BFP 或 OB-Skip 結果放在同一張比較表中。
