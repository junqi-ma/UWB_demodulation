# 脚本与函数索引

> 本文件记录 `F:\USRP数据解调` 下每个 `.m` 文件的用途、输入输出和依赖关系。
> 核心解码函数位于 `+uwbdecoder/` 包内，顶层脚本调用它们完成具体实验。

---

## 数据文件

| 路径 | 说明 |
|------|------|
| `F:\UWB基带数据\DW1000_1.dat` | 纯 DW1000 捕获（单天线，737.28 MHz 采样率） |
| `F:\UWB基带数据\DW1000_2.dat` | 纯 DW1000 捕获（用于全文件消除验证） |
| `F:\UWB基带数据\QM35_1.dat` | 纯 QM35 捕获 |
| `F:\UWB基带数据\qm35_1.dat` | 同上（大小写别名，部分脚本引用） |
| `F:\UWB基带数据\qm35_dw1000_1.dat` | DW1000 + QM35 混合捕获 |
| `F:\UWB基带数据\qm35_worst10_segments\` | QM35 最差 10 段干扰数据的文件夹 |

---

## 1. 核心解码函数（`+uwbdecoder/` 包）

这些是纯函数，不直接运行，由顶层脚本调用。

| 文件 | 功能 |
|------|------|
| `constants.py` | 物理/协议常量（字节/采样、int16 范围、HRP 前导周期、光速） |
| `defaultOptions.m` | 返回默认解码器配置结构体 |
| `mergeOptions.m` | 合并用户覆盖选项并校验 |
| `readIqRaw.m` | 从捕获文件读取交织 int16 IQ（统一文件 I/O） |
| `selectIqChannel.m` | 从交织 IQ 中提取一个通道为复向量 |
| `synchronousTone.m` | 生成采样时钟同步的复指数音调 |
| `ieee802154CRC16.m` | 计算 IEEE 802.15.4 反射 CRC-16 |
| `readAndCancelInterference.m` | 读取捕获并消除已知窄带音调 |
| `compensateCenterFrequency.m` | 将 DW1000 载波搬移到基带 DC |
| `buildUwbReference.m` | 构建 HRP 波形和稀疏扩频码参考 |
| `resampleCapture.m` | 将 X410 采样率转换到 HRP 工作速率 |
| `detectRepeatedPreamble.m` | 检测并跟踪重复的 SYNC 符号 |
| `validateCaptureLength.m` | 校验捕获是否包含完整 SHR |
| `cropToFrame.m` | 裁剪工作缓冲区到活跃帧区域 |
| `estimateFrameSampleSpan.m` | 计算软芯片/裁剪预算 |
| `compensateCarrierOffset.m` | 估计 CFO 并补偿复相位 |
| `refineTimingWithNsSfd.m` | 选择 SFD 模板并精化帧定时 |
| `analyzeNsSfdSymbols.m` | 在符号分辨率下评估 SFD 定时 |
| `estimateCirAndSoftChips.m` | 解扩前导码、平均 CIR、切片软芯片 |
| `locateNsSfd.m` | 在软芯片流中定位 SFD |
| `decodePhrAndPayload.m` | 解码 PHR、PSDU 和 FCS |
| `packageResult.m` | 将各阶段输出打包为公共结果结构体 |
| `applyBlankIntervals.m` | 对绝对捕获区间做软消隐 |
| `plotPreambleDetection.m` | 可视化前导码匹配结果 |
| `plotDespreadCir.m` | 可视化解扩 CIR |
| `plotSfdDetection.m` | 可视化 SFD 搜索度量 |

---

## 2. 顶层解码函数

| 文件 | 行数 | 功能 | 输入 |
|------|------|------|------|
| `decode_uwb.m` | 72 | 单包解码入口，串联所有解码阶段 | `options` 结构体 |
| `decode_uwb_all.m` | 637 | 全文件扫描：粗筛 + 细解码所有包 | `options` + `batch` 结构体 |
| `generate_qm35_tx_from_decode.m` | 257 | 从解码 PSDU 重建 QM35 发射波形 | `decoded` 结构体 |
| `apply_estimated_cir_to_qm35.m` | 62 | 用测量 CIR 替换 QM35 成形脉冲 | `tx` + `cir` 结构体 |

---

## 3. 数据 I/O 工具

| 文件 | 行数 | 功能 |
|------|------|------|
| `read_x410.m` | 59 | 快速查看捕获文件：时域波形 + 频谱 |
| `write_x410_iq_int16.m` | 43 | 将复向量写为交织 int16 IQ 文件 |
| `read_dw1000_cancelled_dat.m` | 171 | 读取消除前后的捕获，对比时域/频谱 |

---

## 4. 单包解码工作流

| 文件 | 行数 | 功能 | 数据文件 |
|------|------|------|----------|
| `run_decode_smoke_test.m` | 83 | 无交互烟雾测试，输出 pass/fail | `DW1000_1.dat` |
| `run_decode_uwb.m` | 379 | 单包解码 + 各阶段计时分析 | `DW1000_1.dat` |
| `run_decode_and_regenerate_qm35.m` | 161 | 解码一帧 QM35 并重建其发射波形 | `QM35_1.dat` |
| `run_analyze_dw1000_preamble_phase.m` | 176 | DW1000 前导码原始相关与相位稳定分析 | `DW1000_1.dat` |

---

## 5. 全文件扫描工作流

| 文件 | 行数 | 功能 | 数据文件 |
|------|------|------|----------|
| `run_decode_uwb_all.m` | 208 | 全文件 UWB 包扫描，保存所有 CIR | `QM35_1.dat` |
| `run_decode_all_qm35_in_mix.m` | 338 | 混合捕获中解码所有 QM35 包 | `qm35_dw1000_1.dat` |
| `run_decode_all_qm35_with_ic.m` | 615 | QM35 解码 + 间隙填充干扰抑制 | `qm35_dw1000_1.dat` |
| `run_find_first_qm35_in_mix.m` | 557 | 在混合捕获中找到第一个 QM35 包 | `qm35_dw1000_1.dat` |
| `run_search_n_qm35_preamble_corr.m` | 740 | 5 ms 网格搜索 N 个 QM35 包（固定窗口） | `qm35_dw1000_1.dat` |
| `run_search_qm35_periodic_cir.m` | 787 | 周期性 QM35 搜索 + CIR 估计（5 ms 间隔） | `qm35_dw1000_1.dat` |

---

## 6. 消除工作流

| 文件 | 行数 | 功能 | 数据文件 |
|------|------|------|----------|
| `run_cancel_all_dw1000_in_capture.m` | 708 | 全文件 DW1000 帧再生与消除（含验证模式） | `DW1000_2.dat` |
| `cancel_qm35_with_regenerated.m` | 253 | 从捕获 IQ 中减去重建的 QM35 | 通用 |
| `compare_qm35_original_and_generated.m` | 254 | 对比捕获与重建的 QM35 IQ | 通用 |
| `visualize_x410_tone_cancellation.m` | 193 | 可视化 X410 音调消除效果（不写文件） | `qm35_1.dat` |

---

## 7. 分析 / 探索脚本

| 文件 | 行数 | 功能 | 数据文件 |
|------|------|------|----------|
| `analyze_x410_interference.m` | 173 | 无 UWB 区间的窄带干扰分析 | `qm35_1.dat` |
| `analyze_worst_qm35_raw_signal.m` | 513 | 可视化最差 QM35 干扰段的原始 IQ | `qm35_worst10_segments\` |
| `analyze_qm35_cancellation_steps.m` | 1072 | 逐步再生信号消除分析（保留所有中间变量） | 通用 |
| `plot_qm35_estimated_cir.m` | 110 | 绘制平均/逐次 QM35 CIR 细节 | 通用 |
| `run_view_qm35_dw1000_1_time.m` | 394 | 冲突对齐窗口的时域 IQ + QM35 CIR 查看 | `qm35_dw1000_1.dat` |
| `UWB_decoding_despread.m` | 462 | 扩频解扩与解码实验（早期探索代码） | 通用 |

---

## 依赖关系图

```
数据文件 (.dat)
    │
    ▼
┌─────────────────────────────────────────────┐
│  数据 I/O 工具                               │
│  read_x410 / write_x410_iq_int16            │
│  read_dw1000_cancelled_dat                  │
└──────────────┬──────────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────────┐
│  顶层解码函数                                │
│  decode_uwb                         │
│  decode_uwb_all                     │
│  generate_qm35_tx_from_decode               │
│  apply_estimated_cir_to_qm35                │
└──────────────┬──────────────────────────────┘
               │ 调用
               ▼
┌─────────────────────────────────────────────┐
│  +uwbdecoder 包（26 个函数）              │
│  constants / defaultOptions / mergeOptions  │
│  readIqRaw / selectIqChannel / synchronousTone │
│  readAndCancelInterference / compensateCenterFrequency │
│  buildUwbReference / resampleCapture     │
│  detectRepeatedPreamble / validateCaptureLength │
│  cropToFrame / estimateFrameSampleSpan      │
│  compensateCarrierOffset / refineTimingWithNsSfd │
│  analyzeNsSfdSymbols / estimateCirAndSoftChips │
│  locateNsSfd / decodePhrAndPayload          │
│  packageResult / applyBlankIntervals        │
│  plot* (3 个可视化)                          │
└─────────────────────────────────────────────┘
```

---

## 快速上手

| 目标 | 运行 |
|------|------|
| 验证解码器是否正常工作 | `run_decode_smoke_test` |
| 查看某个捕获文件的时域/频谱 | 修改 `read_x410.m` 中的 `file_name`，运行 |
| 解码单个 DW1000 包并看各阶段耗时 | `run_decode_uwb` |
| 全文件扫描所有 DW1000 包 | `run_decode_uwb_all` |
| 消除全文件 DW1000 帧（先验证） | `run_cancel_all_dw1000_in_capture`（默认 validation.enabled=true） |
| 解码混合捕获中的 QM35 包 | `run_decode_all_qm35_in_mix` |
| 对比消除前后效果 | `read_dw1000_cancelled_dat` |
