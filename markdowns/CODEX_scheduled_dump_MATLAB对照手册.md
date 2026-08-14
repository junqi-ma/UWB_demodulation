---
tags:
  - codex
  - qm35
  - scheduled-dump
  - matlab
aliases:
  - Codex dump handbook
  - C++ vs MATLAB scheduled dump
date: 2026-08-14
---

# Codex 手册：scheduled SC16 dump 上对齐 MATLAB 与 C++ QM35 解调

给在 `F:\USRP数据解调`（仓库 `UWB_demodulation`，分支 `acceleration`）里改 MATLAB 的 Codex / 代理用。目标：**同一份 GNU Radio dump 上，MATLAB `decode_uwb` 应达到与 C++ 相同的 QM35 FCS**。

相关笔记：[[GNURadio_scheduled_SC16_dump数据解读]] · [[README_解调代码说明]] · [[精确样本定位接口]]

---

## 1. 现状（2026-08-14）

同一目录、同一 100 个窗：

| 解码器 | 文件 | FCS |
|---|---|---:|
| C++ `UwbRealtimeDemodulator` | `decoded_results/scheduled_sc16_dump/scheduled_dump_cpp.csv` | **100/100** |
| MATLAB `decode_uwb` | `decoded_results/scheduled_sc16_dump/scheduled_dump_matlab.csv` | **24/100** |

MATLAB 失败形态（不要当成“没有信号”）：

| `qm35_status` | 个数 | 含义 |
|---|---:|---|
| `success` | 24 | FCS 过 |
| `phr_failed` | 37 | 定时往往还能找到 64 峰，PHR 崩 |
| `fcs_or_payload_failed` | 37 | PHR SECDED 过，载荷/FCS 错 |
| `decode_error` | 2 | 脚本/异常 |

反例（id=3）：

| | C++ | MATLAB |
|---|---|---|
| status | `success` FCS=1 | `phr_failed` FCS=0 |
| `qm35_det_minus_pred` | **+73** | **-174730** |
| CFO Hz | +1587 | -2447 |
| payload | `2D00003200000000090004E8…` | 空 |

`-174730` 样点 @998.4 MHz ≈ **-175 µs**，正好落在 **300 µs 的 head** 里。MATLAB 很大概率在头里的 DW1000 能量上锁错了起点，而不是用 seed 钉在 QM35 `predicted_start`。

C++ 的 `det_minus_pred` 整文件都在大约 **+70～+300** 样点（约 0.07～0.3 µs 量级的锁定残差），没有 1e5 这种跳变。

---

## 2. 文件在哪

### 输入 dump（不要改）

```text
F:\UWB基带数据\qm35_scheduled_sc16_dump\
  capture.iq      原生 SC16 @737.28 MS/s，窗首尾相接
  capture.jsonl   100 行，每窗一行
```

格式见 [[GNURadio_scheduled_SC16_dump数据解读]]。

### 对照结果（C++ 为真值）

```text
F:\USRP数据解调\decoded_results\scheduled_sc16_dump\
  scheduled_dump_cpp.csv              C++ 逐窗结果（真值）
  scheduled_dump_cpp_summary.json     配置摘要
  scheduled_dump_matlab.csv           当前 MATLAB 逐窗结果
  scheduled_dump_matlab.mat
```

`decoded_results/` 被 `.gitignore` 忽略，只存在本机。

C++ 结果由仓库外脚本生成：

```text
uwb-gnuradio/testdata/decode_scheduled_sc16_dump.py
```

链路：读 dump PDU → `UwbPduRationalResamplerCcf65_48`（`quality_minorder`）→ `UwbRealtimeDemodulator`（code 9 / 64 SYNC / 4z2 / CIR bypass）。

---

## 3. C++ CSV 列（`scheduled_dump_cpp.csv`）

按 `packet_id` 与 MATLAB 表 join。

| 列 | 域 | 说明 |
|---|---|---|
| `decoder` | — | 恒为 `gnuradio_cpp` |
| `packet_id` | dump | 0…99，与 jsonl 一致 |
| `schedule_index` | native | 雷达 k；acquisition 为 -1 |
| `capture_mode` | — | `acquisition` / `provisional` / `scheduled` |
| `window_start_native` | 737.28 | 窗左端，原始连续流 0-based |
| `predicted_start_native` | 737.28 | QM35 预测前导起点 |
| `pre_samples` / `body_samples` / `post_samples` | 737.28 | 头 / 体 / 尾 |
| `qm35_status` | — | C++ 应为 `success` |
| `qm35_fcs_pass` | — | 1/0 |
| `qm35_detected_start` | **998.4 绝对** | 重采样后 PDU 坐标系里的检出起点 |
| `qm35_predicted_start_out` | **998.4 绝对** | 映射后的预测起点 |
| `qm35_det_minus_pred` | 998.4 | `detected - predicted`，正常约 +70…+300 |
| `qm35_timing_peaks` | — | QM35 应为 **64** |
| `qm35_cfo_hz` | — | 约 +1.1～+2.3 kHz |
| `qm35_payload_hex` | — | 大写 hex，无空格 |
| `qm35_sfd_metric` | — | C++ SFD 相关 |

**载荷真值（本 dump 全部 100 窗相同前缀）：**

```text
2D00003200000000090004E8
```

C++ 行里后面还有 PHR/PSDU 余下字节。对照时至少比前 12 字节。

---

## 4. MATLAB 必须遵守的契约

`decode_scheduled_sc16_dump.m` 已经按窗做了这些事。改 `decode_uwb` / `detectRepeatedPreamble` 时**不要破坏**它们。

1. **每个 jsonl 行是一个独立窗**，不是连续 0.5 s 文件。禁止对 `capture.iq` 做全文件 energy scan。
2. IQ 是 **int16 SC16 @737.28e6**。先 `upfirdn(x737, taps, 65, 48)`，taps 必须是  
   `testdata/resampler_65_48/taps_quality_minorder.txt`（与 C++ `quality_minorder` 相同）。
3. **种子（1-based，在 998.4 窗内）：**
   ```matlab
   seededStartOne = round(pre * 65/48) + 1;
   result = decode_uwb(opt, x998, [], ref, 'single', seededStartOne);
   ```
   `pre` 用 `pre_trigger_samples`（若无则 `pre_guard_samples`）。
4. PHY：**code 9、64 SYNC、`sfd_mode='4z2'`、6.81 Mbps**。不要用 DW1000 默认（code 10 / 256 / decawave）。
5. 窗里 **head 有密集 DW1000**。seed 失败后若回退全窗搜索，会锁到 head 里的干扰（见 id=3 的 -174730）。
6. `acquisition` 几何是 `2032 / 188074 / 0`，**不是** 221184/140083/221184。
7. 坐标：`window_start_*` / `predicted_start_native` 在 737.28；`*_out` / C++ `qm35_detected_start` 在 998.4。禁止混用。

映射（与 `analyze_qm35_sc16_matlab.m` 相同）：

```matlab
filterDelay = (numel(taps)-1)/2;
abs998 = round((native737 * 65 + filterDelay) / 48);
```

---

## 5. 建议的对照代码

```matlab
resDir = fullfile(pwd, 'decoded_results', 'scheduled_sc16_dump');
cpp = readtable(fullfile(resDir, 'scheduled_dump_cpp.csv'));
ml  = readtable(fullfile(resDir, 'scheduled_dump_matlab.csv'));
J = innerjoin(cpp, ml, 'Keys', 'packet_id');

fcs_cpp = J.qm35_fcs_pass_cpp;   % 若 join 重名，看 readtable 后缀
% 若列名冲突，改用：
% cpp.Properties.VariableNames = strcat('c_', string(cpp.Properties.VariableNames));

mismatch = J.packet_id(J.qm35_fcs_pass_cpp ~= J.qm35_fcs_pass_ml);
fprintf('FCS mismatch packet_id = %s\n', mat2str(mismatch(:).'));
```

逐窗验收（相对 C++）：

- `qm35_fcs_pass` 相同
- `qm35_payload_hex` 前 24 个 hex 字符相同
- `|qm35_det_minus_pred|` 应是几百样点量级，不能是 1e5
- `qm35_timing_peaks == 64`

先修 **seed 被丢掉 / 全窗误锁 head**，再抠 CIR/Viterbi。证据：失败窗常常仍报 64 个峰，但 `det_minus_pred` 已经偏了一个 DW1000 那么远。

---

## 6. 调试顺序（给 Codex）

1. 读 `scheduled_dump_cpp.csv` id=3 与 MATLAB 同行，确认 `predicted_start_native` 一致。
2. 用 `read_uwb_packet` 取出该窗，检查 `seededStartOne` 是否落在 QM35 体而不是 head。
3. 在 `detectRepeatedPreamble` 里打印 seed 路径是否成功、是否 fallback 全搜索。
4. **有合法 seed 时禁止全窗 argmax。** 只允许在 seed 附近（C++ 量级：数百～数千 998.4 样点）搜索。
5. 修完后重跑 `run_decode_scheduled_sc16_dump`，覆盖 `scheduled_dump_matlab.csv`，再和 C++ 表 join。目标：**FCS ≥ 95/100**，再追求 100/100。
6. 不要为了对齐去改 dump，也不要把 C++ 的 998.4 检出点直接当 737.28 索引去切 `capture.iq`。

---

## 7. 不要做的事

- 不要对 dump 跑 `decode_uwb_all` 的能量门全文件扫描。
- 不要换 taps（`realtime` ≠ `quality_minorder`）。
- 不要把 int16 再除一次 32768 之后又按另一套归一化（C++ PDU 路径对 SC16 用 `float(I), float(Q)` 进 FIR；MATLAB `analyze_qm35_sc16_matlab` 同样是 `int16=>single` **不再除 32768**）。`decode_scheduled_sc16_dump.m` 已按此读。
- 不要用 code 10 模板解 QM35。
- 不要把 24 个 FCS 当成“只有 24 个雷达包”。C++ 证明 100 个窗里都有可解 QM35。

---

## 8. 相关源码

| 角色 | 路径 |
|---|---|
| MATLAB 入口 | `F:\USRP数据解调\run_decode_scheduled_sc16_dump.m` |
| MATLAB 解析+解调 | `decode_scheduled_sc16_dump.m` |
| MATLAB 读一窗 | `read_uwb_packet.m` |
| MATLAB 核心 | `decode_uwb.m`、`+uwbdecoder/detectRepeatedPreamble.m` |
| C++ 生成脚本 | `uwb-gnuradio/testdata/decode_scheduled_sc16_dump.py` |
| C++ 解调 | `gr-uwb` `UwbRealtimeDemodulator` + PDU 65/48 |
| 格式说明 | [[GNURadio_scheduled_SC16_dump数据解读]] |
