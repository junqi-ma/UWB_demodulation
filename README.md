# GNU Radio scheduled dump：解调、CIR 干扰检测与 SIC

本分支分析 **GNU Radio detector**（`UwbAutoScheduledExtractorSc16` /
`UwbScheduledExtractorSc16`）按 QM35 雷达周期截下的 SC16 窗，而不是
`acceleration` 上那套连续 1 s `.dat` 搜索脚本。

解码、再生和 SIC 仍复用同一套 `+uwbdecoder` / `decode_uwb` /
`sic_pipeline` 参考实现。连续 1 s 采集上的网格搜索、能量检测可视化、
PLL 笔记和 `backup/` 实验产物不在本分支。

代码使用 MATLAB，依赖 Communications Toolbox 的 `lrwpan` / `helperUWB*`。

---

## 一、本分支做什么

### 1.1 读 GNU Radio 截窗
dump 目录里是 `capture.iq` + `capture.jsonl`：737.28 MS/s SC16，各雷达 slot
只切约 0.6–0.8 ms，中间空隙丢掉。MATLAB 先按 jsonl 切片，65/48 升到
998.4 MHz，再调用 `decode_uwb`。

### 1.2 相干解调（参考实现）
HRP UWB PHY（IEEE 802.15.4a / 4z BPRF）：前导检测、CFO、SFD、CIR、
软芯片、PHR/PSDU、FCS。连续 `.dat` 入口仍保留，供 SIC 和冒烟测试使用。
对已经预处理到 998.4 MHz 的 `.dat`，解码代码不再重复重采样 / 去单音 /
下移 10 MHz。scheduled dump 自己做 65/48 和（可选）去单音。

### 1.3 CIR 干扰检测
在 First Path 之前的诊断 CIR 窗上提特征，决定是否触发 SIC。入口是
`uwbdecoder.analyzeCirInterference`，单包图是
`visualize_qm35_cir_interference`。

### 1.4 波形再生与 SIC
从 PSDU 再生 QM35 / DW1000，做消除。连续 `.dat` 走 `sic_pipeline/`（编排
`run_decode_uwb_all` / `run_cancel_all_uwb_packets`）。GNU Radio dump 走
`run_scheduled_dump_sic_pipeline`：按窗 `decode_uwb`，用
`cancel_uwb_packet_in_iq` 再生消除，并对比 SIC 前后 QM35 CIR。

---

## 二、项目结构

```
+uwbdecoder/                 % 解调原语 + analyzeCirInterference
helpers/                     % Communications Toolbox 薄封装
sic_pipeline/                % QM35 → DW1000 SIC 编排

GNU Radio dump
├── read_uwb_packet.m
├── cancel_capture_tone.m / run_cancel_capture_tone.m
├── decode_scheduled_sc16_dump.m
├── run_decode_scheduled_sc16_dump.m
├── scheduledDumpSicPipeline.m / run_scheduled_dump_sic_pipeline.m
├── cancel_uwb_packet_in_iq.m
├── visualize_qm35_cir_interference.m
├── visualize_scheduled_dump_sic_cir.m
└── analyze_qm35_early_energy_stats.m

解调 / 再生 / 消除参考
├── decode_uwb.m / decode_uwb_all.m
├── run_decode_uwb.m / run_decode_uwb_all.m / run_decode_uwb_smoke_test.m
├── generate_uwb_tx_from_decode.m / apply_estimated_cir_to_uwb.m
├── cancel_uwb_with_regenerated.m / run_cancel_all_uwb_packets.m
└── estimate_uwb_cir_slow_phase.m / *_full_packet_sfo.m

CIR / 码型干扰（合成，服务同一判据）
├── run_analyze_uwb_mixed_code9_cir.m
├── run_analyze_uwb_mixed_preamble_cir.m
├── run_analyze_uwb_preamble_code_interference.m
└── run_analyze_uwb_radar_comm_interference.m

testdata/resampler_65_48/    % 737.28 → 998.4 抽头
decoded_results/             % 运行产物，gitignore
```

数据在 `F:\UWB基带数据\`：

- 本分支主路径：`qm35_*scheduled_sc16_dump*/capture.iq` + `capture.jsonl`
- SIC / 冒烟测试仍可用 `DW1000_*.dat`、`QM35_*.dat`、`qm35_dw1000_*.dat`

---

## 三、解调流程与实现原理

整体流程按"读取预处理 IQ → 同步 → 解扩 → 解码"展开。下面给出每个模块的关键实现要点。

### 3.1 预处理输入
按 `sample_offset`、`sample_num` 读取 int16 交错 IQ，抽取指定通道后直接进入解码。输入必须已经位于 998.4 MHz 的 HRP 工作采样网格，并已完成重采样、单音去除及中心频率下移 10 MHz。

### 3.2 参考波形生成（`buildUwbReference`）
调用 Communications Toolbox 的 `lrwpanHRPConfig`（802.15.4a, MeanPRF=62.4, 支持 6.81 Mbps）+ `lrwpanWaveformGenerator` 生成 1 个前导符号的成形波形；再用 `lrwpan.internal.HRPCodes(code_index)` 得到扩频码，按扩频因子（16）和 SamplesPerPulse（2）插入零并采样，得到 `sampled_code`。参考结构还保存 `fs`（998.4 MHz）、`samples_per_symbol`、`chips_per_symbol`、`code_energy`。

### 3.3 重复前导检测（`detectRepeatedPreamble`）
采用**粗检 + 精跟踪**两阶段：
- **粗检**（`coarsePreamblePeak`）：4 倍降采样后做前导匹配滤波 `fftfilt(flipud(conj(template_ds)), rx_ds)`，用滑动能量归一化得 score；再把 16 个相距 symbol_length 的 score 累加为 metric，取最强点作为粗定位。
- **ROI 跟踪**（`trackPreambleInRoi`）：在粗定位 ±`(preamble_repetitions+32)*symbol_length` 的窗内做满速相关，metric 用 MAD 自适应门限（`median + 6σ`，且不低于峰值的 20%），从最强峰向前/向后 8 符号内迭代搜索相邻峰，再用 `polyfit` 拟合峰位置得到 **measured_period** 和 **clock_error_ppm**。
- 若 ROI 峰数 < 32，回退到全程满速搜索。

### 3.6 帧裁切（`cropToFrame`）
按"软判决码片预算"估计帧跨度（`estimateFrameSampleSpan`），在 `start_sample - 3*period` 到帧尾之间裁掉帧外数据，避免后续对毫秒级整段做相关。`preamble.matched / score` 会同步移位为局部坐标。

### 3.7 载波频偏补偿（`compensateCarrierOffset`）
前导起始 24 个符号是接收机启动瞬变的相位弯曲区，**跳过前 24 个（且至少保留 32 个）峰值**；对后续最多 240 个峰值的相位做 `unwrap + polyfit`，一阶系数给出频偏（单位 Hz），整段复指数补偿；再用常相位把前导波形对齐到实轴正方向。

### 3.8 SFD 模板自动选择与定时细化（`refineTimingWithNsSfd`）
根据 `sfd_mode` 决定候选 SFD 模板：
- `auto` 模式下 BPRF（code 1–24）测试 Decawave DW-8、IEEE legacy、4z #2；HPRF（code 25–32）额外测试 #1、#3、#4。
- 把每个 SFD 序列与扩频码做 Kronecker 展宽，在 `start_sample ± 1 symbol` 内做满速相关，选相关性最高的模板；用满速相关峰位置重新反推 `preamble.start_sample`（精度从符号级细化到样本级）。

### 3.9 CIR 估计与软判决码片（`estimateCirAndSoftChips`）
- **CIR**：仅在最后 `cir_repetitions` 个 SYNC 上做一次局部码匹配滤波（`localMatchedFilterSegment`，按预/后样本窗得到首径附近的信道抽头），把每个 repetition 在名义码结束位置的抽头相干累加，L2 归一化后输出 `cir.values(N×1)` 和 `individual(N×reps)`。
- **软判决码片**：用归一化 CIR 作为 FIR 对整段帧预算截断区间再做一次短匹配滤波，在每片 `measured_period / chips_per_symbol` 处抽样，再用一段已知扩频码做相位对齐（`angle(phase_gain)`），取实部并按峰值归一化，得到 soft chip 序列。
- 该模块特别采用"局部匹配滤波 + 插值"策略，用 `abs_start .. abs_end` 的小段 buffer 代替整段滤波，避免对长采集的 O(N·L) 运算。

### 3.10 SFD 定位与帧解码
- `locateNsSfd`：在软判决流中，以 `preamble_repetitions * chips_per_symbol` 为基准 ±8 片滑动，用展宽 SFD 模板做归一化相关，取绝对值最大点。
- `decodePhrAndPayload`：先按 SFD 极性翻转，再用 Communications Toolbox 的 `helperUWBBPRFDemod` / `helperUWBPHRDecode` / `helperUWBPayloadDecode` 解 PHR 和 PSDU；最后用 `ieee802154CRC16`（反射多项式 0x8408）做 FCS-16 校验。

### 3.11 全文件批解调（`decode_uwb_all`）
粗精两级：
1. **粗检**：4e6 点/块、3e6 步进，32 倍降采样能量门限（median + 6·MAD）+ 可选降采样前导相关，筛出候选起点；
2. **精解**：仅对候选调用 `decode_uwb`，成功后跳过该包覆盖区间；
3. **存盘**：CIR 矩阵 + `frame_summary.csv` + 可选单帧 CIR。

### 3.12 波形再生与对比
- `generate_uwb_tx_from_decode`：复用解码得到的 PSDU 比特（含 FCS），用 `lrwpanWaveformGenerator` 生成标准 64-SYNC BPRF 帧，再显式扩展到 128-SYNC 以匹配 QM35 实际配置；输出 998.4 MHz 工作采样率波形。
- `apply_estimated_cir_to_uwb`：用测量 CIR 替代 Butterworth 成形，把未成形的 {-1,0,+1} 脉冲序列通过 CIR，避免重复成形。
- `compare_uwb_original_and_generated`：直接使用已预处理的真实信号，仅进行 CFO、定时细化和单复数增益拟合，对比波形差异并保留信道/接收机失真特征。

### 3.13 CIR 干扰检测（`analyzeCirInterference`）
对诊断窗 CIR（默认 First Path 前后各 64 tap）提 First Path 前能量 / 残差 /
占用率等特征，供 SIC 决策。单包过程图见 `visualize_qm35_cir_interference`。

---

## 四、关键配置参数

```matlab
options.file_name = 'F:\UWB基带数据\qm35_1.dat';
options.fs_rx = 998.4e6;                  % 预处理后的采样率

options.preamble_repetitions = 128;       % QM35 实际 SYNC 长度
options.cir_repetitions = 64;             % 用于 CIR 平均的 SYNC 数
options.code_index = 9;                   % HRP 扩频码索引
options.data_rate = 6.81;                 % Mbps
options.sfd_mode = 'auto';                % 自动识别 SFD
```

`sfd_mode` 可选：`auto` / `decawave` / `ieee` / `4z1` ~ `4z4`。

scheduled dump 入口只改 `run_decode_scheduled_sc16_dump.m` 或
`run_scheduled_dump_sic_pipeline.m` 里的 `dumpDir`。

---

## 五、运行示例

```matlab
% 1) 解 GNU Radio scheduled dump（改 dumpDir）
run_decode_scheduled_sc16_dump

% 2) 单包 CIR 干扰判定图（改 dump_dir / packet_index）
visualize_qm35_cir_interference

% 3) 被干扰 dump 上做 SIC，对比消除前后 CIR
run_scheduled_dump_sic_pipeline

% 4) 验证解码器环境
run_decode_uwb_smoke_test

% 5) 函数式单包解码（连续 .dat 参考）
options.file_name = 'F:\UWB基带数据\qm35_1.dat';
options.preamble_repetitions = 128;
options.sfd_mode = 'auto';
result = decode_uwb(options);

% 6) SIC（连续混合 .dat 参考）
run('sic_pipeline/run_qm35_dw1000_sic_pipeline.m')
```

---

## 六、主要输出

- `result.preamble`：前导度量峰、门限、峰位置、检测到的重复数、measured_period、时钟误差 (ppm)、载波频偏 (Hz)、SFD 波形相关。
- `result.cir`：`values(N×1)`、`delay_ns`、`individual_values(N×reps)`、平均次数、前后窗。
- `result.sfd`：选中 SFD 名、起止码片、相关系数、极性、搜索窗。
- `result.phr`：SECDED 状态、PSDU 字节数。
- `result.payload`：PSDU 字节、接收/计算 FCS、校验结果。
- scheduled dump：`decoded_results/<dump_tag>/scheduled_dump_matlab.mat` + CSV。
- 批解调 / SIC：`decoded_results/<capture>_<profile>/`。

---

## 七、调试建议

SFD 相关偏低时，优先检查：
1. `preamble_repetitions` 是否与实际 SYNC 长度一致（QM35 实测 128，配 256 会晚 128 个符号）。
2. `code_index`、中心频率、数据率是否与发射端匹配。
3. 两种 SFD 的相关系数是否都偏低（`result.sfd_waveform_candidate_correlations`）。
4. CIR 平均范围是否包含 SFD 或数据段。
5. 干扰抵消系数是否合理（`result.interference.coefficient` 幅度/相位）。

---

## 八、依赖

- MATLAB R2022b+（推荐）
- Communications Toolbox（`lrwpanHRPConfig`、`lrwpanWaveformGenerator`、`helperUWBBPRFDemod`、`helperUWBPHRDecode`、`helperUWBPayloadDecode`、`lrwpan.internal.HRPCodes`）
- X410 采集的 int16 交错 I/Q 数据
