# QM35 → DW1000 SIC pipeline

入口文件：

```matlab
sic_pipeline/run_qm35_dw1000_sic_pipeline.m
```

`uwbSicPipeline.m` 是入口调用的核心函数，不作为 `run_` 入口脚本。

## SIC 本地 decode / cancel 工具（fork）

SIC **不再调用根目录** 的 decode/cancel 入口。下列文件是从根目录复制到
`sic_pipeline/` 的独立副本，后续只在此目录内修改，以免影响根目录通用流程：

| 文件 | 角色 |
|------|------|
| `run_decode_uwb_all.m` | 全文件解调入口（被 pipeline 调用） |
| `decode_uwb_all.m` | 能量扫描 + 多候选精解 |
| `decode_uwb.m` | 单包解调 |
| `run_cancel_all_uwb_packets.m` | 全文件消除入口（被 pipeline 调用） |
| `generate_uwb_tx_from_decode.m` | 从 PSDU 再生发射波形 |
| `apply_estimated_cir_to_uwb.m` | CIR 卷积到再生波形 |
| `estimate_uwb_cir_slow_phase.m` | CIR 慢相位估计 |
| `estimate_uwb_full_packet_sfo.m` | 全包 SFO 估计 |
| `apply_uwb_full_packet_sfo.m` | 全包 SFO 应用 |
| `+uwbdecoder/` | 解调原语包（SIC 本地 fork） |

路径约定：

- `addpath(sic_pipeline)` 放在 `addpath(project_root)` **之后**，使本地
  同名函数与 `+uwbdecoder` 优先于根目录版本。
- `helpers/` 仍共用仓库根目录（MathWorks UWB helper），不在此 fork。
- PLL 模板、`decoded_results/` 仍写在仓库根目录下。

独立可视化脚本：

- `visualize_UwbSicPipeline.m`：packet 数量、逐包 suppression，以及
  QM35/DW1000 packet 的发送时间。
- `visualize_sic_signal_comparison.m`：对比一段可配置时长内的原始混叠
  信号与“去同步单音、去 DW1000、保留 QM35”的信号。

10 ms 诊断入口：

```matlab
sic_pipeline/run_sic_diagnostic_10ms.m
```

该入口把指定的 10 ms 原始区间复制到独立目录，运行完整 SIC，并输出
逐候选解调状态、异常信息、FCS/SFD 统计以及逐包 cancellation 失败原因。

流水线固定执行：

1. 从原始混叠 capture 解码 QM35。合并能量区间内的全部相关候选
   都进入独立的完整解调窗口，避免密集 QM35/DW1000 只保留一个
   packet。PLL 补偿固定覆盖前 10 个 preamble repetition，逐
   repetition CIR 从第 11 个开始保存。
2. 去除同步单音并暂时消除可靠的 QM35 packet，生成
   `qm35_removed.dat`，用于暴露和解码 DW1000。
3. 从 `qm35_removed.dat` 使用 code 11 解码、拟合 DW1000；同样采用
   PLL 1–10、CIR 11 之后的交接边界。
4. 从原始混叠 capture 去除同步单音和拟合出的 DW1000，但不减
   QM35，生成 `dw1000_removed_qm35_preserved.dat`。
5. 两个 PHY 的消除均启用 CIR 慢相位补偿、由 CIR 线性趋势得到的
   二级 CFO，以及 full-packet SFO 仿射时间校正。
6. 保存 manifest、CSV 汇总和 suppression 图。

所有阶段使用显式路径，不再通过中间文件的 stem 猜测结果目录。

## 输出目录

```text
sic_dw1000_removed_qm35_preserved/
├─ pipeline_manifest.mat
├─ pipeline_summary.csv
├─ 01_qm35_decode/
├─ 02_qm35_cancel/
├─ 03_dw1000_decode/
├─ 04_dw1000_cancel/
└─ 05_validation/
```

`cfg.resume = true` 时，只复用输入路径、PHY、PLL/CIR 边界、CFO2/SFO
配置和文件长度均通过验证的完整阶段。旧算法产物会被判定为不兼容。
默认的 `cfg.overwrite = false` 会阻止覆盖完整或不完整的已有阶段。
首次升级已有结果时，请设置 `cfg.overwrite = true`；流水线会自动重建不兼容
阶段。完成后可恢复为 `false`。
