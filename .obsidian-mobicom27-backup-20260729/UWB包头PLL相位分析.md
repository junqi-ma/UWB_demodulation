---
title: UWB包头PLL相位漂移一致性与Cancellation机会分析
date: 2026-07-29
tags:
  - MobiCom27
  - UWB
  - PLL
  - Cancellation
  - DW1000
  - QM35
status: completed
---

# UWB包头PLL相位漂移一致性与Cancellation机会分析

## 结论

DW1000 和 QM35 的 UWB packet 开头都存在高度可重复的非线性相位瞬态。移除每个 packet 各自的常数初相和稳定 CFO 后：

| 设备 | 有效 packet 数 | 前 24 个 SYNC 的相位一致性 | 第 1 个 SYNC 的平均相位偏差 | 留一法模板收益中位数 | 得到改善的 packet |
|---|---:|---:|---:|---:|---:|
| DW1000 | 955 | 0.999 | -37.59° | +2.60 dB | 100.0% |
| QM35 | 1409 | 0.997 | -39.63° | +0.90 dB | 95.7% |

其中，相位一致性使用 circular mean resultant length 衡量，取值范围为 0–1，越接近 1 表示不同 packet 的相位轨迹越一致。

因此：

1. 两种芯片的包头相位瞬态在各自设备内部高度一致。
2. 该相位瞬态可以作为确定性模板加入再生波形。
3. 留一 packet 验证已经表明，模板对未参与训练的 packet 仍然有效，并非对同一批数据过拟合。
4. 当前最值得优先实现的是 DW1000 模板补偿，其收益更大且所有 packet 均得到改善。

需要注意：本实验观察到的是“与 PLL settling 相符的、可重复的包头非线性相位误差”。仅凭当前基带数据还不能排除 PA 启动、模拟前端群时延变化等其他确定性启动瞬态，因此下文简称为 PLL 相位漂移，但不将其作为硬件成因的最终证明。

## 分析方法

分析直接读取 `run_cancel_all_uwb_packets.m` 当前生成的 cancellation 结果。

对每个 packet：

1. 从 fitting capture 和 cancelled capture 读取相同的 preamble 区域。
2. 通过下式恢复 cancellation 使用的再生模型：

   $$
   x_{\mathrm{model}}=x_{\mathrm{fitting}}-x_{\mathrm{cancelled}}
   $$

3. 对每个 SYNC repetition 的强信号采样点计算复数最小二乘比值：

   $$
   q_k=\frac{\sum_n x_{\mathrm{model},k}^{*}[n]x_{\mathrm{rx},k}[n]}
   {\sum_n|x_{\mathrm{model},k}[n]|^2}
   $$

   其中 $\angle q_k$ 表示接收信号相对当前 cancellation 模型的相位误差。

4. 在 preamble 的稳定后半段拟合每个 packet 自己的常数初相和线性 CFO，并从整条相位轨迹中移除。剩余的非线性相位分量才作为 PLL settling 候选。
5. 使用 circular statistics 比较不同 packet 的相位轨迹。
6. 对每个目标 packet，使用“除目标 packet 以外的所有 packet”建立相位模板，再计算目标 packet 的预期 cancellation suppression。该 leave-one-packet-out 测试避免了训练与测试使用同一个 packet。

DW1000 使用第 64–128 个 SYNC 拟合稳定相位直线，QM35 使用第 32–64 个 SYNC；两者均使用前 24 个 SYNC 评价包头模板。

## DW1000 结果

![[UWB包头PLL相位漂移附件/dw1000_pll_phase_drift_analysis.png]]

分析数据为 `dw1000_new_3`，共 955 个成功 cancellation 的 packet。

主要观察：

- 第一个 SYNC repetition 的平均相位偏差为 -37.59°。
- 随后出现幅度逐渐衰减的相位振铃，并在约 20–25 μs 后基本稳定。
- 前 24 个 repetition 的一致性中位数为 0.9991，最低值仍为 0.9988。
- 固定模板使包头 suppression 的中位数提高 2.60 dB。
- 955 个 packet 全部获得正收益。
- 相比仅重新拟合每包稳定常数相位/CFO，加入非线性模板仍额外提高 2.77 dB，说明收益确实来自包头相位轨迹，而不是普通 CFO 重拟合。

DW1000 的相位轨迹具有明显的确定性振铃结构，是目前最有价值的模板补偿对象。

## QM35 结果

![[UWB包头PLL相位漂移附件/qm35_pll_phase_drift_analysis.png]]

分析数据为 `qm35_new_3`，共 1409 个成功 cancellation 的 packet。

主要观察：

- 第一个 SYNC repetition 的平均相位偏差为 -39.63°。
- 主要瞬态集中在 packet 启动后的前几个 repetition，之后平均相位迅速接近 0°。
- 前 24 个 repetition 的一致性中位数为 0.9973，最低值为 0.9960。
- 固定模板使包头 suppression 的中位数提高 0.90 dB。
- 95.7% 的 packet 获得正收益。
- 相比仅重新拟合每包稳定常数相位/CFO，非线性模板额外提高 1.00 dB。

QM35 的跨包一致性同样很高，但除第一个 repetition 外，平均非线性漂移较小，因此最终 cancellation 收益低于 DW1000。

## 如何加入 Cancellation

设原 cancellation 使用的再生波形为 $s[n]$，将 repetition 级模板插值到采样级得到 $\phi_{\mathrm{PLL}}[n]$，补偿后的波形为：

$$
s_{\mathrm{corrected}}[n]
=s[n]\exp\left(j\phi_{\mathrm{PLL}}[n]\right)
$$

建议实现方式：

1. 分别保存 DW1000 和 QM35 模板，不跨设备共用。
2. 模板时间零点绑定 `abs_start_fitted`，而不是初始检测位置 `abs_start_detected`。
3. 先对 repetition 级模板进行平滑，再插值到 X410 采样率。
4. 仅在 preamble 开头启用模板；模板稳定后平滑回到 0°，避免影响 SFD、PHR 和 Payload。
5. 将模板补偿放在 fractional delay、CFO 和 global complex gain 之后，再执行最终 subtraction。
6. 保留开关，同时输出：
   - 原始 cancellation suppression；
   - 仅稳定相位/CFO 重拟合后的 suppression；
   - 加入 PLL 模板后的 suppression。

## 风险与后续验证

- 当前收益是依据现有 cancellation 模型计算的离线 leave-one-packet-out 结果，还需要把模板真正接入 cancellation pipeline 后重新生成 `.dat` 文件验证。
- 模板可能与设备、信道、温度、发射功率、packet 间隔以及上电状态有关。至少应在 `new_1/new_2/new_3` 和不同功率配置之间做交叉训练/测试。
- 当前模板是 repetition 级相位估计。若要进一步提高第一个 SYNC 内部的消除效果，需要研究更细的 sub-repetition 相位轨迹。
- 应验证模板不会降低稳定 preamble、SFD、PHR 和 Payload 区域的 cancellation。
- 如果跨 capture 模板仍然稳定，可以在在线系统中直接使用固定标定模板；否则需要按 capture 或按温度状态选择模板。

## 产物

- 分析脚本：`analyze_uwb_pll_phase_drift.m`
- 总结数据：`decoded_results/pll_phase_drift_analysis/summary.csv`
- 每 packet 指标：`packet_phase_drift.csv`
- repetition 相位模板：`repetition_phase_template.csv`
- 完整 MATLAB 数据：`pll_phase_drift_analysis.mat`

