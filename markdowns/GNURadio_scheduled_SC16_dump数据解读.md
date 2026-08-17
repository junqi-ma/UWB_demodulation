---
tags:
  - uwb
  - qm35
  - sc16
  - scheduled-dump
aliases:
  - scheduled SC16 dump
  - capture.iq
  - QM35 截窗格式
date: 2026-08-14
---

# GNU Radio scheduled SC16 dump 数据解读

GNU Radio 锁定 QM35 之后，按 5 ms 周期把每个雷达 slot **原样截窗**写盘。磁盘上是 **737.28 MS/s 的 SC16**，没有 65/48，也没有 CF32 再量化。

当前两份 dump：

```text
F:\UWB基带数据\qm35_scheduled_sc16_dump\         mixed，100 窗
F:\UWB基带数据\qm35_clean_scheduled_sc16_dump\   无干扰 QM35，99 窗
  capture.iq
  capture.jsonl
```

mixed 来自 `dw1000_qm35_mixed_*737p28*0p5s*`；clean 来自
`qm35_6489p6MHz_737p28Msps_0p5s_sc16_20260811_01.dat`。都是盲 t0 锁定后
EverySlot 落盘，再逐窗消单音覆盖 `capture.iq`。clean 比 mixed 少 1 窗，因为
首包更晚（约 4.80 ms），最后一个 300/190/100 µs 窗超出 0.5 s 文件末尾被丢掉。

入口脚本：[[#MATLAB 怎么读]] · 仓库函数 `decode_scheduled_sc16_dump.m` ·
运行 `run_decode_scheduled_sc16_dump.m`，改 `dumpDir` 切换 mixed / 无干扰。  
C++ 对照与 Codex 修 MATLAB：[[CODEX_scheduled_dump_MATLAB对照手册]]。

保存后去单音：`testdata/cancel_capture_tone.py DUMP` 或 MATLAB `run_cancel_capture_tone`。  
约 6200 MHz 的 CW 实测在 **RF 6256.640 MHz**（基带 −232.960 MHz）。逐窗减去后**直接覆盖 `capture.iq`**，不保留未去单音副本。jsonl 不变。

解调算法仍见 [[README_解调代码说明]]。dump 只负责把窗和坐标留下来。

---

## 两个文件各自干什么

| 文件 | 角色 |
|---|---|
| `capture.iq` | 所有窗的 IQ **首尾相接**，无文件头、无分隔符 |
| `capture.jsonl` | 一行一个 JSON，描述这一窗在 `capture.iq` 里的位置，以及在原始连续流里的坐标 |

不是整段 0.5 s 连续采集的再封装。每个雷达 slot 只切一小段（约 0.6～0.8 ms），中间 5 ms 空隙丢弃。

```
原始连续流 @737.28 MS/s
     |----5 ms----|----5 ms----|----5 ms----|
          [窗0]         [窗1]         [窗2]
            \             |             /
             \            |            /
              +-- 拼进 capture.iq --+
```

---

## `capture.iq`：二进制

- 小端序（little-endian）
- 交错 **int16 I/Q**：`I0, Q0, I1, Q1, …`
- 1 个复样点 = **4 字节**
- `sample_format = "sc16"`
- `iq_scale = 32768`（这份 dump 是原生 SC16 直写，没有按峰再缩放）

还原成复基带：

```matlab
x = (double(I) + 1i * double(Q)) / meta.iq_scale;
```

第 `k` 个窗：

```text
字节偏移 = file_offset_samples × 4
字节长度 = sample_count × 4
```

核对：`capture.iq` 大小 = 231 705 932 字节。  
`sum(sample_count) × 4` 应等于该值。

---

## `capture.jsonl`：每行一个窗

100 行，对应 100 个 `packet_id`（0…99）。字段如下。

### 文件内寻址

| 字段 | 含义 |
|---|---|
| `packet_id` | dump 内序号，从 0 起 |
| `file_offset_samples` | 本窗在 `capture.iq` 中从第几个**复样点**开始 |
| `sample_count` | 本窗复样点数 |
| `sample_format` | `"sc16"` |
| `iq_scale` | 32768 |
| `sample_rate` | **737280000**（不是 998.4e6） |

### 原始连续流坐标（0-based）

| 字段 | 含义 |
|---|---|
| `window_start_sample` | 窗左端在原始 `.dat` 流中的样点 |
| `predicted_start_sample` | 预测的 QM35 前导起点 |
| `start_sample` / `trigger_sample` | 与 Writer 兼容的别名；锁定后一般等于 `predicted_start_sample` |
| `schedule_index` | 雷达周期编号 `k`（`t0 + kT`）。acquisition 行没有这项 |

### 窗几何

| 字段 | 含义 |
|---|---|
| `pre_guard_samples` | 头：QM35 起点之前 |
| `capture_samples` | 体：QM35 包 |
| `post_guard_samples` | 尾：QM35 体之后 |
| `pre_trigger_samples` | 实际头长；未被夹到 0 时等于 `pre_guard` |

关系（未被文件头夹断时）：

```text
sample_count = pre + body + post
predicted_start = window_start + pre
```

### 状态

| 字段 | 取值 |
|---|---|
| `capture_mode` | `acquisition` / `provisional` / `scheduled` |
| `lock_state` | `candidate_verify` / `provisional` / `locked` |
| `detection_metric` | 仅 acquisition 有意义（code-9 细相关） |

---

## 窗里三段怎么切

对读出的向量 `x`（长度 `sample_count`，MATLAB 1-based）：

```text
head = x(1 : pre)
qm35 = x(pre+1 : pre+body)
tail = x(pre+body+1 : end)
```

```
|<---------- sample_count ---------->|
[######## head ########|==== QM35 ====|#### tail ####]
                       ^
                 predicted_start
                 （x 的第 pre+1 个点）
```

- **head**：起点在雷达之前、仍可能压在 QM35 前导上的 DW1000。CIR 干扰主要发生在前导，所以头要留整条 DW1000（约 300 µs）。
- **body**：QM35 本身，约 190 µs。
- **tail**：收完从 t0 起算的那条 DW1000。当前生产默认 100 µs；**这份拷贝是缩短尾部之前的 300 µs**。

### 这份数据的实际几何

| `capture_mode` | pre | body | post | 合计 | 说明 |
|---|---:|---:|---:|---:|---|
| `acquisition`（id=0） | 2032 | 188074 | 0 | 190106 | 能量门首包，几乎没有头尾 |
| `provisional` | 239616 | 140083 | 239616 | 619315 | 锁定前两侧各 +25 µs |
| `scheduled`（locked） | 221184 | 140083 | 221184 | 582451 | 300 + 190 + 300 µs |

时间换算：`samples / 737.28e6`。  
`221184 / 737.28e6 = 300 µs`。

---

## 和原始 mixed 文件的关系

`window_start_sample` 指向：

```text
F:\UWB基带数据\dw1000_qm35_mixed_6489p6MHz_737p28Msps_0p5s_sc16_20260811_01.dat
```

同一套 SC16 排布。落盘时按字节拷贝，锁定后 scheduled 窗应与源流逐样本一致。

不要把 `capture.iq` 当成从 t=0 开始的连续 0.5 s。中间空隙已经丢掉。要把某一窗对回射频时间：

```matlab
t0_s = double(meta.window_start_sample) / meta.sample_rate;
t_pred_s = double(meta.predicted_start_sample) / meta.sample_rate;
```

首个确认包约在 **2.292 ms**（`start_sample ≈ 1 690 126`）。周期 **T = 5 ms**。

---

## MATLAB 怎么读

读一窗：

```matlab
dump = 'F:\UWB基带数据\qm35_scheduled_sc16_dump';
[x, meta] = read_uwb_packet( ...
    fullfile(dump,'capture.iq'), ...
    fullfile(dump,'capture.jsonl'), 3);   % packet_id

pre  = meta.pre_guard_samples;
body = meta.capture_samples;
head = x(1:pre);
qm35 = x(pre+1 : pre+body);
tail = x(pre+body+1 : end);
```

整目录解调 QM35（65/48 + `decode_uwb`，code 9 / 64 / 4z2）。
mixed / 无干扰共用 `run_decode_scheduled_sc16_dump.m`，只改 `dumpDir`：

```matlab
dumpDir = 'F:\UWB基带数据\qm35_scheduled_sc16_dump';        % mixed
% dumpDir = 'F:\UWB基带数据\qm35_clean_scheduled_sc16_dump'; % 无干扰
cd('F:\USRP数据解调')
run_decode_scheduled_sc16_dump
```

结果按 dump 路径分开：

```text
decoded_results\scheduled_sc16_dump\              mixed
decoded_results\scheduled_sc16_dump_qm35_clean\   无干扰
  scheduled_dump_matlab.csv
  scheduled_dump_matlab.mat
```

工作区变量 `results`。种子约定与 GNU Radio 一致：

```text
seededStartOne = round(pre * 65/48) + 1
```

即在 998.4 域对准 `predicted_start`。

---

## 不要搞混的几件事

1. **磁盘采样率是 737.28 MHz**。`decode_uwb` 要 998.4 MHz，由脚本做 65/48，不要对 `capture.iq` 再预重采样一遍。
2. **`start_sample` 不是 `capture.iq` 的偏移**。文件内偏移是 `file_offset_samples`。
3. **acquisition 和 scheduled 几何不同**。不要用 221184 去切 id=0。
4. **这份 dump 的尾仍是 300 µs**。当前代码默认尾已改为 100 µs（73728），新采的数据会更短。
5. dump **不解 DW1000**。头尾只是把干扰 IQ 留下；要解干扰再对整窗跑 code 10 / 256 / decawave。

---

## 相关

- 函数：`read_uwb_packet.m`、`decode_scheduled_sc16_dump.m`
- 入口：`run_decode_scheduled_sc16_dump.m`
- 算法：[[README_解调代码说明]]、[[精确样本定位接口]]
- 仓库：`UWB_demodulation` 分支 `acceleration`
