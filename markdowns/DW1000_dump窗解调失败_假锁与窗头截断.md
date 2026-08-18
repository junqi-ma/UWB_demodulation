# dump 窗里 DW1000 解调失败：假锁与窗头截断

| 字段 | 值 |
|---|---|
| Date | 2026-08-17 |
| Status | 分析结论（已用 SIC 产物 + 种子复检核对） |
| Branch | `gnuradio-scheduled-dump` |
| 数据 | `F:\UWB基带数据\qm35_gain1_scheduled_sc16_dump_20260817` |
| 产物 | `decoded_results/qm35_gain1_scheduled_sc16_dump_20260817/sic_dw1000_removed_qm35_preserved/` |
| 不在本文范围 | packet 47 消除对齐 0.691&lt;0.700；改 `min_alignment_correlation`；改 v2 预径簇选窗 |

v2 预径簇检测器已经把 SIC 入口扩到 68 个 `interfered` 窗。本文只回答：这 68 窗里，**DW1000 为什么有 16 帧 FCS 失败**。结论不是随机误码，而是搜索策略加上窗几何。

相关入口：

- 失败表：`sic_dw1000_removed_qm35_preserved/dw1000_decode_failures.csv`
- 复现分类 / pkt 24 种子复检：`analyze_dump_dw1000_decode_failures.m`
- 整窗原始 I/Q + 两类标注：`visualize_qm35_cir_interference.m`（改 `packet_index`）
- 选窗设计：[[QM35_CIR预径簇检测器_v2]]（明确把 DW 解不出排除在选窗器之外）

---

## 1. 现象

`scheduledDumpSicPipeline` 对 68 个窗做：解 QM35 → 消 QM35 → **无种子**解 DW1000 → 若 FCS 过再消 DW。汇总：

| 量 | 值 |
|---|---|
| 处理窗 | 68 |
| DW 检出（`decode_ok`） | 68 |
| DW FCS 通过 | 52 |
| DW FCS 失败 | **16** |
| SIC 实际施加（消 DW） | 51 |
| packet 47 | FCS 通过，消除因对齐相关 0.691&lt;0.700 被拒（不是解调失败） |

成功帧高度一致：

- `start_sample` 在窗中后段，9174–275417（中位数 145642）
- PHR SECDED 通过，**PSDU 恒为 12 字节**
- 载荷同一族 blink：`6188..F2F00200010000....`
- CFO 聚在约 −1750 Hz
- 配置是 `dw1000_code10_n256` / Decawave DW-8

失败帧也高度一致，但和成功帧完全不是一类东西：

- `start_sample` **全部**锁在窗头 27–969（中位数 498）
- PSDU 长度乱七八糟（9–121），没有一帧是 12
- 10/16 PHR SECDED 直接失败；另外 6 帧 PHR 碰巧过了，长度仍不可信
- CFO 两极：一部分仍在 −1800 Hz 附近（残尾里还有真 SYNC），一部分到 +9.7 kHz / −18.5 kHz

`detected_repetitions` 成功/失败都常报 64，不能当“真实 SYNC 个数”读。峰跟踪上限是

```text
maxPeaks = min(preamble_repetitions, max(64, cir_repetitions))
        = min(256, 64) = 64
```

成功帧真正有 256 个 SYNC；64 只是跟踪截断。

---

## 2. 窗几何与 DW1000 格子

dump 窗按 QM35 切：native 434995 点 @ 737.28 MHz，65/48 升到约 **589056 点 / 590 μs** @ 998.4 MHz。预守卫大约 300 μs，QM35 起点通常在窗内 ~300 μs。

| 量 | 样点 @ 998.4 MHz | 时间 |
|---|---|---|
| 一枚 SYNC | 1016 | 1.018 μs |
| DW1000 256 SYNC | 260096 | 260.6 μs |
| SHR（256 SYNC + 8 SFD） | 268224 | 268.7 μs |
| 本窗还能放下完整 SHR 的最晚起点 | 320832 | 321.3 μs |
| QM35 64 SYNC | 65024 | 65.1 μs |

成功 DW 的绝对起点按 5.1333 ms 一格走动，20.020 ms 为一个大周期（两路相差 14.8867 ms）。QM35 排程是 5.000 ms。两个周期差约 133 μs / 5 ms，所以 **DW 在 QM35 窗里的位置一直在走**：有时整包落在窗中，有时只剩窗头残尾，有时后段包贴着窗尾、SFD 已经出窗。

成功载荷序列号连续递增，是同一台 DW1000，不是两套 PHY。

---

## 3. 两类失败

16 帧按 5.133 ms 格子回推后，分成两类。每一类窗头都有上一包 DW 的 SYNC 残尾；差别在于**本窗后段还有没有一个 SHR 能放下的真包**。

### 3.1 假锁：后面还有完整包（7）

`1, 24, 28, 51, 55, 74, 78`

检测器锁在窗头（红），但格子在 282k–315k（约 282–316 μs）给出一个 SHR 仍装得下的起点（绿）。这个位置紧挨 QM35（~300 μs）。

| packet | 锁点 | 后段真包起点 | PHR | 乱 PSDU |
|---|---|---|---|---|
| 1 | 793 | 302017 | 否 | 22 |
| 24 | 720 | 288617 | 否 | 36 |
| 28 | 373 | 308617 | 否 | 92 |
| 51 | 300 | 295417 | 是 | 107 |
| 55 | 969 | 315417 | 否 | 121 |
| 74 | 227 | 282017 | 是 | 46 |
| 78 | 896 | 302017 | 否 | 25 |

pkt 24 复检（先消 QM35，再解 DW）：

| 搜索 | 结果 |
|---|---|
| 无种子（与 SIC 相同） | `start=720`，41 个峰 |
| 种子 288696 | `start=288696`，**256 个峰** |

后段确实有完整 256 SYNC。SIC 的 `decodeDw1000OnWindow` 传空种子，自适应检测器按「最早包优先」在窗头 32+ 峰处提交，后面再也不看。

有种子的整包解调仍报 `ternarySymbols is too short: need samples 144865:154080`。真包靠窗尾，256 SYNC 之后 PHR/载荷已经贴边；即便改搜索，这 7 帧也不保证全部 FCS 能过，但至少能对准真包。

### 3.2 窗头截断：本窗装不下完整包（9）

`5, 9, 32, 36, 59, 63, 82, 86, 90`

上一包 DW 起点在窗外 150k–230k 样点（约 150–231 μs 之前）。256 SYNC 只有尾巴伸进本窗，检测器锁在 27–873，解出的是残段。这 9 帧后段往往还有下一包，但起点 ≥322k，**SFD 已经出窗**（最晚合法起点 320832）。

| packet | 锁点 | 上一包相对窗起点 | 后包起点（SFD 出窗） |
|---|---|---|---|
| 5 | 446 | −190583 | 322017 |
| 9 | 100 | −170583 | 342017 |
| 32 | 27 | −183783 | 328617 |
| 36 | 696 | −163783 | 348617 |
| 59 | 623 | −177183 | 335417 |
| 63 | 276 | −157183 | 355217 |
| 82 | 550 | −190383 | 322017 |
| 86 | 203 | −170383 | 342017 |
| 90 | 873 | −150583 | 362017 |

pkt 5 无种子复检：`start=446`，64 个峰，与截断残尾一致。当前 590 μs 窗救不回这类帧。

---

## 4. 根因

不是 QM35 没消干净，也不是 code 10 / Decawave SFD 配错。成功 52 帧已经证明同一套 PHY 能解。

直接原因在搜索：

```174:194:scheduledDumpSicPipeline.m
function [decoded, profile] = decodeDw1000OnWindow(x, profiles)
    ...
        candidate = decode_uwb(..., 'single', [], true);   % 空种子
```

```148:151:+uwbdecoder/detectRepeatedPreamble.m
    % 单包解码沿用原有“最早包优先”语义；多包保留由 decode_uwb_all 负责。
    if candidatePreamble.detected_repetitions >= 32
        preamble = candidatePreamble;
        return;
```

窗头几乎总有上一包 DW 的 SYNC 残尾（5.133 ms 对 5.000 ms 走动的必然结果）。残尾能凑出 ≥32 个峰，检测器就停。SFD 按配置的 256 符号去搜：`start + 256×1016 ≈ 260 k`，落在窗中后段的噪声或 QM35 残差上，PHR/FCS 必然是垃圾。

CIR 预径簇 N≥5 只说明「QM35 SYNC 里有 DW 能量」，不保证本窗里有一个完整、可解的 DW 帧。假锁那 7 帧 N 仍然很高（多数 51–54），因为后段真包确实压在 QM35 上；窗头截断那 9 帧 N 从 7 到 46 都有，早期能量来自残尾或出窗后包的一部分。

---

## 5. 和 packet 47 的区别

packet 47：**解调成功**（FCS=1，start=275417，12 字节），消除因

```text
Fractional alignment correlation 0.691 is below 0.700
```

被拒。那是 `cancel_uwb_packet_in_iq` 的对齐门限，不是本文的解调失败。不要和 16 帧混在一起改。

---

## 6. 以后若要修

| 对象 | 做法 | 预期 |
|---|---|---|
| 假锁 7 帧 | 丢掉窗头残段，或按 5.133 ms 格子给后段种子，再解一次 | 能对准真 256 SYNC；FCS 是否过还取决于贴窗尾的 PHR 长度 |
| 窗头截断 9 帧 | 加长 dump 窗，或换连续 `.dat` / 以 DW 为中心的窗 | 当前 590 μs 窗几何上不够 |
| packet 47 | 另议对齐门限 0.70 | 与本文无关 |

不要用 `cir_coherence≥0.99` 或 occupancy 回过头来解释这 16 帧。它们在解 DW 这一步就已经锁错或被截断了。

看图：`visualize_qm35_cir_interference.m` 里改 `packet_index`。底层是整窗原始 I/Q；红=假锁/残尾，绿=后段真包，紫=后包 SFD 出窗。

---

### 实现规格（2026-08-18）：见 [[dump窗DW1000_跳过残段与Preamble-only_SIC]]。

dump SIC 跳过 `start<2000` 的窗头残段，在 `x(qm35-80μs:end)` 搜重叠 DW
（`start>qm35+40μs` 仍接受）；整包 FCS 不过则 preamble-only。
不改 `detectRepeatedPreamble` 全局最早优先，不降 0.70，不加长 dump 窗。
禁止用 64 峰 `detected_repetitions` 当残尾游标。
