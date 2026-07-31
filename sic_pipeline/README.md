# QM35 → DW1000 SIC pipeline

入口文件：

```matlab
sic_pipeline/run_qm35_dw1000_sic_pipeline.m
```

`uwbSicPipeline.m` 是入口调用的核心函数，不作为 `run_` 入口脚本。

## 与仓库根目录工具的关系

SIC **共用仓库根目录** 的 decode / cancel 实现，与交互式脚本保持同一真源：

| 根目录文件 | 角色 |
|------|------|
| `run_decode_uwb_all.m` | 全文件解调入口（pipeline 调用） |
| `decode_uwb_all.m` | 能量扫描 + 自适应 full-rate 多包相关 + 精解 |
| `decode_uwb.m` | 单包解调 |
| `run_cancel_all_uwb_packets.m` | 全文件消除入口（pipeline 调用） |
| `generate_uwb_tx_from_decode.m` | 从 PSDU 再生发射波形 |
| `apply_estimated_cir_to_uwb.m` | CIR 卷积到再生波形 |
| `estimate_uwb_cir_slow_phase.m` | CIR 慢相位估计 |
| `estimate_uwb_full_packet_sfo.m` | 全包 SFO 估计 |
| `apply_uwb_full_packet_sfo.m` | 全包 SFO 应用 |
| `+uwbdecoder/` | 解调原语包 |

`sic_pipeline/` 只负责：

- 阶段编排与路径（`uwbSicPipeline.m`）
- 入口配置（`run_qm35_dw1000_sic_pipeline.m`）
- SIC 专用可视化

路径约定：

- `addpath(project_root)` 后 `addpath(sic_pipeline)`，可视化脚本在本地。
- decode / cancel 通过 `run(fullfile(project_root, 'run_*.m'))` 调用。
- PLL 模板、`decoded_results/` 写在仓库根目录下。

独立可视化脚本：

- `visualize_UwbSicPipeline.m`：packet 数量、逐包 suppression，以及
  QM35/DW1000 packet 的发送时间。
- `visualize_sic_signal_comparison.m`：对比一段可配置时长内的原始混叠
  信号与“去同步单音、去 DW1000、保留 QM35”的信号。

## 算法契约（`latestAlgorithmConfig`）

当前版本字符串：

```text
adaptive_fullrate_multipkt_v3_pll10_cir11_cfo2_full_packet_sfo_v1
```

| 字段 | 值 | 含义 |
|------|-----|------|
| `detection_algorithm_version` | **3** | 与 `decode_uwb_all` 写入的 `results.detection_algorithm_version` 一致 |
| 检测 | full-rate multi-packet | `correlation_decimation=1`，能量 onset 分层搜索，长区间多包 |
| 能量 | dB margin | `energy_threshold_margin_db_high ≥ 6` |
| PLL | SYNC 1–10 | 需要已学习的 PLL 模板（缺模板会报错，不允许 silent skip） |
| CIR slow | SYNC 11 起 | + 二级 CFO |
| SFO | full-packet | 仿射时间校正 |

检测器不兼容升级时：同时 bump `decode_uwb_all` 与 `uwbSicPipeline` 的 version，并用 `cfg.overwrite = true` 重建阶段产物。

## 流水线固定执行

1. 从原始混叠 capture 解码 **QM35**（自适应能量 + full-rate 相关）。
2. 去除同步单音并消除可靠的 QM35 packet，生成 `qm35_removed.dat`。
3. 从 `qm35_removed.dat` 解码 **DW1000**（同一检测栈，code 11）。
4. 从 **原始** capture 去除同步单音和拟合出的 DW1000，**保留 QM35**，生成 `dw1000_removed_qm35_preserved.dat`。
5. 两 PHY 消除均启用 PLL + CIR slow + full-packet SFO。
6. 保存 manifest、CSV 汇总；可选 suppression 图。

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

`cfg.resume = true` 时，只复用输入路径、PHY、检测版本、PLL/CIR 边界、
CFO2/SFO 配置和文件长度均通过验证的完整阶段。旧算法产物会被判定为不兼容。
默认的 `cfg.overwrite = false` 会阻止覆盖完整或不完整的已有阶段。
检测器升级后首次重跑请设 `cfg.overwrite = true`；完成后可改回 `false`。
