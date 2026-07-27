# X410 UWB 基带数据解调 / 再生 / 干扰分析

本项目基于 **USRP X410** 采集的 UWB 基带 IQ 数据，实现对 **DW1000 / QM35（QM35825）** 两种 UWB 芯片发射波形的完整解调流程，并延伸到信道冲激响应（CIR）估计、波形再生对比、以及混合场景下 **DW1000 → QM35 干扰的定量分析（SIR）**。代码使用 MATLAB，依赖 Communications Toolbox 的 `lrwpan` / `helperUWB*` 系列函数（用于扩频码 / SFD 模板参考波形生成和 BPRF 解调）。

---

## 一、研究内容与目标

### 1.1 UWB 相干解调
针对 X410 以 737.28 MHz 采样率记录的数据，完整实现 HRP UWB PHY（IEEE 802.15.4a / 4z BPRF）的基带处理：时钟同步干扰抑制、中心频率补偿、前导检测、载波频偏恢复、SFD 自动识别、CIR 估计、软判决码片生成、PHR/PSDU 解码及 FCS 校验。

### 1.2 波形再生与一致性验证
从解码得到的 PSDU 比特流出发，按原 PHY 配置重新生成标准 QM35 发射波形，再经过与真实接收信号完全相同的预处理链路，通过复数增益拟合和相减，验证解调—再生链路的自洽性，并暴露信道/接收机失真。

### 1.3 DW1000 + QM35 混合场景的干扰分析
在 `qm35_dw1000_1.dat` 这类 DW1000 与 QM35 交错/重叠发射的采集上：
- 利用 QM35 5 ms 周期网格定位每个包；
- 取 **pre-first-path CIR bin**（首径之前、几乎没有 QM35 多径能量的延迟段）作为 DW1000 干扰 + 热噪声的代理；
- 以首径峰值功率为信号参考，计算每包的 **SIR（dB）**，输出汇总表与时域/频域可视化；
- 导出干扰最严重的若干段原始 IQ，做进一步分析。

### 1.4 干扰抑制策略
- **同步音调消隐（tone cancel）**：利用已知的采样时钟相关干扰（~ -169 bin / 512 周期），在静默段估计复系数后整段抵消。
- **时域空白（blanking）**：对混合场景中已知的干扰突发位置做加权/渐变置零，避免 QM35 解调被 DW1000 突发拉偏。

---

## 二、项目结构

```
+uwbdecoder/           % 解调算法包（核心，纯函数，可被批量脚本调用）
├── readAndCancelInterference.m   % 读 IQ + 同步音调抵消 + 时域空白
├── selectIqChannel.m             % 抽取指定通道的复基带
├── compensateCenterFrequency.m   % X410 中心频点 → 载波 DC
├── buildUwbReference.m        % 利用 lrwpan 生成前导/扩频码模板
├── resampleCapture.m             % 重采样到 HRP 工作采样率 (998.4 MHz)
├── detectRepeatedPreamble.m      % 粗检 + ROI 内 16-symbol 累加度量 + 峰值跟踪
├── validateCaptureLength.m       % 长度门限检查
├── cropToFrame.m                 % 按软判决预算裁掉帧外数据
├── compensateCarrierOffset.m     % 基于前导峰值相位的线性拟合 CFO + 常相位
├── refineTimingWithNsSfd.m       % 多 SFD 模板满速相关 + 自动选优 + 定时细化
├── analyzeNsSfdSymbols.m         % 码片级 SFD 诊断
├── estimateCirAndSoftChips.m     % 解扩 CIR + 软判决码片生成
├── locateNsSfd.m                 % 在软判决流中定位 SFD
├── decodePhrAndPayload.m         % PHR/PSDU 解码 + FCS-16
├── ieee802154CRC16.m             % 反射式 CRC-16
├── mergeOptions / defaultOptions / packageResult / ...
├── applyBlankIntervals.m         % 加权渐变时域空白
├── synchronousTone.m             % 采样时钟同步复指数（查表法）
└── plotXxx.m                     % 各阶段可视化辅助

顶层脚本（面向实验的入口）
├── 单包解调
│   ├── run_decode_uwb.m        % 分步运行，保留中间变量（调试用）
│   ├── decode_uwb.m            % 函数式入口，返回 result 结构
│   └── run_decode_smoke_test.m         % 最小冒烟测试
├── 全文件批解调（滑窗 + 粗精两级）
│   ├── run_decode_uwb_all.m
│   └── decode_uwb_all.m
├── 混合场景 QM35 搜索与 CIR
│   ├── run_find_first_qm35_in_mix.m    % 从文件头滑窗找第一个 QM35 包 + 相关诊断图
│   ├── run_search_qm35_periodic_cir.m  % 5 ms 网格搜多包 + pre-path SIR
│   └── run_search_n_qm35_preamble_corr.m % N 包定长窗网格搜索 + 导出最差段
├── 波形再生与对比
│   ├── run_decode_and_regenerate_qm35.m            % 端到端驱动
│   ├── generate_qm35_tx_from_decode.m              % PSDU → 标准 QM35 波形
│   ├── apply_estimated_cir_to_qm35.m               % 用测量 CIR 替代脉冲成形
│   ├── compare_qm35_original_and_generated.m       % 对齐/增益拟合/相减
│   ├── plot_qm35_estimated_cir.m                   % CIR 可视化
│   └── write_x410_iq_int16.m                       % 写 interleaved int16 IQ
├── 干扰与可视化辅助
│   ├── analyze_worst_qm35_raw_signal.m   % 最差段原始 IQ 可视化
│   ├── analyze_x410_interference.m       % 时钟相关干扰 / 镜像 / 功率分析
│   ├── visualize_x410_tone_cancellation.m % 抵消前后时域/频域对比
│   ├── run_view_qm35_dw1000_1_time.m     % 冲突窗时域视图
│   ├── run_decode_all_qm35_in_mix.m      % 混合场景多包解调
│   ├── run_decode_all_qm35_with_ic.m     % 带干扰抵消的多包解调
│   └── cancel_qm35_with_regenerated.m    % 再生波形相减抵消
└── 输出目录（运行生成，已 gitignore）
    ├── decoded_results/        % 全文件批解调结果
    └── regenerated_qm35/       % 再生/对比结果
```

数据文件（位于 `F:\UWB基带数据\`）：
- `dw1000_*.dat`、`qm35_*.dat`、`qm35_dw1000_*.dat` 等，int16 交错 I/Q。

---

## 三、解调流程与实现原理

整体流程按"干扰抑制 → 变频 → 重采样 → 同步 → 解扩 → 解码"展开。下面给出每个模块的关键实现要点。

### 3.1 读取与干扰抑制（`readAndCancelInterference`）
1. 按 `sample_offset`、`sample_num` 读取 int16 原始 IQ，抽取指定通道。
2. **同步音调抵消**：干扰频率为 `tone_bin / period_samples * fs_rx`，与采样时钟严格相关。先在静默段（`interference_quiet_offset`）取一段纯净数据，与本地复指数做相关得到复系数 `coefficient = mean(rx_quiet .* conj(basis))`，再从整段减去 `coefficient * basis`。系数可缓存复用。
3. **时域空白**（`applyBlankIntervals`）：对绝对样本位置给出的干扰区间乘以 `blank_weight`（0 = 全删，1 = 不变），两端用余弦渐变 `0.5 - 0.5 cos(πt)` 避免突变。用于 QM35 解调前压低同段 DW1000 突发。
4. 去直流。

### 3.2 中心频率补偿（`compensateCenterFrequency`）
X410 本振 `x410_center_frequency`（6500 MHz）与 UWB 载波 `dw1000_center_frequency`（6489.6 MHz）之差（+10.4 MHz）通过复指数搬移到 DC，再按 RMS 归一化。

### 3.3 参考波形生成（`buildUwbReference`）
调用 Communications Toolbox 的 `lrwpanHRPConfig`（802.15.4a, MeanPRF=62.4, 支持 6.81 Mbps）+ `lrwpanWaveformGenerator` 生成 1 个前导符号的成形波形；再用 `lrwpan.internal.HRPCodes(code_index)` 得到扩频码，按扩频因子（16）和 SamplesPerPulse（2）插入零并采样，得到 `sampled_code`。参考结构还保存 `fs`（998.4 MHz）、`samples_per_symbol`、`chips_per_symbol`、`code_energy`。

### 3.4 重采样（`resampleCapture`）
`resample(rx, p, q)` 将 737.28 MHz 的 X410 采样无混叠地转换为 HRP 工作采样率 998.4 MHz，使用 `rat` 保证有理倍率精度 1e-12。

### 3.5 重复前导检测（`detectRepeatedPreamble`）
采用**粗检 + 精跟踪**两阶段：
- **粗检**（`coarsePreamblePeak`）：4 倍降采样后做前导匹配滤波 `fftfilt(flipud(conj(template_ds)), rx_ds)`，用滑动能量归一化得 score；再把 16 个相距 symbol_length 的 score 累加为 metric，取最强点作为粗定位。
- **ROI 跟踪**（`trackPreambleInRoi`）：在粗定位 ±`(preamble_repetitions+32)*symbol_length` 的窗内做满速相关，metric 用 MAD 自适应门限（`median + 6σ`，且不低于峰值的 20%），从最强峰向前/向后 8 符号内迭代搜索相邻峰，再用 `polyfit` 拟合峰位置得到 **measured_period** 和 **clock_error_ppm**。
- 若 ROI 峰数 < 32，回退到全程满速搜索。

### 3.6 帧裁切（`cropToFrame`）
按"软判决码片预算"估计帧跨度（`estimateFrameSampleSpan`），在 `start_sample - 3*period` 到帧尾之间裁掉帧外数据，避免后续对毫秒级整段做相关。`preamble.matched / score` 会同步移位为局部坐标。

### 3.7 载波频偏补偿（`compensateCarrierOffset`）
前导起始 24 个符号是重采样/接收机启动瞬变的相位弯曲区，**跳过前 24 个（且至少保留 32 个）峰值**；对后续最多 240 个峰值的相位做 `unwrap + polyfit`，一阶系数给出频偏（单位 Hz），整段复指数补偿；再用常相位把前导波形对齐到实轴正方向。

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
- `generate_qm35_tx_from_decode`：复用解码得到的 PSDU 比特（含 FCS），用 `lrwpanWaveformGenerator` 生成标准 64-SYNC BPRF 帧，再显式扩展到 128-SYNC 以匹配 QM35 实际配置；输出工作采样率波形和重采样/频移到 X410 的波形。
- `apply_estimated_cir_to_qm35`：用测量 CIR 替代 Butterworth 成形，把未成形的 {-1,0,+1} 脉冲序列通过 CIR，避免重复成形。
- `compare_qm35_original_and_generated`：真实信号走相同预处理（抵消 → 变频 → 重采样 → CFO → 定时细化），再对生成波形做单复数增益拟合，对比波形差异并保留信道/接收机失真特征。

### 3.13 Pre-first-path SIR 分析（`run_search_qm35_periodic_cir`）
- 在 5 ms 周期网格上逐包锁定 QM35，估计 CIR；
- 取首径（delay≈0）附近 ±1 bin 的最大功率为 `P_signal`；
- 取首径之前、留 2 bin 保护间隔之外的 pre-path bin 平均功率作为 DW1000 干扰 + 噪声的代理 `P_interf`；
- `SIR_dB = 10 log10(P_signal / P_interf_mean)`，并给出 peak SIR、pre-path floor、每包 FCS 状态；
- 输出汇总表、CSV、以及 CIR 放大 / 干扰地板 / SIR 趋势 / SIR-时间 四合一图。

---

## 四、关键配置参数

```matlab
options.file_name = 'F:\UWB基带数据\qm35_1.dat';
options.fs_rx = 737.28e6;                 % X410 采样率
options.x410_center_frequency = 6500e6;   % X410 本振
options.dw1000_center_frequency = 6489.6e6; % UWB 载波

options.preamble_repetitions = 128;       % QM35 实际 SYNC 长度
options.cir_repetitions = 64;             % 用于 CIR 平均的 SYNC 数
options.code_index = 9;                   % HRP 扩频码索引
options.data_rate = 6.81;                 % Mbps
options.sfd_mode = 'auto';                % 自动识别 SFD
```

`sfd_mode` 可选：`auto` / `decawave` / `ieee` / `4z1` ~ `4z4`。

常用干扰抵消参数：
```matlab
options.enable_interference_cancellation = true;
options.interference_tone_bin = -169;
options.interference_period_samples = 512;
options.interference_quiet_offset = 400000;
options.interference_quiet_num = 262144;
options.interference_coefficient = [];   % 留空则自动估计，可缓存复用
```

---

## 五、运行示例

```matlab
% 1) 单包分步调试
run_decode_uwb

% 2) 函数式调用
options.file_name = 'F:\UWB基带数据\qm35_1.dat';
options.preamble_repetitions = 128;
options.sfd_mode = 'auto';
result = decode_uwb(options);

% 3) 全文件批解调
run_decode_uwb_all

% 4) 混合场景：找第一个 QM35 + 相关诊断
run_find_first_qm35_in_mix

% 5) 5 ms 网格多包 + pre-path SIR
run_search_qm35_periodic_cir

% 6) N 包定长窗搜索 + 导出最差段
run_search_n_qm35_preamble_corr

% 7) 解码 → 再生 → 对比
run_decode_and_regenerate_qm35
```

---

## 六、主要输出

- `result.preamble`：前导度量峰、门限、峰位置、检测到的重复数、measured_period、时钟误差 (ppm)、载波频偏 (Hz)、SFD 波形相关。
- `result.cir`：`values(N×1)`、`delay_ns`、`individual_values(N×reps)`、平均次数、前后窗。
- `result.sfd`：选中 SFD 名、起止码片、相关系数、极性、搜索窗。
- `result.phr`：SECDED 状态、PSDU 字节数。
- `result.payload`：PSDU 字节、接收/计算 FCS、校验结果。
- 批解调：`decoded_results/<文件名>/all_frames_cir.mat` + `frame_summary.csv`。
- 干扰分析：`qm35_prepath_sir.csv`、最差段 `.dat` + 元数据 `.mat`。

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
