---
title: UWB包头PLL相位漂移一致性与Cancellation机会分析
date: 2026-07-29
updated: 2026-07-29
project: "[[MobiCom27-规划]]"
type: analysis
summary: 验证 DW1000 与 QM35 包头相位瞬态的跨 packet 一致性，并比较 repetition 与 sub-SYNC 两种模板的 cancellation 潜力。
tags:
  - project/mobicom27
  - UWB
  - PLL
  - Cancellation
  - DW1000
  - QM35
status: in-progress
---

# UWB包头PLL相位漂移一致性与Cancellation机会分析

## 最新结论

DW1000 和 QM35 的 packet 开头都存在高度可重复的非线性相位瞬态，但它并不是“每个 SYNC 内相位恒定”的慢漂移。尤其在第一个约 1.018 μs 的 SYNC 内，相位可以快速变化超过 100°。

原来的 repetition 级分析把一个 SYNC 内的所有强样本做复相关，只得到一个平均相位。这个平均值没有算错，但时间分辨率不足，无法解释或补偿 `Strong peak phase error` 最开始接近 100° 的现象。

将每个 SYNC 划分为 32 个 bin 后，时间分辨率提高到约 31.80 ns。细粒度结果显示：

| 设备 | Packet 数 | 第一个细分 bin | 细分相位一致性中位数 | 旧模板早期收益 | 细粒度模板早期收益 |
|---|---:|---:|---:|---:|---:|
| DW1000 | 955 | -112.03° | 0.996 | +2.60 dB | +4.38 dB |
| QM35 | 1409 | +21.35°，随后跨越 ±180° | 0.997 | +0.90 dB | +7.06 dB |

表中的收益是前 24 个 SYNC 内强信号 bin 的 leave-one-packet-out 离线结果，不是整包 suppression。

目前可以得到三个明确判断：

1. 原 repetition 级模板的符号和平均值正确。
2. 包头剩余误差主要来自第一个 SYNC 内部的快速相位变化，而不是模板正负号错误。
3. cancellation 应改用 sub-SYNC 模板，而不是在整个 SYNC 内保持一个固定补偿角。

> [!important]
> 当前 `run_cancel_all_uwb_packets.m` 仍使用 repetition 级模板。细粒度模板已经生成，但尚未接入正式 cancellation pipeline。

## 信号与分析定义

分析读取 `run_cancel_all_uwb_packets.m` 生成的 fitting capture 和 cancelled capture，通过

$$
x_{\mathrm{model}}[n]
=x_{\mathrm{fitting}}[n]-x_{\mathrm{cancelled}}[n]
$$

恢复 cancellation 实际减去的再生模型。

在一个分析窗口 $\mathcal B$ 中计算：

$$
q_{\mathcal B}
=\sum_{n\in\mathcal B}
x_{\mathrm{model}}^{*}[n]x_{\mathrm{rx}}[n]
$$

则 $\angle q_{\mathcal B}$ 表示接收信号相对再生模型的相位误差。

每个 packet 的稳定 preamble 后半段用于拟合常数相位和线性 CFO：

- DW1000：第 64–128 个 SYNC；
- QM35：第 32–64 个 SYNC。

从原始相位中移除这条稳定直线后，剩余非线性部分作为 packet-start settling phase。这样不会把 packet 间不同的初相或 CFO 误认为固定 PLL 模板。

跨 packet 一致性使用 circular mean resultant length 衡量：

- 1：所有 packet 相位完全一致；
- 0：相位近似随机分布。

模板收益使用 leave-one-packet-out 验证：目标 packet 不参与自己的模板估计。

## 为什么旧模板只有约 -40°

旧算法每个 SYNC 只输出一个相位值：

$$
\phi_k
=\angle\left(
\sum_{n\in \mathrm{SYNC}_k}
x_{\mathrm{model}}^{*}[n]x_{\mathrm{rx}}[n]
\right)
$$

以 DW1000 packet 1 的第一个 SYNC 为例：

- 最早强样本真实相位误差：约 -107.44°；
- 整个第一个 SYNC 的复相关平均相位：约 -35.98°；
- 旧模板补偿：约 -37.59°；
- 补偿后整 SYNC 平均残差：约 +1.61°；
- 最早强样本补偿后仍剩：约 -69.86°。

因此旧模板在“整个 SYNC 的平均意义”上非常准确，但无法修正 SYNC 内部从约 -110°快速变化到约 -10°的过程。这正是可视化中平均模板接近 -40°、逐采样 `Strong peak phase error` 却接近 100°的原因。

## Repetition 级结果

### DW1000

![[UWB包头PLL相位漂移附件/dw1000_pll_phase_drift_analysis.png]]

`dw1000_new_3` 共 955 个有效 packet：

- 前 24 个 SYNC 的一致性中位数：0.9991；
- 第一个 SYNC 平均相位：-37.59°；
- repetition 级 leave-one-packet-out 早期收益：+2.60 dB；
- 100% packet 得到改善。

### QM35

![[UWB包头PLL相位漂移附件/qm35_pll_phase_drift_analysis.png]]

`qm35_new_3` 共 1409 个有效 packet：

- 前 24 个 SYNC 的一致性中位数：0.9973；
- 第一个 SYNC 平均相位：-39.63°；
- repetition 级 leave-one-packet-out 早期收益：+0.90 dB；
- 95.7% packet 得到改善。

## Repetition 模板的真实整包验证

repetition 模板已经接入 `run_cancel_all_uwb_packets.m`，并使用独立 `_pll` 输出完成全文件验证：

| 设备 | Packet 数 | 整包 suppression 提升中位数 | 最小提升 | 最大提升 | 改善比例 |
|---|---:|---:|---:|---:|---:|
| DW1000 | 955 | +0.531 dB | +0.195 dB | +0.826 dB | 100% |
| QM35 | 1409 | +0.292 dB | +0.032 dB | +0.447 dB | 100% |

整包收益小于“前 24 个 SYNC”的离线收益是正常的，因为 PHR 和 Payload 没有应用 PLL 模板，整包功率统计会稀释包头改善。

该结果同时证明：

- 模板相位符号正确；
- 模板没有破坏后续字段；
- 每个 packet 都获得正收益；
- 主要剩余问题是模板时间分辨率，而不是补偿方向。

## Sub-SYNC 细粒度分析

每个 SYNC 被划分为 32 个 bin：

$$
T_{\mathrm{bin}}
=\frac{1016/998.4\ \mathrm{MHz}}{32}
\approx 31.80\ \mathrm{ns}
$$

每个 bin 复用该 repetition 的强样本门限。没有有效 UWB 脉冲或跨 packet 支持不足的 bin 不直接估计相位，而是根据相邻可靠 bin 的连续相位进行插值。

### DW1000

![[UWB包头PLL相位漂移附件/dw1000_pll_subsync_phase_drift_analysis.png]]

第一个 SYNC 的部分模板值：

| 时间 | 相位 |
|---:|---:|
| 0.0159 μs | -112.03° |
| 0.0477 μs | -94.24° |
| 0.0795 μs | -90.85° |
| 0.1431 μs | -74.28° |
| 0.1749 μs | -67.97° |
| 0.2385 μs | -50.79° |
| 0.3021 μs | -46.55° |
| 0.3657 μs | -40.30° |

主要结果：

- 细分 bin 一致性中位数：0.9961；
- 第一个 bin：-112.03°；
- 细粒度 leave-one-packet-out 早期收益：+4.38 dB；
- 100% packet 获得改善。

该轨迹与最早强样本约 -107°的直接测量一致。

### QM35

![[UWB包头PLL相位漂移附件/qm35_pll_subsync_phase_drift_analysis.png]]

QM35 在第一个 SYNC 内的相位旋转更剧烈：

| 时间 | 相位 |
|---:|---:|
| 0.0159 μs | +21.35° |
| 0.0477 μs | +78.79° |
| 0.0795 μs | +103.40° |
| 0.1113 μs | +142.94° |
| 0.1431 μs | +172.68° |
| 0.1749 μs | -154.07° |
| 0.2067 μs | -139.12° |
| 0.3021 μs | -75.72° |

从 +172.68° 到 -154.07° 是相位 wrap，不是物理相位突变。补偿使用

$$
\exp\left(j\phi_{\mathrm{PLL}}[n]\right)
$$

因此 ±180° 边界不会造成复波形跳变。

主要结果：

- 细分 bin 一致性中位数：0.9967；
- 细粒度 leave-one-packet-out 早期收益：+7.06 dB；
- 99.9% packet 获得改善。

QM35 的 repetition 平均相位接近 -40°，但这个平均值掩盖了第一个 SYNC 内超过 300°的连续旋转。

## 如何接入 Cancellation

设完成 fractional delay 和 CFO 补偿后的再生信号为 $s[n]$，使用细粒度模板：

$$
s_{\mathrm{corrected}}[n]
=s[n]\exp\left(j\phi_{\mathrm{PLL}}[n]\right)
$$

建议实现顺序：

1. 整数与 fractional sample alignment；
2. 稳定 preamble CFO 补偿；
3. DW1000/QM35 各自的 sub-SYNC PLL phase template；
4. global complex gain；
5. PHR/Payload field gain；
6. subtraction。

具体要求：

- 模板时间零点必须绑定 `abs_start_fitted`；
- 读取 `subsync_phase_template.csv` 中的 `applied_template_phase_deg`；
- 将 31.80 ns bin 模板映射到 X410 sample grid；
- 补偿应使用复指数，不能直接对 wrap 后的角度做普通线性插值；
- 仅对前 24 个 SYNC 应用模板；
- 对无脉冲 bin 的相位使用脚本输出的连续插值值；
- 保留无模板与有模板的同包 A/B 指标。

## 风险与后续验证

1. 细粒度收益目前仍是早期强信号 bin 的离线 leave-one-packet-out 结果，需要接入 pipeline 后重新生成 `.dat` 做整包验证。
2. 当前 bin 宽度为 31.80 ns。若第一个 bin 内仍有明显相位变化，可继续提高到 64 bin/SYNC，但有效强样本数量会下降。
3. 模板可能随设备个体、温度、发射功率、packet 间隔或上电状态变化，需要在 `new_1/new_2/new_3` 之间做跨 capture 训练与测试。
4. 强样本逐点相位也会受到 fractional timing、CIR 和低幅度样本影响，因此模板仍使用 bin 内复相关，而不是直接平均逐点角度。
5. 如果跨 capture 模板不稳定，应按设备状态选择模板或在线更新，而不能使用单一全局模板。

## 产物

- 分析脚本：`analyze_uwb_pll_phase_drift.m`
- repetition 模板：`repetition_phase_template.csv`
- sub-SYNC 模板：`subsync_phase_template.csv`
- 每 packet 指标：`packet_phase_drift.csv`
- 总结：`decoded_results/pll_phase_drift_analysis/summary.csv`
- 完整 MATLAB 数据：`pll_phase_drift_analysis.mat`
- repetition 模板 cancellation 输出：`cancelled_optimal_complex_pll.dat`
- repetition 模板 cancellation 报告：`cancelled_optimal_complex_pll_summary.csv`

`subsync_phase_template.csv` 关键列：

- `raw_template_phase_deg`：有真实观测支持的 circular mean；
- `applied_template_phase_deg`：补齐无脉冲区后可用于 cancellation 的模板；
- `resultant_length`：跨 packet 相位一致性；
- `valid_packets`：该 bin 的有效 packet 数；
- `reliable`：是否满足模板可靠性门限。

## 关联笔记

- 项目主页：[[MobiCom27-规划]]
- 单音相位噪声：[[DW1000单音相位噪声与Cancellation影响分析]]
- 管线开发记录：[[7月14日-7月27日工作记录]]
- 实验计划：[[7月28日实验计划]]
