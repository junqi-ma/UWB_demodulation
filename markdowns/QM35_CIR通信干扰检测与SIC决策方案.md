# QM35 CIR 通信干扰检测与 SIC 决策方案

## 1. 文档目的

本文面向后续代码修改与实验验证，目标是在当前 QM35 scheduled SC16 dump 解调流程中增加一个可靠的通信干扰检测器，从而判断每个 QM35 radar packet 是否需要执行 SIC（Successive Interference Cancellation）。

当前流程已经使用 C++ 输出的 QM35 包头真值位置完成定时初始化，100 个 scheduled packet 均能正确解调。因此，本方案不再修改包头搜索、CFO、PHR 或 PSDU 主链路，而是在已有 CIR 估计阶段增加一条旁路诊断链路。

核心结论：

> “First Path 之前的 QM35 码相关底噪抬升”可以作为通信干扰特征，但不能只观察多个 SYNC 相干平均后的 CIR。应使用逐 repetition CIR 的非相干残差、归一化功率和时间占用比例联合判断。

---

## 2. 当前解调流程

相关入口和实现文件：

- `run_decode_scheduled_sc16_dump.m`
- `decode_scheduled_sc16_dump.m`
- `decode_uwb.m`
- `+uwbdecoder/estimateCirAndSoftChips.m`
- `+uwbdecoder/estimateCir.m`
- `+uwbdecoder/packageResult.m`

QM35 参数为：

- 采样率：998.4 MHz；
- preamble code：9；
- SYNC：64 repetitions；
- SFD：4z2；
- CIR 使用 repetitions 11～64，共 54 个；
- 包头种子来自 C++ `qm35_detected_start` 真值。

当前 CIR 估计在 CFO 补偿后执行。`estimateCir.m` 先对对齐后的多个 SYNC 原始片段进行相干平均，然后只做一次 code 9 相关：

```matlab
averageSegment = mean(alignedSegments, 2);
values = conv(averageSegment, codeMf, 'valid') / ...
    (reference.code_energy + eps);
```

这种实现适合获得稳定的 QM35 信道估计并用于后续 CMF 解调，但不适合作为唯一的通信干扰观测量，因为与 QM35 不相干的信号可能在相干平均中被明显压低。

---

## 3. 方案的物理依据

QM35 雷达信号与通信信号使用不同前导码。接收信号经过 QM35 code 9 相关器后：

1. QM35 信号在固定时延产生跨 repetition 稳定、相位相干的 CIR 路径；
2. 不同码的通信信号一般不会产生同样稳定的 QM35 主峰；
3. 通信信号更多表现为分散相关旁瓣、底噪抬升以及 repetition 间波动；
4. 当通信信号覆盖 QM35 前导的一部分时，异常只出现在部分 repetition；
5. 当通信信号持续覆盖整个 QM35 前导时，First Path 前功率会在多数 repetition 中持续升高。

因此，First Path 前的相关域功率和跨 repetition 变化可以检测通信干扰。

但“不同前导码近似正交”不是严格零互相关，以下因素会破坏理想正交性：

- 通信信号与 QM35 的任意相对时延；
- 多径和截断相关窗口；
- 通信信号 CFO、采样偏差和脉冲成形差异；
- 通信信号只覆盖部分 QM35 SYNC；
- ADC 量化、AGC 变化和接收机非线性；
- QM35 主峰及多径的相关旁瓣泄漏。

所以该检测器必须使用保护区、归一化和数据标定，不能只设置一个未经验证的绝对幅度阈值。

---

## 4. 为什么不能只检查平均 CIR

设第 `m` 个 QM35 SYNC repetition 的 CIR 为：

```text
h_m[k]
```

相干平均 CIR 为：

```text
h_bar[k] = (1/M) * sum_m h_m[k]
```

稳定的 QM35 信道路径会相干累加，而热噪声和不相干通信分量会部分抵消。因此仅检查 `abs(h_bar[k])`，可能将需要 SIC 的 packet 错判为干净。

推荐计算非相干残差功率：

```text
P_res[k] = mean_m(abs(h_m[k])^2) - abs(h_bar[k])^2
```

该量等价于逐 tap 的复数样本方差（仅可能因浮点误差出现极小负值，实现时应截断到 0）：

```matlab
residualPower = max(0, mean(abs(H).^2, 2) - abs(mean(H, 2)).^2);
```

它能够将以下两部分分开：

- `abs(h_bar).^2`：跨 repetition 相干、稳定的 QM35 CIR；
- `P_res`：热噪声、通信干扰和其他跨 repetition 非稳定分量。

---

## 5. CIR 窗口与 First Path 检测

### 5.1 扩大前置窗口

当前默认 `cir_pre_samples = 8`，在 998.4 MHz 下只有约 8 ns，统计样本过少，而且容易受到定时误差和主峰相关泄漏影响。

scheduled QM35 流程建议先使用：

```matlab
qm35Opt.cir_pre_samples = 64;
qm35Opt.cir_post_samples = 64;
qm35Opt.cir_store_individual_values = true;
```

这提供约 64 ns First Path 前窗口和约 64 ns 后向多径窗口。该修改先仅用于 scheduled dump 流程，不应直接改变全局默认值，以免影响其他数据集。

### 5.2 First Path 不能固定等于 delay=0

C++ 真值给出 QM35 包头位置，但 MATLAB 的精细定时相对 C++ 仍可能存在 1～2 个输出采样差，真实传播路径也可能相对 nominal correlation peak 偏移。因此不能简单把 `delay_ns == 0` 固定视为 First Path。

建议从相干平均 CIR 中估计 First Path：

1. 在 CIR 最前端选取一段基线区；
2. 计算稳健基线 `median(power)`；
3. 用 MAD 估计离散程度；
4. 从前向后寻找首次连续 2～3 个 tap 超过 `median + K*MAD` 的位置；
5. 初始建议 `K=6`，后续按干净包标定；
6. 同时限制候选点必须位于 nominal zero 附近的合理搜索区；
7. 若找不到可靠 First Path，则输出 `valid=false`，不能强行进行 SIC 分类。

### 5.3 Early-noise 窗口

为避免 QM35 主峰泄漏，将统计窗口结束位置设置在 First Path 前 4～6 个采样：

```text
CIR start ---- early-noise window ---- guard ---- First Path ---- multipath
                                         4～6 taps
```

建议初值：

```matlab
guardSamples = 6;
earlyIndices = 1:(firstPathIndex - guardSamples);
```

如果有效 early taps 少于约 16 个，则该 packet 的判定标记为无效或低置信度。

---

## 6. 推荐检测特征

### 6.1 前路径非相干残差比

```text
P_early = median(P_res[earlyIndices])
```

使用 QM35 相干信号功率归一化：

```text
P_signal = max(abs(h_bar[signalIndices])^2)
R_early = P_early / (P_signal + eps)
R_early_dB = 10*log10(R_early + eps)
```

`signalIndices` 可取 First Path 到 First Path 后 20～30 个 tap，或者直接使用相干 CIR 的主峰功率。第一版建议同时保存两种归一化结果，实验后再确定最终定义。

### 6.2 前路径异常峰值比

中位数对窄脉冲干扰不敏感，因此补充：

```text
R_peak = max(P_res[earlyIndices]) / (P_signal + eps)
R_peak_dB = 10*log10(R_peak + eps)
```

为降低单个异常 tap 的影响，也可以使用第 90 或第 95 百分位代替最大值。

### 6.3 repetition 时间占用比例

对每个 repetition 计算 First Path 前功率：

```text
E_m = median_k(abs(h_m[k])^2), k in earlyIndices
```

从较低功率 repetitions 估计 packet 内部基线，并统计异常 repetition 比例：

```text
occupancy = count(E_m > T_rep) / M
```

`T_rep` 不宜由全部 repetitions 的均值产生，否则长时间持续干扰会抬高自身阈值。可使用最低 20%～30% repetition、跨 packet 干净基线，或两者结合。

该特征可区分：

- 偶发脉冲；
- 只覆盖部分 QM35 前导的通信包；
- 持续覆盖多数 QM35 前导的通信干扰。

### 6.4 可选补充特征

后续可按实验效果增加：

- `early_to_late_residual_ratio_db`：First Path 前残差与后向 CIR 残差之比；
- `residual_flatness`：残差谱或 CIR tap 的平坦度；
- `repetition_energy_cv`：逐 repetition 前路径能量变异系数；
- `early_excess_kurtosis`：检测少量高能脉冲；
- `raw_input_power`：相关前原始 IQ 功率，仅用于辅助区分 ADC/AGC 异常。

第一版不要引入过多特征，优先实现 residual ratio、peak ratio 和 occupancy 三项。

---

## 7. SIC 决策逻辑

不要让单个特征超阈值直接等价于“必须消除”。建议输出三级状态：

```text
clean       -> 不执行 SIC
suspected   -> 尝试 SIC，并比较消除前后质量
interfered  -> 建议执行 SIC
```

第一版组合逻辑可写为：

```matlab
strongResidual = earlyResidualRatioDb > residualThresholdDb;
highOccupancy  = interferenceOccupancy > occupancyThreshold;
impulsivePeak  = earlyPeakRatioDb > peakThresholdDb;

if strongResidual && highOccupancy
    state = "interfered";
elseif strongResidual || (impulsivePeak && highOccupancy)
    state = "suspected";
else
    state = "clean";
end
```

`occupancyThreshold` 可暂从 0.20 起步，但所有功率阈值必须根据实际数据标定，不应在没有标签的情况下写死为最终值。

输出一个连续置信度比只输出布尔值更有用。可以将各特征相对阈值的 margin 映射到 0～1，但第一版应同时保留原始特征，避免置信度掩盖算法问题。

---

## 8. 建议代码改动

### 8.1 新增分析函数

建议新增：

```text
+uwbdecoder/analyzeCirInterference.m
```

接口建议：

```matlab
diagnostics = uwbdecoder.analyzeCirInterference(cir, options)
```

输入：

- `cir.values`：当前相干平均 CIR；
- `cir.individual_values`：每个 repetition 的 CIR；
- `cir.delay_ns`；
- 阈值、First Path 搜索范围、guard samples 和最小 early taps。

输出字段建议：

```matlab
diagnostics.valid
diagnostics.reason
diagnostics.first_path_index
diagnostics.first_path_delay_ns
diagnostics.first_path_power
diagnostics.early_tap_count
diagnostics.early_noise_power
diagnostics.early_residual_power
diagnostics.signal_power
diagnostics.early_residual_ratio_db
diagnostics.early_peak_ratio_db
diagnostics.interference_occupancy
diagnostics.state
diagnostics.interfered
diagnostics.sic_recommended
diagnostics.confidence
```

建议额外保留调试数组，但不要写入 CSV：

```matlab
diagnostics.residual_power
diagnostics.repetition_early_power
diagnostics.early_indices
```

### 8.2 注意当前 CIR 的幅度尺度不一致

当前 `estimateCir.m` 中：

- `individual_values` 是除以 `reference.code_energy` 后的原始相关幅度；
- `values` 随后又被 `norm(values)` 归一化；
- 因此不能直接用当前 `cir.values` 和 `cir.individual_values` 计算方差公式。

实现时必须统一尺度。推荐在归一化前保存：

```matlab
averageValuesRaw = values;
cir.normalization_norm = norm(averageValuesRaw) + eps;
cir.values_raw = averageValuesRaw;
cir.values = averageValuesRaw / cir.normalization_norm;
```

逐 repetition CIR 同样按 `cir.normalization_norm` 归一化：

```matlab
cir.individual_values = individual / cir.normalization_norm;
```

或者全部干扰统计只使用原始 `individual` 并在分析函数内部计算 `mean(individual,2)`。后一种改动对现有解调侵入更小，也避免改变绘图接口。无论选择哪一种，都必须增加单元测试验证尺度一致性。

### 8.3 调用位置

在 `decode_uwb.m` 获得 `cir` 后执行分析，或在 scheduled dump 的 `decodeOne` 获得 `result.cir` 后执行。推荐先只在 `decode_scheduled_sc16_dump.m` 中启用，以控制影响范围：

```matlab
interference = uwbdecoder.analyzeCirInterference(result.cir, detectorOptions);
```

长期方案可由 `decode_uwb.m` 统一封装到：

```matlab
result.interference.cir_diagnostics
```

但要注意 `result.interference` 当前已有用途，修改前应检查其既有结构，避免覆盖其他干扰处理结果。

### 8.4 scheduled CSV/MAT 输出

在 `decode_scheduled_sc16_dump.m` 的结果结构中增加：

```text
qm35_cir_interference_valid
qm35_first_path_delay_ns
qm35_early_tap_count
qm35_early_residual_ratio_db
qm35_early_peak_ratio_db
qm35_interference_occupancy
qm35_interference_state
qm35_interference_confidence
qm35_sic_recommended
```

完整数组保存在 MAT 中即可，不写入 CSV。

### 8.5 绘图脚本

建议新增按 `packet_index` 选择 packet 的诊断图，例如：

```text
visualize_qm35_cir_interference.m
analyze_qm35_early_energy_stats.m
```

至少绘制：

1. 按 C++ 检测起点对齐的原始 IQ；
2. 相干平均 CIR；
3. 每个 repetition CIR 的幅度热图；
4. `P_res[k]` 与 early window、guard、First Path；
5. 每个 repetition 的 early power 和 repetition threshold；
6. 按 C++ 检测起点对齐的原始 IQ。

---

## 9. 阈值标定与数据标签

### 9.1 必须建立标签

没有通信重叠真值时，只能观察特征分布，不能证明分类正确。应尽量从发送调度、C++ 解调结果、通信包时间范围或人工波形检查中建立：

- `clean`：确认 QM35 前导期间无通信信号；
- `interfered`：确认通信信号覆盖 QM35 前导；
- `partial`：只覆盖部分 repetitions；
- `unknown`：无法确认，不参与阈值训练。

注意：QM35 FCS 成功不能作为“无干扰”标签。通信干扰存在时，QM35 仍可能正确解调。

### 9.2 稳健阈值

对已确认干净包的 `R_early_dB` 建立基线，例如：

```text
T_residual = median(clean_metric) + K * MAD(clean_metric)
```

由于 dB 域和线性域 MAD 的含义不同，代码中必须明确在哪个域标定，并保持训练和运行一致。

建议同时报告：

- clean/interfered 两类直方图；
- ROC 或 precision-recall 曲线；
- 混淆矩阵；
- 按通信覆盖比例分组的召回率；
- 阈值附近 packet 的诊断图。

### 9.3 防止数据泄漏

若同一 capture 中相邻 packet 的信道和干扰高度相关，不能随机把相邻 packet 分散到训练集和验证集。应按 capture 或连续时间段分组划分。

---

## 10. SIC 后闭环验证

干扰检测器只决定“是否值得尝试 SIC”，不能独立证明消除成功。SIC 后至少比较：

- `early_residual_ratio_db` 是否下降；
- `interference_occupancy` 是否下降；
- QM35 SFD correlation 是否提高或保持；
- PHR/FCS 是否保持或改善；
- QM35 主 CIR 路径功率是否被误消除；
- payload 是否仍与 C++ 真值一致。

建议保留原始解调和 SIC 解调两个结果。如果 SIC 后质量恶化，应回退原始 packet，不应强制使用消除结果。

可采用如下接受逻辑：

```text
检测为 suspected/interfered
        |
        v
尝试 SIC 并重新解调
        |
        +-- FCS/PHR 改善且 QM35 主径未受损 --> 接受 SIC 结果
        |
        +-- 指标无改善或恶化 -------------> 回退原始结果
```

---

## 11. 测试与验收标准

### 11.1 单元测试

至少增加以下测试：

1. 只有稳定 QM35 CIR 时，非相干残差接近 0；
2. 加入跨 repetition 随机通信分量时，残差比上升；
3. 干扰只覆盖部分 repetitions 时，occupancy 接近设置比例；
4. 整体幅度缩放后，归一化特征基本不变；
5. First Path 平移 1～2 taps 时，检测结果保持稳定；
6. early window 不足时输出 `valid=false`；
7. 浮点误差不会产生负的 residual power；
8. 关闭干扰诊断时，现有解调结果完全不变。

### 11.2 回归测试

使用当前 100 个 scheduled packet 验证：

- MATLAB 解调仍为 100/100 FCS；
- payload 仍与 C++ 100/100 一致；
- C++ 真值包头映射不变；
- 新增指标不存在无解释的 NaN/Inf；
- 启用诊断不改变 CFO、SFD、PHR、payload 和原有 CIR-CMF 结果；
- 运行时间和 MAT 文件大小增量有明确统计。

### 11.3 分类验收

在建立干扰标签后，再给出最终分类验收标准。至少应关注：

- `interfered` 类漏检率，因为漏检意味着错过 SIC；
- `clean` 类误检率，因为误检会增加计算量并带来误消风险；
- `suspected` 类是否有效覆盖阈值边缘样本；
- SIC 闭环回退是否避免净性能下降。

---

## 12. 推荐实施顺序

1. 只扩大 scheduled 流程的 CIR 前置窗口并保留逐 repetition CIR；
2. 统一平均 CIR 与 individual CIR 的幅度尺度；
3. 实现 `analyzeCirInterference.m`，先输出特征，不立即控制 SIC；
4. 新增 packet-index 诊断绘图；
5. 对 100 个 packet 批量生成特征表并人工检查典型包；
6. 建立 clean/interfered/partial 标签；
7. 标定 residual、peak 和 occupancy 阈值；
8. 输出三级状态及置信度；
9. 接入 SIC 尝试与解调回退逻辑；
10. 完成单元测试、100 包回归测试和分类评估报告。

---

## 13. 给代码执行者的约束

- 不修改 C++ 真值包头映射公式；
- 不恢复 MATLAB 全窗包头搜索作为 scheduled 主路径；
- 不以 FCS 成功代替“无通信干扰”标签；
- 不直接用已归一化的 `cir.values` 和未同尺度的 `individual_values` 计算方差；
- 不只用相干平均 CIR 的 First Path 前幅度作为最终判据；
- 不在没有标签和分布图的情况下固化最终阈值；
- 新算法首先作为旁路诊断，必须证明不改变现有 100/100 解调结果；
- SIC 结果必须支持质量比较和回退。

## 14. 最终结论

利用 First Path 前的 QM35 码相关底噪判断通信干扰在物理上合理，但可靠实现需要利用逐 repetition CIR。推荐核心指标为：

```text
前路径非相干残差功率比
+ 前路径异常峰值比
+ 干扰 repetition 占用比例
```

该方案能够与现有 C++ 真值定时、CFO 补偿和 CIR 解调链路自然结合。第一阶段应只生成诊断特征和标签分析；完成数据标定后，再用三级决策驱动 SIC，并通过 SIC 后重新解调和质量回退保证系统不会因误消而退化。
