# X410 UWB 数据解调说明

本项目用于解调 X410 采集的 DW1000/QM35825 UWB 基带数据，支持 Decawave、IEEE legacy/BPRF 和 IEEE 802.15.4z SFD 自动识别。

## 入口文件

- `run_decode_uwb.m`：分步骤运行，保留各阶段变量，便于调试。
- `decode_uwb.m`：函数式入口，返回完整 `result` 结构体。
- `run_decode_uwb_all.m`：滑窗扫描整段 `.dat`，解调全部报文并保存 CIR。
- `decode_uwb_all.m`：全文件解调函数入口。
- `+uwbdecoder/`：各解调模块的具体实现。
- GNU Radio 周期截窗 dump 格式：[[GNURadio_scheduled_SC16_dump数据解读]]。
- 入口：`run_decode_scheduled_sc16_dump.m`。

## 解调流程

1. 读取已经预处理到 998.4 MHz 的 IQ 数据。
2. 生成前导码和扩频码参考波形。
3. 检测重复前导符号，估计定时和采样时钟误差。
4. 估计并补偿载波频偏与相位偏差。
5. 比较当前 PHY/code family 允许的 SFD，自动选择相关性更高的模板。
6. 估计 CIR，并形成软判决码片序列。
7. 定位 SFD，随后解码 PHR、PSDU 和 FCS。

## 关键配置

```matlab
options.file_name = 'F:\UWB基带数据\QM35_1.dat';
options.sample_num = 0.5e6;

options.fs_rx = 998.4e6;

options.preamble_repetitions = 128;
options.cir_repetitions = 128;
options.code_index = 9;
options.data_rate = 6.81;

options.sfd_mode = 'auto';
```

`sfd_mode` 可设置为：

- `'auto'`：按 PHY/code family 自动比较合法候选，推荐用于未知发射配置。
- `'decawave'`：固定使用 Decawave DW-8。
- `'ieee'`：固定使用 IEEE legacy/BPRF SFD #0。
- `'4z1'`～`'4z4'`：固定使用 IEEE 802.15.4z SFD #1～#4。

两种短 SFD 序列为：

```matlab
% Decawave DW-8
[-1; -1; -1; -1; 1; -1; 0; 0]

% IEEE 802.15.4
[0; 1; 0; -1; 1; 0; 0; -1]

% IEEE 802.15.4z SFD #2（QM35_1.dat 实测匹配）
[-1; -1; -1; 1; -1; -1; 1; -1]
```

## 运行方法

需要逐步观察中间结果时，直接运行：

```matlab
run_decode_uwb
```

需要通过函数调用时：

```matlab
options = struct();
options.file_name = 'F:\UWB基带数据\QM35_1.dat';
options.preamble_repetitions = 128;
options.cir_repetitions = 128;
options.sfd_mode = 'auto';

result = decode_uwb(options);
```

需要扫完整段采集文件时，直接运行：

```matlab
run_decode_uwb_all
```

或：

```matlab
results = decode_uwb_all(options, batch);
```

全文件流程（P0）：

1. **粗检**：大块读取（默认 4e6 点，步进 3e6），降采样能量门限 + 可选降采样前导相关，只保留候选起点。
2. **精解**：仅对候选调用 `decode_uwb`，成功后跳过该包覆盖区间。
3. **存盘**：CIR 与帧摘要。

常用加速参数（`batch`）：

| 参数 | 默认 | 说明 |
|------|------|------|
| `coarse_chunk_samples` | `4e6` | 粗检块长 |
| `coarse_step_samples` | `3e6` | 粗检步进（保留重叠） |
| `coarse_decimation` | `32` | 粗检降采样 |
| `energy_threshold_sigma` | `6` | 能量门限 = median + k·MAD |
| `use_coarse_correlation` | `true` | 能量区再做前导相关 |
| `window_samples` | `0.8e6` | 候选处精解窗长 |

全文件结果默认写到 `decoded_results/<capture>_<profile>/`（如 `qm35_1_qm35/`）：

- `all_frames_cir.mat`：所有帧摘要 + `cir_values` 矩阵 + 粗检候选
- `frame_summary.csv`：每帧时间、SFD、FCS、payload 摘要
- `cir_XXX.mat`：单帧 CIR（可在 `batch.save_individual_cir` 关闭）

## 主要输出

- `result.preamble`：前导检测、频偏、时钟误差和满速 SFD 相关结果。
- `result.sfd`：选中的 SFD、起止码片位置和相关系数。
- `result.cir`：信道冲激响应及平均次数。
- `result.phr`：PHR SECDED 状态和 PSDU 长度。
- `result.payload`：PSDU 字节、接收 FCS、计算 FCS 和校验结果。

## QM35_1.dat 实测结论

- 实际 SYNC 长度为 **128 symbols**；配置为 256 会使 SFD 定位晚 128 个符号。
- IEEE 802.15.4z SFD #2 满速相关约为 **0.892**，长度为 8 symbols。
- 符号级相关约为 **0.999**，软码片相关约为 **0.866**。
- 16-symbol SFD #3 相关约为 **0.235**，不符合当前采集。
- 当前数据应自动选择 **IEEE 802.15.4z SFD #2**。
- PHR 解出 PSDU 长度 **14 bytes**，接收与计算 FCS 均为 **0x6943**，校验通过。

## 调试重点

SFD 相关较低时，优先检查：

1. `preamble_repetitions` 是否与实际 SYNC 长度一致。
2. `code_index`、中心频率和数据率是否匹配发射端。
3. 两种 SFD 的相关系数是否都偏低。
4. CIR 平均范围是否包含 SFD 或数据段。
