# 脚本与函数索引

> 本文件记录 **本分支**（`gnuradio-scheduled-dump`）下每个 `.m` 文件的用途。
> 本分支面向 GNU Radio scheduled-extractor 的截窗输出（`capture.iq` + `capture.jsonl`），
> 以及支撑它的解调 / 再生 / SIC 参考实现。连续 1 s 采集上的搜索、可视化与实验脚本
> 留在 `acceleration`，不在本分支。
>
> 顶层命名：`run_*` 实验入口；`visualize_*` 画图；`analyze_*` / `run_analyze_*` 专项分析。
> 可复用的解码 / I/O / 消除函数不加这些前缀。
> `+uwbdecoder/` 包内保持 camelCase。

---

## 数据文件

数据在仓库外 `F:\UWB基带数据\`。本分支主要读 GNU Radio detector 的截窗 dump，不是整段 1 s `.dat`。

| 路径 | 说明 |
|------|------|
| `F:\UWB基带数据\qm35_scheduled_sc16_dump\` | mixed 737.28 scheduled SC16 dump（`capture.iq` 已去单音） |
| `F:\UWB基带数据\qm35_clean_scheduled_sc16_dump\` | 无干扰 QM35 737.28 scheduled SC16 dump |
| `F:\UWB基带数据\qm35_gain1_scheduled_sc16_dump_20260817\` | gain1 scheduled SC16 dump |
| `F:\UWB基带数据\DW1000_*.dat` / `QM35_*.dat` / `qm35_dw1000_*.dat` | 连续采集 `.dat`，仅解调 / SIC 参考脚本使用 |

每个 dump 目录需要：

- `capture.iq` — 各雷达 slot 窗首尾相接的 SC16
- `capture.jsonl` — 每窗在文件中的偏移、以及在原始连续流中的坐标
- 可选 `scheduled_dump_cpp.csv` — C++ detector 对照

---

## 1. 核心解码函数（`+uwbdecoder/` 包）

纯函数，不直接运行，由顶层脚本调用。

| 文件 | 功能 |
|------|------|
| `constants.m` | 物理/协议常量 |
| `defaultOptions.m` | 默认解码器配置（含 `cir_diag_*` 诊断窗） |
| `mergeOptions.m` | 合并用户覆盖选项并校验 |
| `readIqRaw.m` / `readIqRawStrided.m` | 读交织 int16 IQ |
| `selectIqChannel.m` | 抽取一个通道为复向量 |
| `ieee802154CRC16.m` | IEEE 802.15.4 反射 CRC-16 |
| `buildUwbReference.m` | 构建 HRP 波形和稀疏扩频码参考 |
| `detectRepeatedPreamble.m` | 检测并跟踪重复 SYNC |
| `validateCaptureLength.m` | 校验捕获是否包含完整 SHR |
| `cropToFrame.m` | 裁剪工作缓冲区到活跃帧 |
| `estimateFrameSampleSpan.m` | 软芯片/裁剪预算 |
| `compensateCarrierOffset.m` | 估计 CFO 并补偿 |
| `refineTimingWithNsSfd.m` | 选择 SFD 模板并精化定时 |
| `analyzeNsSfdSymbols.m` | 符号分辨率 SFD 评估 |
| `estimateCir.m` / `estimateCirAndSoftChips.m` | 解扩 CIR、软芯片 |
| `estimateCirAndPostDespreadPaths.m` | 解扩后路径估计 |
| `locateNsSfd.m` | 在软芯片流中定位 SFD |
| `decodePhrAndPayload.m` / `decodePhrAndPayloadPostCmf.m` | 解码 PHR、PSDU、FCS |
| `analyzeCirInterference.m` | First Path 前 CIR 干扰特征与 SIC 判据 |
| `packageResult.m` | 打包公共结果结构体 |
| `fftFilter.m` | 滤波封装 |
| `plotPreambleDetection.m` / `plotDespreadCir.m` / `plotSfdDetection.m` | 阶段可视化 |

---

## 2. 顶层解码 / 再生 / 消除（参考实现）

这些是 GNU Radio 分析脚本和 SIC 共用的真源，不要在分析脚本里再写一套。

| 文件 | 功能 |
|------|------|
| `decode_uwb.m` | 单包解码入口 |
| `decode_uwb_all.m` | 全文件扫描（SIC 与连续 `.dat` 参考） |
| `generate_uwb_tx_from_decode.m` | 从解码 PSDU 重建发射波形 |
| `apply_estimated_cir_to_uwb.m` | 用测量 CIR 替换成形脉冲 |
| `cancel_uwb_with_regenerated.m` | 从捕获 IQ 减去重建帧 |
| `compare_uwb_original_and_generated.m` | 对比捕获与重建 IQ |
| `estimate_uwb_cir_slow_phase.m` | CIR 慢相位估计 |
| `estimate_uwb_full_packet_sfo.m` / `apply_uwb_full_packet_sfo.m` | 全包 SFO |
| `plot_uwb_estimated_cir.m` | CIR 细节图 |
| `write_x410_iq_int16.m` | 写交织 int16 IQ |
| `read_x410.m` | 快速查看 `.dat` 时域/频谱 |
| `build_uwb_mex.m` | 可选加速核 |

入口：

| 文件 | 功能 |
|------|------|
| `run_decode_uwb_smoke_test.m` | 无交互冒烟测试 |
| `run_decode_uwb.m` | 单包解码 + 分阶段计时 |
| `run_decode_uwb_all.m` | 全文件扫描（SIC 调用） |
| `run_decode_and_regenerate_uwb.m` | 解码一帧并重建发射波形 |
| `run_cancel_all_uwb_packets.m` | 全文件再生与消除（SIC 调用） |
| `analyze_uwb_pll_phase_drift.m` | 学习 PLL 模板（SIC 需要） |
| `regenerate_uwb_pll_templates.m` | 重建 DW1000 / QM35 PLL 模板 |
| `generate_uwb_gnuradio_sample.m` | 生成给 GNU Radio 用的确定性测试波形 |

---

## 3. GNU Radio detector 输出：读、去单音、解调

GNU Radio `UwbAutoScheduledExtractorSc16` / `UwbScheduledExtractorSc16` 按雷达周期截窗。
磁盘是 737.28 MS/s SC16；MATLAB 侧 65/48 升到 998.4 MHz 再 `decode_uwb`。

| 文件 | 功能 |
|------|------|
| `read_uwb_packet.m` | 读 `capture.iq` + `capture.jsonl` 的指定窗 |
| `cancel_capture_tone.m` | 逐窗减去约 6200 MHz 单音 |
| `run_cancel_capture_tone.m` | 去单音入口；覆盖 `capture.iq` |
| `decode_scheduled_sc16_dump.m` | 按窗切开 head / QM35 body / tail，升采样后解码，并跑 CIR 干扰检测 |
| `run_decode_scheduled_sc16_dump.m` | 实验入口；改 `dumpDir` 切换 mixed / clean / gain1 |
| `cancel_uwb_packet_in_iq.m` | 在 998.4 MHz 窗内再生并减去一个已解码包（dump SIC 用） |
| `scheduledDumpSicPipeline.m` | dump 窗上的 QM35→消→DW1000→消编排 |
| `run_scheduled_dump_sic_pipeline.m` | 被干扰 dump 的 SIC 入口；对比消除前后 QM35 CIR |
| `visualize_scheduled_dump_sic_cir.m` | dump SIC 前后 CIR 叠图 / 热图 |

升采样抽头：`testdata/resampler_65_48/taps_quality_minorder.txt`。

---

## 4. GNU Radio dump 上的 CIR / 干扰分析

| 文件 | 功能 |
|------|------|
| `visualize_qm35_cir_interference.m` | 单包：C++ 起点对齐的原始 IQ + First Peak 归一化 CIR 判定过程 |
| `analyze_qm35_early_energy_stats.m` | 多帧 First Path 前能量统计 |
| `run_analyze_uwb_mixed_preamble_cir.m` | 合成 code-9 + 异码前导，观察泄漏进 CIR |
| `run_analyze_uwb_mixed_code9_cir.m` | 合成 code-9 包 + code-10 干扰，跑接收机前端并打分 CIR |
| `run_analyze_uwb_preamble_code_interference.m` | 不同 preamble code 互相关泄漏矩阵 |
| `run_analyze_uwb_radar_comm_interference.m` | 雷达呼吸感知 vs 通信干扰的链路预算 |

合成脚本不读 dump，但服务同一套 CIR 干扰 / SIC 判据，所以留在本分支。

---

## 5. SIC 流水线

连续 `.dat` 的 `sic_pipeline/` 不复制解码 / 消除逻辑，只编排阶段。调用根目录
`run_decode_uwb_all` / `run_cancel_all_uwb_packets`。

GNU Radio dump 的 SIC 在根目录：`run_scheduled_dump_sic_pipeline.m`。它按窗复用
`decode_uwb` 和 `cancel_uwb_packet_in_iq`（内部仍是 `generate_uwb_tx_from_decode`
+ `apply_estimated_cir_to_uwb`），不走连续文件能量扫描。

| 文件 | 功能 |
|------|------|
| `sic_pipeline/run_qm35_dw1000_sic_pipeline.m` | 连续 `.dat` 入口：QM35 解 → 消 → DW1000 解 → 消 |
| `sic_pipeline/uwbSicPipeline.m` | 连续 `.dat` 编排函数 |
| `sic_pipeline/analyze_qm35_cir_before_after_dw1000.m` | 连续 `.dat` 消除前后 CIR |
| `sic_pipeline/visualize_UwbSicPipeline.m` | 包数量 / suppression / 发送时间 |
| `sic_pipeline/visualize_sic_signal_comparison.m` | 原始混叠 vs 消除后 |
| `run_scheduled_dump_sic_pipeline.m` | dump 入口：被干扰窗上同样的 SIC 顺序，并画 CIR |

---

## 6. 测试

| 文件 | 功能 |
|------|------|
| `tests/testReadIqRawStrided.m` | 分块读 IQ |
| `tests/testBprfAndSeededPreamble.m` | BPRF 核 / 种子前导 |
| `tests/testAnalyzeCirInterference.m` | CIR 干扰检测器 |

---

## 依赖关系

```
GNU Radio detector
  capture.iq + capture.jsonl
        │
        ▼
 read_uwb_packet / cancel_capture_tone
        │
        ▼
 decode_scheduled_sc16_dump   ──65/48──►  decode_uwb  ──►  +uwbdecoder
        │                                      │
        ▼                                      ▼
 analyzeCirInterference              generate_uwb_tx_from_decode
        │                                      │
        ▼                                      ▼
 visualize_qm35_cir_interference           sic_pipeline
 analyze_qm35_early_energy_stats
```

---

## 快速上手

| 目标 | 运行 |
|------|------|
| 解一份 scheduled dump | 改 `run_decode_scheduled_sc16_dump.m` 的 `dumpDir` 后运行 |
| 看单包 CIR 干扰判定 | 改 `visualize_qm35_cir_interference.m` 的 `dump_dir` / `packet_index` |
| DW1000 假锁 / 窗头截断 | `markdowns/DW1000_dump窗解调失败_假锁与窗头截断.md` |
| dump 去单音 | `run_cancel_capture_tone` |
| 验证解码器环境 | `run_decode_uwb_smoke_test` |
| SIC（连续 `.dat` 参考） | `sic_pipeline/run_qm35_dw1000_sic_pipeline` |
