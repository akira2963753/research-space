# DEW_PE RTL Design Plan

> 文件狀態: Draft for design review  
> 版本: v0.5  
> 適用目錄: `research1/rtl/03_DEW-PE/01_RTL/`  
> 本版範圍: **RTL Design only**，不包含 Testbench、Assertion、Simulation、Synthesis 或其他 Verification 規劃。

## 1. 目的

本文件定義 `DEW_PE` 的初版 RTL architecture、module boundary、interface、data format、arithmetic rule 與 cycle-level control。實作會以現有 Baseline `BFP_PE` 為起點，保留其 Weight-Stationary dataflow 與 FP accumulation behavior，並加入以下功能:

1. Top-2 activation outlier index decoding。
2. 依架構圖修改的 routed Adder Tree。
3. 具有 asymmetric exponent window 的 `DEW_ACC`。
4. 24-bit fixed-width accumulation 與 overflow spill。
5. 單一 local `FP_ACC` 的 request scheduling。

本文件需先經過確認，之後才進入 RTL implementation。

## 2. 已確認的設計規格

### 2.1 固定的初版 design point

| 項目 | 初版設定 |
|---|---|
| Weight format | W-BFP4，G16，single shared exponent |
| Activation format | T2A-BiE4，G16，normal / outlier 各一個 shared exponent |
| Group size | **16 lanes** |
| Outlier 上限 | **2 lanes / block** |
| `T_SKIP` | **9** |
| `T_REPLACE` | **3** |
| `DEW_ACC_W` | **24 bits，包含 sign bit** |
| FP accumulator | **1 個 local FP32-like `FP_ACC`** |
| FIFO | **不實作** |
| Shared FP-Acc | **不實作跨 PE sharing** |

`DEW (9, 3)` 在本設計中明確表示:

```text
T_SKIP    = 9
T_REPLACE = 3
```

### 2.2 參考來源與優先順序

設計依據的優先順序如下:

1. 本次已確認的使用者規格。
2. [`architecture.pdf`](../../thesis/figures/architecture.pdf) 的 Outlier Dispatcher 與 Adder Tree。
3. `research1/docs/Process.md` 的 DEWA numerical contract。
4. Baseline `BFP_PE / INT_MAC / FP_ACC` RTL。
5. Bucket Getter 的 registered spill control pattern。

架構圖中的 `Shared FP-ACC` 是 system-level 方向；本次依指定改成每個 `DEW_PE` 內只有 **1 個 local FP_ACC**。Adder Tree 與 outlier routing 本身仍遵循架構圖。

## 3. 整體 Architecture

```mermaid
flowchart TD
    IN[Input block + OI1/OI2] --> OD[Outlier_Dispatcher]
    WR[Weight-Stationary registers] --> MAC[16 lane multipliers]
    OD --> MAC
    MAC[INT_MAC: multipliers + modified Adder Tree] -->|Normal partial P_N| DA[DEW_ACC 24-bit]
    MAC -->|Outlier 1 product| ARB[FP request selector]
    MAC -->|Outlier 2 product| ARB
    DA -->|Overflow spill / Final flush| ARB
    ARB --> FP[Local FP_ACC]
    FP --> OUT[FP result + out_valid]
```

核心資料流為:

1. Weight 先由 `weight_load` 寫入 Weight-Stationary registers。
2. 每個 accepted activation block 解碼 `oi1/oi2`，產生 normal lane 與兩個 outlier lane 的 routing control。
3. 16 個 lane 各做一次 mantissa multiplication；不為 outlier 額外複製 multiplier。
4. `INT_MAC` 內部的 modified Adder Tree 將 normal products 相加，並依 index 直接選出 `OP1/OP2`。
5. `P_N` 更新 `DEW_ACC`；outlier 與 DEW spill 經簡單 selector 依序送進單一 `FP_ACC`。

## 4. Top-Level Interface: `DEW_PE`

### 4.1 Interface 定義

| Port | Direction | Width | 語意 |
|---|---|---:|---|
| `clk` | input | 1 | Clock |
| `rst_n` | input | 1 | Active-low asynchronous reset |
| `acc_clear` | input | 1 | 清除目前 accumulation transaction，不清除 weight registers |
| `weight_load` | input | 1 | 載入 packed weight block 與 `w_exp` |
| `in_valid` | input | 1 | Input block valid |
| `in_ready` | output | 1 | PE 可接受 input block |
| `in_last` | input | 1 | 本 block 是目前 dot product 的最後一個 G16 block |
| `w_sign_b` | input | 16 | Packed weight signs |
| `w_man_b` | input | 48 | 16 × 3-bit weight magnitudes |
| `w_exp` | input | 5 | Weight shared exponent |
| `a_sign_b` | input | 16 | Packed activation signs |
| `a_man_b` | input | 48 | 16 × 3-bit activation magnitudes |
| `a_exp` | input | 5 | Normal activation shared exponent |
| `oa_exp` | input | 5 | Outlier activation shared exponent |
| `oi1` | input | 4 | Outlier index slot 1 |
| `oi2` | input | 4 | Outlier index slot 2 / count marker |
| `out_valid` | output | 1 | Final FP result valid |
| `out_ready` | input | 1 | Consumer 接受 final result |
| `o_sign` | output | 1 | FP result sign |
| `o_exp` | output | 8 | FP result exponent |
| `o_man` | output | 23 | FP result mantissa |
| `busy` | output | 1 | Transaction、pending request 或未取走 result 尚未結束 |

### 4.2 Handshake contract

Input transfer 只在以下條件成立時發生:

```text
input_fire = in_valid && in_ready
```

`in_valid=1` 但 `in_ready=0` 時，upstream 必須保持所有 input payload 與 `in_last` 不變。`out_valid=1` 但 `out_ready=0` 時，`o_sign/o_exp/o_man` 必須保持不變。

`weight_load` 延續 Baseline semantics: 同 cycle 的 input 使用舊的 registered weight，新 weight 從下一個 cycle 才可見。系統正常使用時應在新 transaction 開始前完成 `weight_load`。

## 5. Outlier Index Encoding 與 Routing Rule

### 5.1 Canonical encoding

```text
0 outlier : {oi1, oi2} = {4'b1111, 4'b1111}
1 outlier : {oi1, oi2} = {OI1,      4'b0000}
2 outlier : {oi1, oi2} = {OI1,      OI2}
```

`Outlier_Dispatcher` 不計算 `outlier_count`，只產生兩個簡單的 routing valid:

```text
no_outlier     = &(oi1 & oi2)  // 等價於 oi1==4'hF 且 oi2==4'hF
outlier1_valid = !no_outlier
outlier2_valid = !no_outlier && (oi2 != 4'h0)
```

也就是先判斷 `oi1` 與 `oi2` 是否同時為全 1；若成立，兩個 index 都不分配。否則 `oi1` 一律有效，而 `oi2=0` 時只忽略第二個 index，不加入其他 count decoder 或特殊狀態。

### 5.2 Encoding 的必要限制

因為 `oi2 = 4'h0` 代表「忽略 OI2」，input encoder 必須遵守:

1. `oi1 != oi2`。
2. two-outlier case 的 `oi2` 不可為 lane 0。
3. 若兩個 outlier 包含 lane 0，lane 0 必須放在 `oi1`。

RTL 不會修正或重新排序 index；`oi2=0` 時單純不配置 Outlier 2。

## 6. Module 分解

### 6.1 `DEW_PE.sv`: Top integration 與 control owner

責任如下:

1. 保存 Weight-Stationary registers。
2. 計算 normal / outlier block exponent。
3. 連接 Dispatcher、INT_MAC、DEW_ACC 與 FP_ACC。
4. 管理 local FP source selection 與單一 OP2 pending slot。
5. 產生 `in_ready/out_valid/busy`。

Exponent 計算沿用 Baseline:

```text
normal_blk_exp  = w_exp_reg + a_exp  - BFP_EXP_BIAS
outlier_blk_exp = w_exp_reg + oa_exp - BFP_EXP_BIAS
```

兩條 exponent path 都使用 signed `BFP_BEXP_W`，避免負 exponent 被 unsigned arithmetic 破壞。

### 6.2 `Outlier_Dispatcher.sv`: Simple index routing

現有 stub 檔名 `Outlier_Dispather.sv` 有拼字錯誤。正式實作預計更名為 `Outlier_Dispatcher.sv`，module name 同步使用 `Outlier_Dispatcher`。

此 module 不負責 exponent、mantissa、product 或 outlier count 計算，只依 `oi1/oi2` 決定 lane 應分配到 Normal、Outlier 1 或 Outlier 2。

Interface 保持精簡:

| Signal | Direction | 語意 |
|---|---|---|
| `oi1`, `oi2` | input | Encoded outlier indices |
| `normal_lane_en[15:0]` | output | Normal lane enable mask |
| `outlier1_valid`, `outlier2_valid` | output | 兩個 routing slot 的有效狀態 |

實際 routing rule 為:

```text
no_outlier = &(oi1 & oi2)
outlier1_valid = !no_outlier
outlier2_valid = !no_outlier && (oi2 != 4'h0)

normal_lane_en = 16'hFFFF
if (outlier1_valid) normal_lane_en[oi1] = 1'b0
if (outlier2_valid) normal_lane_en[oi2] = 1'b0
```

因此 `{4'hF,4'hF}` 時 `normal_lane_en=16'hFFFF`；`oi2=0` 時只把 `normal_lane_en[oi1]` 清為 0。`oi1/oi2` 本身直接送入 `INT_MAC` 做 indexed product selection，不再建立兩組 16-bit outlier one-hot mask。

Encoded outlier 的 mantissa 即使為 0，lane ownership 仍依 index 決定；Adder Tree 會將該 lane 從 Normal path 移除，而 Top 再依 product magnitude 是否為 0 決定要不要產生 FP request。

### 6.3 `INT_MAC.sv`: Multiplier array 與 modified Adder Tree

`INT_MAC` 由 Baseline 延伸，保留 16 個 shared lane multipliers:

```text
prod[i]  = w_man[i] * a_man[i]
sign[i]  = w_sign[i] XOR a_sign[i]
sprod[i] = sign[i] ? -prod[i] : prod[i]
```

Adder Tree 邏輯直接放在 `INT_MAC.sv`，不另外建立 `DEW_ADDER_TREE` module。內部先依 Dispatcher 的 `normal_lane_en` 將 outlier products 從 normal path 移除，再以 G16 固定的 4-stage balanced tree 相加:

```text
normal_prod[i] = normal_lane_en[i] ? sprod[i] : 0

stage1[0..7] = pairwise add normal_prod[0..15]
stage2[0..3] = pairwise add stage1[0..7]
stage3[0..1] = pairwise add stage2[0..3]
normal_sum    = stage3[0] + stage3[1]
```

`OP1/OP2` 不需要另一棵 Adder Tree。它們直接在同一段 `INT_MAC` stage logic 中，按照架構圖使用 `oi1/oi2` 的各級 index bit 控制 mux / bypass，最後選出對應 lane product。功能上等價於:

```text
op1 = outlier1_valid ? sprod[oi1] : 0
op2 = outlier2_valid ? sprod[oi2] : 0
```

RTL 會明確寫出架構圖中的 stage mux connection，不另外抽象成 recursive node、payload structure 或 child module。Normal path 只保留一棵 balanced Adder Tree。Stage width 依每層增加 1 bit:

```text
lane product = 7 bits signed
stage 1      = 8 bits signed
stage 2      = 9 bits signed
stage 3      = 10 bits signed
final sum    = 11 bits signed
```

`INT_MAC` 最後輸出三條 logically independent path:

| Output | Width | 語意 |
|---|---:|---|
| `normal_sign` | 1 | Normal partial sign |
| `normal_mag` | `BFP_MAG_W` | 所有 normal lanes 的 signed sum magnitude |
| `op1_sign/op1_mag` | 1 / `BFP_PROD_W` | `oi1` 指定 lane 的 product |
| `op2_sign/op2_mag` | 1 / `BFP_PROD_W` | `oi2` 指定 lane 的 product |
| `op1_valid/op2_valid` | 1 / 1 | 對應 outlier slot 是否 occupied |

`INT_MAC` 不做 exponent comparison，也不保存 accumulation state。

所有 add operation 都在 signed domain 進行，最後才將三個 outputs 轉為 sign-magnitude。`OP1/OP2` 的 magnitude 為原始 6-bit product。

### 6.4 `DEW_ACC.sv`: 24-bit Dynamic Exponent-Window Accumulator

`DEW_ACC` 保存以下 state:

| Register | Width | 用途 |
|---|---:|---|
| `acc_valid_reg` | 1 | Accumulator 是否非空 |
| `acc_value_reg` | `DEW_ACC_W=24` signed | Two's-complement integer accumulator |
| `acc_lsb_exp_reg` | `BFP_BEXP_W` signed | `acc_value_reg[0]` 對應的 exponent scale |
| `spill_valid_reg` | 1 | Registered FP request slot，供 overflow 或 final flush 共用 |
| `spill_sign/mag/exp_reg` | parameterized | 共用 spill payload |

`spill_valid_reg` 採 Bucket Getter 相同的一筆 registered spill 形式：產生 overflow 或 final flush 時寫入，直到 Top 以 `spill_ready` 接收後清除。它只是 DEW_ACC 的 output register，不是 FIFO。

`DEW_ACC_W` 包含 sign bit。正常可表示範圍為:

```text
-2^(DEW_ACC_W-1) ... 2^(DEW_ACC_W-1)-1
```

#### 6.5.1 Leading exponent

對非零輸入 normal partial:

```text
E_new = normal_blk_exp + floor(log2(normal_mag))
```

對非零 accumulator:

```text
E_acc = acc_lsb_exp_reg + floor(log2(abs(acc_value_reg)))
delta = E_new - E_acc
```

比較的必須是 **current numeric accumulator** 的 leading exponent。每次 addition 或 cancellation 後，都從更新後的 accumulator magnitude 重新取得 leading exponent；不保存 historical maximum exponent。

#### 6.5.2 Decision rule

```text
P_N == 0                     : HOLD
acc_valid == 0               : LOAD P_N
delta <= -T_SKIP             : SKIP_NEW
delta >= +T_REPLACE          : REPLACE_OLD
-T_SKIP < delta < T_REPLACE  : ALIGN_ADD
```

初版帶入 `(T_SKIP, T_REPLACE) = (9, 3)`:

```text
delta <= -9       : discard New
delta >= +3       : discard Old，accumulator 改為 New
-9 < delta < +3   : align and add
```

`REPLACE_OLD` 是 DEWA approximation policy；被取代的 old accumulator 不會送往 FP_ACC。

#### 6.5.3 Alignment rule

`acc_value_reg` 與 `P_N` 各自帶有 LSB exponent。進入 `ALIGN_ADD` 時:

```text
common_lsb_exp = max(acc_lsb_exp_reg, normal_blk_exp)
```

LSB exponent 較小的 operand 先對 magnitude 做 logical right shift，再恢復 sign，等效於 sign-magnitude truncation toward zero。之後將兩個 aligned signed values sign-extend 到 `DEW_ACC_W+1` 再相加。

這個規則避免對負數直接做 arithmetic right shift 所造成的 round-toward-negative-infinity 偏差，也與現有 Baseline `FP_ACC` 對較小 magnitude 的 truncation 方向一致。

#### 6.5.4 Overflow rule

所有 commit 前的 addition 都使用 `DEW_ACC_W+1` widened candidate:

```text
candidate = aligned_old + aligned_new
overflow  = candidate 超出 24-bit signed range
```

發生 overflow 時:

1. 不 commit wrapped 或 saturated 24-bit value。
2. 保存完整的 **25-bit candidate sign/magnitude** 與 `common_lsb_exp`。
3. 將 candidate 寫入共用 `spill_*_reg`，下一個 cycle assert `spill_valid` 並送入 `FP_ACC`。
4. 將 DEW accumulator 清成 invalid / zero，後續 normal partial 重新由 `LOAD` 開始。

因此一次 overflow request 代表「截至該 block 的完整 DEW integer subtotal」，不是只送 new partial，也不會造成 old value 被重複累加。

#### 6.5.5 Final flush rule

當 accepted block 同時帶有 `in_last=1`:

- 若本次沒有 overflow，將更新後的 nonzero `DEW_ACC` 寫入同一個 `spill_*_reg`。
- 若本次 overflow，overflow candidate 已包含最後一次 normal update，不再另外產生 final request。
- 若 final DEW value 為 0，不產生 FP request，但 normal path 仍回報完成。
- Final spill 被 FP_ACC 接收後，清除 DEW state。

最終結果只從 local `FP_ACC` 輸出，因此不需要額外的 FP adder 去合併 DEW output 與 exception output。

### 6.5 `FP_ACC.sv` 與 `BFP_PKG.sv`: Reuse boundary

下列 Baseline behavior 原封不動保留:

1. `FP_ADD` 的 exponent alignment、sign add/subtract 與 normalization。
2. 單一 `acc_reg` 的 update semantics。
3. `acc_clear` priority。
4. FP output format `1S / 8E / 23M`。
5. 既有的 truncation、underflow-to-zero 與 overflow saturation policy。

唯一需要 generalize 的部分是 `NORM` input width。Baseline 只接受 `BFP_MAG_W=10` 的 dot-product magnitude，但 DEW overflow candidate 可達 **25 bits**。因此 DEW 版本會使用 parameterized `FP_REQ_MAG_W = DEW_ACC_W + 1`:

```text
Outlier product : 6-bit magnitude  -> zero-extend to FP_REQ_MAG_W
DEW final value : 24-bit magnitude -> zero-extend to FP_REQ_MAG_W
Overflow value  : 25-bit magnitude -> direct use
```

`NORM` 的 leading-one detection 與 exponent correction 改以 `FP_REQ_MAG_W` 計算；`FP_ADD` 與 accumulator register 不重寫。這是為了讓同一個 FP_ACC 正確接收不同 fixed-point width，而不是更改 FP accumulation algorithm。

## 7. Local FP Request Selection

### 7.1 Request sources

單一 `FP_ACC` 共有四種 source:

| Source | 產生時機 | Exponent |
|---|---|---|
| `OP1` | accepted block 有第一個 nonzero outlier | `outlier_blk_exp` |
| `OP2` | accepted block 有第二個 nonzero outlier | `outlier_blk_exp` |
| `DEW_OVERFLOW` | 24-bit `ALIGN_ADD` overflow | `common_lsb_exp` |
| `DEW_FINAL` | `in_last` 後 normal accumulator 非零 | `acc_lsb_exp` |

Exception path 不做 exponent comparison。所有 occupied 且 product magnitude 非零的 outlier 都直接送往 FP_ACC。

### 7.2 不使用 FIFO 的實作方式

本設計不建立 queue、pointer、counter 或 request array，只保留兩個必要的 one-entry state:

- `DEW_ACC.spill_valid_reg` 與一組 `spill_sign/mag/exp`，overflow 和 final flush 共用。
- `op2_pending_reg` 與一組 OP2 payload，因為 accepted cycle 的 FP port 先給 OP1。

Top 另外只需要一個 `closing_reg` 記住已接受 `in_last`。只要 `spill_valid`、`op2_pending` 或 `closing` 尚未結束，`in_ready` 就拉低，因此 payload 不會被後續 block 覆蓋。

### 7.3 Arbitration priority 與固定順序

FP_ACC 每 cycle 最多接受一筆 request。順序固定為:

```text
1. DEW spill     // overflow 或 final flush 共用
2. OP2 pending
3. Current OP1  // 只會在 input_fire 且沒有舊 pending 時出現
```

`OP1` 在 input block 被 accepted 的同一個 active edge 送入 FP_ACC。`OP2` 因為只有一個 FP_ACC port，所以保存到下一個可用 cycle。

若同一個 block 同時產生 `OP1`、`OP2` 與 DEW spill，實際 FP order 固定為:

```text
accepted cycle : OP1
next cycle     : DEW spill
following      : OP2
```

Overflow 與 final flush 不建立兩套 arbitration；兩者都走同一個 registered spill port。如此 overflow 一定能在下一個 cycle 送入 FP_ACC，control 也只需固定 priority mux。

### 7.4 Cycle behavior 摘要

| Accepted block event | FP_ACC / stall behavior |
|---|---|
| 0 outlier，no overflow | 當 cycle 無 FP request；下一 cycle 可再收 input |
| 1 outlier，no overflow | 當 cycle送 OP1；下一 cycle 可再收 input |
| 2 outliers，no overflow | 當 cycle送 OP1；下一 cycle送 OP2 並 stall |
| Any overflow | overflow 後下一 cycle送 widened candidate 並 stall |
| `in_last` | 排空 OP2、overflow/final request 後才產生 `out_valid` |

Zero-magnitude request 不會觸發 `FP_ACC.in_valid`，但 corresponding control slot 仍會被視為已完成。

## 8. Control 與 Output Lifecycle

Top-level 不建立額外 processing FSM，只使用 `op2_pending_reg`、`closing_reg` 與 `out_valid_reg`；DEW request state 由 `DEW_ACC.spill_valid_reg` 自己保存。

`in_ready` 的基本條件:

```text
in_ready = !dew_spill_valid
        && !op2_pending
        && !closing
        && !out_valid
```

`busy` 在以下任一狀態為 1:

- DEW accumulator 已有有效 subtotal。
- `dew_spill_valid` 或 `op2_pending`。
- 已接受 `in_last` 且 transaction 正在 closing。
- `out_valid` 尚未被 `out_ready` 接收。

當最後一筆必要 FP request 在某個 rising edge 被 `FP_ACC` 接收，更新後的 FP accumulator output 於該 edge 後可見，同時 assert `out_valid`。Result handshake 完成後清除 `out_valid/closing`；下一筆 transaction 必須先由 `acc_clear` 建立乾淨 accumulator state。

## 9. Reset 與 Clear Priority

Sequential control priority 統一為:

```text
if (!rst_n)
    reset all state, including weight registers;
else if (acc_clear)
    clear DEW_ACC, FP_ACC, pending slots, closing and out_valid;
else
    perform normal handshakes and updates;
```

`acc_clear` 不清除 Weight-Stationary registers，與 Baseline PE 一致。`acc_clear` 發生時，尚未送出的 outlier、overflow 與 final request 全部取消。

## 10. Parameterization Plan

### 10.1 必須 parameterize

| Parameter | Default | 位置 |
|---|---:|---|
| `T_SKIP` | 9 | `DEW_PE`, `DEW_ACC` |
| `T_REPLACE` | 3 | `DEW_PE`, `DEW_ACC` |
| `DEW_ACC_W` | 24 | `DEW_PE`, `DEW_ACC`, FP request normalization |

`T_SKIP/T_REPLACE/DEW_ACC_W` 使用 module parameters，由 `DEW_PE` 往下傳遞，不使用散落的 magic numbers。

### 10.2 初版維持固定的項目

`BFP_GSIZE=16`、`BFP_EXP_W=5`、`BFP_MAN_W=3` 與 FP32-like output format 直接延續 Baseline global definition。本次 Adder Tree 明確實作為 G16 的 4 stages，不先加入 G32 或 arbitrary group-size abstraction。未來若改 group size，OI encoding 也必須一併重新定義。

Derived widths 集中定義:

```text
BFP_PROD_W     = 2 * BFP_MAN_W
BFP_SPROD_W    = BFP_PROD_W + 1
BFP_SUM_W      = BFP_SPROD_W + clog2(BFP_GSIZE)
FP_REQ_MAG_W   = DEW_ACC_W + 1
```

## 11. RTL File Plan

### 11.1 會實作或修改的檔案

| File | 規劃內容 |
|---|---|
| `DEW_PE.sv` | Top integration、Weight-Stationary registers、FP source selection、handshake |
| `Outlier_Dispatcher.sv` | OI valid decode 與 normal lane mask |
| `INT_MAC.sv` | 16 lane multipliers、4-stage Adder Tree、OP1/OP2 indexed selection |
| `DEW_ACC.sv` | 24-bit window decision、alignment、overflow、final flush |
| `FP_ACC.sv` | Baseline FP accumulator，僅 generalize fixed-point input width |
| `BFP_PKG.sv` | Generic LOD / fixed-to-FP normalization helper，保留 `FP_ADD` |
| `include.vh` | 集中 format 與 derived width definitions |

現有空白 `INT_ACC.sv` 不放入 active hierarchy；fixed-width state 全部由 `DEW_ACC` 擁有。

### 11.2 Module hierarchy

```text
DEW_PE
|-- Outlier_Dispatcher
|-- INT_MAC
|-- DEW_ACC
`-- FP_ACC
    `-- BFP_PKG functions
```

### 11.3 Maintainability constraints

- 不建立獨立 `DEW_ADDER_TREE` module；所有 multiplier、mux 與 adder stages 都留在 `INT_MAC.sv`。
- 不建立獨立 Arbiter module；FP source selection 留在 `DEW_PE.sv` 的一個 `always_comb`。
- 不建立 FIFO、request array、pointer、counter 或通用 scheduler framework。
- `DEW_ACC` 只保留一份 accumulator state 與一個共用 spill register。
- G16 Adder Tree 使用清楚的固定 4-stage signal naming，不為尚未要求的 G32 建立 recursive abstraction。

## 12. Implementation Sequence

### Phase 1: Freeze data contract

- 整理 `include.vh` 的 format 與 derived widths。
- 修正 Dispatcher 檔名與 module name。
- 固定 `{4'hF,4'hF}` bypass、`oi2=0` ignore 與 lane-0 canonical ordering。
- 固定 FP request payload 的 sign / magnitude / LSB exponent semantics。

### Phase 2: Build integer datapath

- 實作 `Outlier_Dispatcher`。
- 在 `INT_MAC.sv` 內實作 16-lane multiplier array。
- 在同一個 `INT_MAC.sv` 內實作 4-stage balanced Adder Tree。
- 直接以 `oi1/oi2` 選出 OP1、OP2 products。

### Phase 3: Build accumulation datapath

- 實作 `DEW_ACC` state、LOD、threshold decision 與 alignment。
- 實作 25-bit candidate 與 pre-commit overflow detection。
- 實作 overflow / final 共用的 registered spill port。
- Generalize FP input normalization，保留 Baseline `FP_ADD` core。

### Phase 4: Integrate top-level control

- 實作 direct OP1、pending OP2 與 DEW spill priority mux。
- 只使用 `op2_pending/closing/out_valid` control flags。
- 完成 `in_ready/out_valid/out_ready/busy` semantics。
- 移除 active hierarchy 中未使用的 stub connection 與 duplicate state。

## 13. 需要在 RTL 開始前核准的設計決策

以下是本 plan 已採用、但希望在開始寫 RTL 前由 reviewer 明確核准的三點:

1. **24-bit DEW_ACC width 包含 sign bit**。
2. Overflow 時送往 FP_ACC 的是 **25-bit full candidate sum**，送出後 DEW state 清空。
3. 單一 FP_ACC 的 request order 採 `OP1 -> DEW spill(next cycle) -> OP2`；overflow 與 final flush 共用同一個 spill port。

若以上三點維持不變，後續 RTL implementation 可以直接依本文件進行，不需要再補一層 FIFO 或 shared-FP-ACC protocol。
