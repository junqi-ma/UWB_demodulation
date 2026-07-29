# QM35 → DW1000 SIC pipeline

入口文件：

```matlab
sic_pipeline/run_qm35_dw1000_sic_pipeline.m
```

`uwbSicPipeline.m` 是入口调用的核心函数，不作为 `run_` 入口脚本。

独立可视化脚本：

- `visualize_UwbSicPipeline.m`：packet 数量、逐包 suppression，以及
  QM35/DW1000 packet 的发送时间。
- `visualize_sic_signal_comparison.m`：对比一段可配置时长内的原始混叠
  信号与“去同步单音、去 DW1000、保留 QM35”的信号。

流水线固定执行：

1. 从原始混叠 capture 解码 QM35。PLL 补偿固定覆盖前 10 个
   preamble repetition，逐 repetition CIR 从第 11 个开始保存。
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
