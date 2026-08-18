# UWB Demodulation Project Structure

本文按当前工作区实际文件整理项目结构、主要运行入口和每个 MATLAB 文件的作用。现有 `README.md` / `SCRIPTS.md` 里有少量旧入口名在当前分支已不存在，本文以当前文件系统和 Git 跟踪文件为准。

## 1. 项目定位

本项目用于处理 USRP X410 采集的 UWB 基带 IQ 数据，主要覆盖：

- DW1000 / QM35(QM35825) HRP UWB BPRF 信号解调；
- 同步窄带音调干扰抵消、中心频率补偿、重采样、前导检测、CFO/SFD/CIR/软芯片/PHR/PSDU/FCS 解码；
- 基于已解码 PSDU 的 UWB 波形再生、CIR 成形、与原始捕获对齐比较；
- 全文件多包扫描与可靠包抵消；
- QM35 与 DW1000 混合捕获中的逐级 SIC：先消 QM35，再解/消 DW1000，并输出保留 QM35 的结果。

主要依赖 MATLAB Communications Toolbox 的 `lrwpanHRPConfig`、`lrwpanWaveformGenerator` 以及 `helperUWB*` 解调辅助函数。

## 2. 当前目录结构

```text
UWB_demodulation/
|-- README.md
|-- SCRIPTS.md
|-- PROJECT_STRUCTURE_SUMMARY.md
|-- +uwbdecoder/              核心解调原语包
|-- helpers/                  MATLAB/802.15.4 HRP 辅助解调函数
|-- sic_pipeline/             QM35 -> DW1000 串行干扰抵消流水线
|-- tests/                    MATLAB 单元测试
|-- decoded_results/          运行生成目录，当前未纳入 Git
|-- phase_noise_results/      相位噪声分析输出目录
|-- 顶层 *.m                  实验入口、批处理、可视化、再生与抵消工具
```

常用外部数据路径写在脚本里，主要是 `F:\UWB基带数据\*.dat`。`.dat` 数据按 int16 交错 I/Q 存储，默认 X410 采样率为 737.28 MHz。

## 3. 推荐运行入口

| 目标 | 入口 |
|---|---|
| 快速验证解码链路 | `run_decode_uwb_smoke_test.m` |
| 单包分步解调和调试 | `run_decode_uwb.m` |
| 函数式单包解调 | `decode_uwb(options)` |
| 全文件扫描所有包 | `run_decode_uwb_all.m`，内部调用 `decode_uwb_all.m` |
| 全文件包再生与抵消 | `run_cancel_all_uwb_packets.m` |
| 解码并再生一帧 QM35 | `run_decode_and_regenerate_uwb.m` |
| 分步分析再生抵消链路 | `run_analyze_uwb_cancellation_steps.m` |
| QM35 -> DW1000 SIC 流水线 | `sic_pipeline/run_qm35_dw1000_sic_pipeline.m` |
| 查看批量解码结果 | `visualize_decode_uwb_all.m` |
| 查看抵消结果 | `visualize_uwb_cancellation.m` / `visualize_uwb_cancellation_10ms.m` |

## 4. 核心处理链路

`decode_uwb.m` 是单包解调主链路：

```text
readAndCancelInterference
  -> compensateCenterFrequency
  -> buildUwbReference
  -> resampleCapture
  -> detectRepeatedPreamble
  -> validateCaptureLength
  -> cropToFrame
  -> compensateCarrierOffset
  -> refineTimingWithNsSfd
  -> analyzeNsSfdSymbols
  -> estimateCirAndSoftChips
  -> locateNsSfd
  -> decodePhrAndPayload
  -> packageResult
```

`decode_uwb_all.m` 在全文件上分三阶段工作：

1. stride 方式读取并做能量包络扫描；
2. 在能量区域附近做自适应 full-rate 前导相关；
3. 只对候选窗口调用 `decode_uwb` 精解，去重、筛选 FCS、保存 CIR 和 CSV。

`run_cancel_all_uwb_packets.m` 使用全文件扫描结果，对每个可靠包再生波形、拟合增益/相位/时间漂移并写回抵消后的 int16 IQ 捕获文件。

`sic_pipeline/uwbSicPipeline.m` 编排四个阶段：

1. 原始混合捕获解 QM35；
2. 从混合捕获中消 QM35，得到 `qm35_removed.dat`；
3. 从 `qm35_removed.dat` 解 DW1000；
4. 从原始捕获中消 DW1000，得到 `dw1000_removed_qm35_preserved.dat`。

当前 SIC 算法版本为 `adaptive_fullrate_multipkt_v3_pll10_cir11_cfo2_full_packet_sfo_v1`，与 `decode_uwb_all.m` 中 `detection_algorithm_version = 3` 对齐。

## 5. 顶层 MATLAB 文件

| 文件 | 类型 | 作用 |
|---|---|---|
| `decode_uwb.m` | 函数 | 单包 UWB 解调入口，串联 `+uwbdecoder` 各阶段并返回 `result`。支持传入已预处理样本和已构建参考，供批处理复用。 |
| `decode_uwb_all.m` | 函数 | 全文件多包扫描与解调。输出 `all_frames_cir.mat`、`frame_summary.csv`，记录候选、CIR、FCS、时间区间等。 |
| `run_decode_uwb.m` | 脚本 | 单包 DW1000/X410 分步入口，保留中间变量并输出阶段耗时、图和解码诊断。 |
| `run_decode_uwb_smoke_test.m` | 脚本 | 非交互冒烟测试，验证单包解码基本可运行。 |
| `run_decode_uwb_all.m` | 脚本 | 全文件扫描入口，设置 DW1000/QM35 profile、输入文件、batch 参数和输出目录后调用 `decode_uwb_all`。也被 SIC pipeline 调用。 |
| `run_decode_and_regenerate_uwb.m` | 脚本 | 解码一帧 QM35，生成标准发射波形，再用测得 CIR 成形，保存 MATLAB 结果和 X410-ready IQ。 |
| `generate_uwb_tx_from_decode.m` | 函数 | 从解码结果中的 PSDU/FCS 重建 UWB 发射波形，生成工作采样率和 X410 采样率版本。 |
| `apply_estimated_cir_to_uwb.m` | 函数 | 用测得 CIR 替换标准脉冲成形，将稀疏 UWB 脉冲序列卷积成更接近接收信道的副本。 |
| `compare_uwb_original_and_generated.m` | 函数 | 对真实捕获和再生波形走相同预处理链，做起点细化、复增益拟合和残差对比。 |
| `cancel_uwb_with_regenerated.m` | 函数 | 从捕获帧中减去 CIR 成形后的再生 UWB 包，输出 residual、suppression、CFO/相位诊断和图。 |
| `run_cancel_all_uwb_packets.m` | 脚本 | 全文件抵消入口。读取扫描结果，复制输出基准捕获，去同步单音，并对所有可靠包逐个拟合/抵消/写回。 |
| `run_analyze_uwb_cancellation_steps.m` | 脚本 | 把单包再生抵消过程拆成详细步骤，分析前导相位、插值、CFO、字段增益和残差。 |
| `run_analyze_uwb_preamble_phase.m` | 脚本 | 分析 DW1000 前导码原始相关峰、相位稳定过程和瞬时 CFO。 |
| `visualize_decode_uwb_all.m` | 脚本 | 读取 `all_frames_cir.mat`，画包时间线、逐包指标、CIR 叠加并输出汇总。 |
| `visualize_uwb_cancellation.m` | 脚本 | 针对一个已抵消包画原始/再生/抵消后信号、频谱、相位差、IQ 平面和 CIR。 |
| `visualize_uwb_cancellation_10ms.m` | 脚本 | 在可配置时间窗内对比原始和抵消后的整段捕获，展示包位置、时域包络和频谱。 |
| `visualize_uwb_segment.m` | 脚本 | 快速查看任意捕获片段的时域、频谱和 spectrogram。 |
| `visualize_x410_tone_cancellation.m` | 脚本 | 估计并可视化 X410 时钟同步窄带音调抵消效果，不写新捕获文件。 |
| `visualize_qm35_energy_detection.m` | 脚本 | 复现并可视化 QM35 全文件 Stage-1 能量检测器，检查阈值、区域和候选。 |
| `visualize_qm35_preamble_correlation.m` | 脚本 | 可视化 QM35 自适应多包 full-rate 前导相关，检查能量区域内多候选搜索机制。 |
| `read_x410.m` | 脚本 | 快速读取一个 X410 `.dat`，绘制时域 IQ 和频谱。 |
| `write_x410_iq_int16.m` | 函数 | 将复数单通道向量归一化并写成 interleaved int16 IQ 文件。 |
| `plot_uwb_estimated_cir.m` | 函数 | 绘制平均 CIR 和逐 repetition CIR 细节，支持保存 PNG。 |
| `analyze_worst_uwb_raw_signal.m` | 脚本 | 读取 `qm35_worst10_segments` 中最差干扰段，分析原始/抵消 IQ、频谱、时频和解码结果。 |
| `analyze_dw1000_single_tone_phase_noise.m` | 脚本 | 对捕获到的 DW1000 单音做频率估计、残余相位、Allan/PSD/SSB phase noise 分析。 |
| `analyze_qm35_cir_slow_phase.m` | 脚本 | 从批解码 CIR 结果中统计 QM35 每包 repetition CIR 的慢相位漂移。 |
| `analyze_uwb_pll_phase_drift.m` | 脚本 | 比较拟合捕获和抵消捕获，学习/评估包起始 PLL 相位漂移模板。 |
| `regenerate_uwb_pll_templates.m` | 脚本 | 重建 DW1000/QM35 的批解码与 baseline cancellation 产物，再生成 PLL 相位补偿模板。 |
| `estimate_uwb_cir_slow_phase.m` | 函数 | 从单包 CIR repetition 子空间估计慢相位漂移、二级 CFO 和校正诊断。 |
| `estimate_uwb_full_packet_sfo.m` | 函数 | 对接收信号和再生副本分窗估计全包仿射采样频偏/时间漂移。 |
| `apply_uwb_full_packet_sfo.m` | 函数 | 根据 SFO 诊断对再生副本做分数延迟仿射时间校正。 |

## 6. `+uwbdecoder` 包

| 文件 | 作用 |
|---|---|
| `constants.m` | 集中定义物理/协议常量，如 int16 范围、HRP 采样、光速等。 |
| `defaultOptions.m` | 给出默认捕获路径、X410/UWB 频点、采样率、干扰抵消、前导、CIR、SFD 和绘图参数。 |
| `mergeOptions.m` | 合并用户 options，校验字段名和取值范围，规范化 SFD/布尔/blanking 参数。 |
| `readIqRaw.m` | 从 int16 交错 I/Q 文件读取连续样本。 |
| `readIqRawStrided.m` | 按 stride 读取捕获样本，供全文件能量扫描高效抽样。 |
| `selectIqChannel.m` | 从多天线交错 IQ 中抽取指定通道为复向量。 |
| `synchronousTone.m` | 生成与采样周期锁定的复指数音调基函数。 |
| `readAndCancelInterference.m` | 读取 IQ、估计/复用同步音调系数、抵消窄带干扰、执行 blank interval 和 DC 去除。 |
| `applyBlankIntervals.m` | 对绝对样本区间做带余弦渐变的软消隐。 |
| `compensateCenterFrequency.m` | 根据 X410 中心频率和 DW1000/UWB 中心频率差进行复混频到 DC，并 RMS 归一化。 |
| `buildUwbReference.m` | 用 `lrwpan` 生成 HRP 参考波形、扩频码、SFD 候选和工作采样率元数据。 |
| `resampleCapture.m` | 将 X410 采样率重采样到 HRP 工作采样率 998.4 MHz。 |
| `detectRepeatedPreamble.m` | 粗检并跟踪重复 SYNC 前导峰，估计符号周期、clock error ppm 和相关指标。 |
| `validateCaptureLength.m` | 检查工作缓冲区是否足够包含完整 SHR/帧头附近区域。 |
| `estimateFrameSampleSpan.m` | 根据前导、SFD、PHR、最大 PSDU 等估算帧样本跨度，用于裁剪窗口。 |
| `cropToFrame.m` | 将重采样后的工作缓冲裁到活跃帧附近，并同步调整前导坐标。 |
| `compensateCarrierOffset.m` | 基于前导相关峰相位拟合 CFO，补偿频偏和常相位。 |
| `refineTimingWithNsSfd.m` | 对 Decawave/IEEE/4z SFD 候选做 full-rate 相关，自动选择并细化定时。 |
| `analyzeNsSfdSymbols.m` | 在符号分辨率下对选定 SFD 位置做诊断。 |
| `estimateCirAndSoftChips.m` | 解扩前导得到平均 CIR，并用 CIR 生成软判决 chip 流。 |
| `locateNsSfd.m` | 在软 chip 流中定位 SFD 起点、极性和相关质量。 |
| `decodePhrAndPayload.m` | 调用 helper 解码 PHR/PSDU，并计算 IEEE 802.15.4 FCS。 |
| `ieee802154CRC16.m` | 实现反射式 IEEE 802.15.4 CRC-16。 |
| `packageResult.m` | 将内部阶段输出整理成公开 result 结构。 |
| `plotPreambleDetection.m` | 绘制前导检测/峰跟踪结果。 |
| `plotDespreadCir.m` | 绘制平均 CIR 与每次解扩 CIR。 |
| `plotSfdDetection.m` | 绘制 SFD 搜索度量。 |

## 7. `helpers` 目录

| 文件 | 作用 |
|---|---|
| `helperFindFirstHRPPreamble.m` | 在信号中查找第一个 HRP preamble 出现位置。 |
| `helperUWBBPRFDemod.m` | BPRF HRP-UWB PHR/payload BPM-BPSK 符号解调。 |
| `helperUWBHPRFDemod.m` | HPRF/ERDEV 方案解调辅助。 |
| `helperUWBConvDec.m` | IEEE 802.15.4a/z 卷积码译码。 |
| `helperUWBPHRDecode.m` | PHR SECDED 和帧长度字段解码。 |
| `helperUWBPayloadDecode.m` | Payload 软符号解调和 PSDU 解码。 |

## 8. `sic_pipeline` 目录

| 文件 | 作用 |
|---|---|
| `run_qm35_dw1000_sic_pipeline.m` | SIC 推荐入口。设置混合捕获路径、输出目录、抵消模式、resume/overwrite，再调用 `uwbSicPipeline`。 |
| `uwbSicPipeline.m` | 核心编排函数。复用根目录 `run_decode_uwb_all.m` 与 `run_cancel_all_uwb_packets.m`，负责路径、阶段复用/覆盖、算法版本校验、manifest 和 summary。 |
| `visualize_UwbSicPipeline.m` | 从 pipeline manifest 中汇总显示包数、suppression 和阶段结果。 |
| `visualize_sic_signal_comparison.m` | 对比原始混合 IQ、QM35 removed、DW1000 removed/QM35 preserved 等阶段信号的时域和频谱。 |
| `analyze_qm35_cir_before_after_dw1000.m` | 对比 DW1000 抵消前后匹配 QM35 包的 CIR，分析分布变化并输出图表。 |
| `README.md` | SIC pipeline 的入口、阶段约定、算法版本契约和输出目录说明。 |

## 9. `tests` 目录

| 文件 | 作用 |
|---|---|
| `testReadIqRawStrided.m` | MATLAB unit test，验证 `readIqRawStrided` 的 stride 读取与连续读取一致，并覆盖双天线样本布局。 |

## 10. 当前文档与实际文件的差异

以下名字在 `README.md` 或 `SCRIPTS.md` 中出现，但当前工作区根目录没有对应文件：

- `analyze_x410_interference.m`
- `read_uwb_cancelled_dat.m`
- `run_find_first_uwb_in_mix.m`
- `run_search_uwb_periodic_cir.m`
- `run_search_n_uwb_preamble_corr.m`
- `run_decode_uwb_in_mix.m`
- `run_decode_uwb_with_ic.m`
- `run_view_uwb_mix_time.m`
- `run_cancel_uwb_segment.m`
- `UWB_decoding_despread.m`

另外，`SCRIPTS.md` 中写到 `constants.py`，当前实际文件是 `+uwbdecoder/constants.m`。

