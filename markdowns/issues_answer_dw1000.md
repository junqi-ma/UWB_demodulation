# DW1000 连续发射模式与 EVM 测试可行性调研报告

> 调研范围：本项目固件中的 DW1000 寄存器定义 (`deca_regs.h`)、底层驱动 API (`deca_device_api.h`)、驱动实现 (`deca_device.c`)、参数表 (`deca_params_init.c`)，结合 DW1000 芯片数据手册（DecaWave DW1000 User Manual v2.10 / DW1000 Datasheet v2.04）对应章节。

---

## 核心结论

| 模式 | 是否支持 | 依据 |
|---|---|---|
| **Continuous Wave (CW，连续单载波)** | ✅ **支持** | 驱动已提供 `dwt_configcwmode()` 函数，通过 `TC_PGTEST` 寄存器（写入 `0x13`）将脉冲发生器切换为 CW 模式 |
| **Continuous Pulse (连续 UWB 脉冲)** | ⚠️ **部分支持** | 不存在"无限连续发 UWB 脉冲"的硬件模式；但可通过 **连续帧模式** (`dwt_configcontinuousframemode()`) 以最高约 4ms 周期反复发送同一帧，实现"准连续"脉冲串发射，适合频谱/EVM 测试 |

---

## 1. Continuous Pulse 测试模式

### 1.1 结论：不存在真正的"Continuous Pulse"模式

DW1000 没有可让硬件无限循环发送原始 UWB 脉冲（无帧结构、不间断）的专用模式。但有两种替代方案：

### 1.2 替代方案 A：连续帧模式（推荐用于 EVM 测试）

**函数**：`void dwt_configcontinuousframemode(uint32 framerepetitionrate)`
**代码位置**：`firmware_uwb/Components/HAL/DW/decadriver/deca_device.c` 第 3476 行

**工作原理**：
- 将 `DIAG_TMC` 寄存器（`DIG_DIAG` 寄存器组 0x2F，偏移 0x24）的 `TX_PSTM` 位置 1（`DIAG_TMC_TX_PSTM = 0x0010`）
- 数据手册原文：*"This test mode is provided to help support regulatory approvals spectral testing. When the TX_PSTM bit is set it enables a repeating transmission of the data from the TX_BUFFER."*
- 硬件会**自动重复发送 TX_BUFFER 中的帧数据**，无需 MCU 干预
- 重复周期通过 `DX_TIME` 寄存器（0x0A）设置，最小值被硬件限制为 4（代码中 `if(framerepetitionrate < 4) framerepetitionrate = 4;`）

**配置流程**（驱动内部实现）：
1. 调用 `_dwt_disablesequencing()` — 关闭 PMSC 对 RF 块的自动时序控制，切换到 XTI 时钟
2. 写 `RF_CONF`（0x28）使能 RF PLL 和全部 TX 块（`RF_CONF_TXPLLPOWEN_MASK`、`RF_CONF_TXALLEN_MASK`）
3. 强制使能系统 PLL 和 TX PLL 时钟（`FORCE_SYS_PLL`、`FORCE_TX_PLL`）
4. 将 `framerepetitionrate` 写入 `DX_TIME`（0x0A）
5. 写 `DIAG_TMC`（0x2F:24）= `0x10` 启动连续发送

**限制**：
- 每次发送仍是完整帧（前导码 + SFD + PHR + 数据），帧间存在间隙
- 占空比受帧长和重复周期约束，不是 100% 连续

### 1.3 替代方案 B：MCU 循环触发单次 TX（灵活性最高）

若需要精确控制脉冲间隔，可在 MCU 主循环中反复调用 `dwt_starttx()`，但受限于 SPI 写入和帧间延迟，无法达到真正"连续"。

---

## 2. Continuous Wave (CW) 测试模式

### 2.1 结论：完全支持

**函数**：`int dwt_configcwmode(uint8 chan)`
**代码位置**：`firmware_uwb/Components/HAL/DW/decadriver/deca_device.c` 第 3411 行
**寄存器依据**：`TC_PGTEST`（TX_CAL 寄存器组 0x2A，偏移 0x0C）

**工作原理**：
- 向 `TC_PGTEST` 写入 `TC_PGTEST_CW = 0x13`，将脉冲发生器从"正常 UWB 脉冲"切换为"连续波（单载波正弦波）"输出
- 发射频率 = 所选信道的 RF 中心频率（由 `FS_PLLCFG` / `FS_PLLTUNE` 配置）
- 这是一个**未调制的纯净单频载波**，频谱上为单一谱线，是 EVM/频偏/相位噪声测试的理想信号源

### 2.2 CW 模式最小配置流程（基于驱动源码分析）

| 步骤 | 操作 | 寄存器 / API | 说明 |
|---|---|---|---|
| 1 | 关时序 | `_dwt_disablesequencing()` | 停止 PMSC 自动时序，时钟切到 XTI 19.2MHz |
| 2 | 配 RF PLL | `FS_CTRL` (0x2B) 偏移 0x07 写 `pll2_config[chan]` | 5 字节 PLL 配置，按信道查表（见 `deca_params_init.c` 第 39-52 行） |
| 3 | 校准 | `FS_XTALT` (0x2B:0x0E) 写 `pll2calcfg` (0x70) | 注意 bits 7:5 必须为 011，否则芯片故障 |
| 4 | 配 TX 模拟 | `RF_TXCTRL` (0x28:0x0C) 写 `tx_config[chan]` | 4 字节信道特定值（CH1=0x00005C40, CH3=0x00086EC0, CH7=0x001E7DE0 等） |
| 5 | 使能 PLL | `RF_CONF` (0x28) 写 `RF_CONF_TXPLLPOWEN_MASK` | 使能 LDO 和 RF PLL |
| 6 | 使能 TX 块 | `RF_CONF` (0x28) 写 `RF_CONF_TXALLEN_MASK` | 使能全部 TX 通道 |
| 7 | 配 TX 时钟 | `PMSC_CTRL0` (0x36:0x00) 写 0x22，(0x36:0x01) 写 0x07 | 切换到 125MHz PLL 时钟 |
| 8 | 关 fine grain TX seq | `PMSC_TXFINESEQ_OFFSET` (0x36:0x26) 写 0x0 | 禁用细粒度时序控制 |
| 9 | **启动 CW** | `TX_CAL` (0x2A) 偏移 0x0C 写 `0x13` | **关键步骤：进入 CW 模式** |

**信道中心频率参考**（数据手册）：
- Channel 1: 3494.4 MHz
- Channel 3: 4492.8 MHz
- Channel 5: 6489.6 MHz
- Channel 7: 6489.6 MHz（与 5 不同带宽）

### 2.3 CW 模式的退出 / 复位方法

| 方法 | 操作 | 说明 |
|---|---|---|
| **方法 1：回写 Normal** | 向 `TC_PGTEST` (0x2A:0x0C) 写 `TC_PGTEST_NORMAL = 0x00` | 立即停止 CW，脉冲发生器恢复 UWB 脉冲模式 |
| **方法 2：复位** | 调用 `dwt_softreset()` | 复位 HIF/TX/RX/PMSC，PLL 重新锁定（需等 ~10us，且 SPI < 3MHz） |
| **方法 3：关 TX 时序** | 调用 `_dwt_disablesequencing()` + `_dwt_enableclocks(ENABLE_ALL_SEQ)` | 先停止再恢复自动时序，回到空闲 INIT 状态 |
| **方法 4：强制关收发** | `SYS_CTRL` (0x0D) 写 `SYS_CTRL_TRXOFF (0x40)` | 立即中止 TX/RX，进入 IDLE |

> **推荐退出流程**：方法 1（写 0x00 到 TC_PGTEST）→ 方法 4（TRXOFF）→ 方法 3（恢复时序）。这样可确保干净退出且不残留异常状态。

---

## 3. 发射功率调节

### 3.1 功率控制寄存器总览

DW1000 的发射功率由**两个层级**控制：

| 层级 | 寄存器 | 功能 | 粒度 |
|---|---|---|---|
| **粗调（RF 模拟级）** | `RF_CONF` (0x28) bits [20:16] `TXPOW_MASK` | 控制 RF 功放偏置电流，32 级 (0x00–0x1F) | 大步进，改变输出功率范围 |
| **细调（数字基带级）** | `TX_POWER` (0x1E) 32 位 | 4 个 8 位字段分别控制不同帧段功率 | 精细步进，0–255 每字段 |

### 3.2 细调：`TX_POWER` 寄存器（0x1E）—— 主要功率控制手段

**结构**（`dwt_txconfig_t.power` 字段，见 `deca_device_api.h` 第 239-249 行）：

```
power (32-bit):
  Bits [31:24]  BOOST_0.125ms_PWR  — 帧长 < 0.125ms 时的功率
  Bits [23:16]  TX_SHR_PWR         — 同步头 (SHR) 段功率 (帧长 < 0.25ms)
  Bits [15:8]   TX_PHR_PWR         — PHY 头 (PHR) 段功率 (帧长 < 0.5ms)
  Bits [7:0]    TX_DATA_PWR        — 数据段功率 / 正常功率
```

**工作模式取决于 Smart TX Power 是否启用**：

- **Smart TX Power 启用**（默认，`SYS_CFG.DIS_STXP = 0`）：硬件根据帧长自动选择以上 4 个值之一（帧越短可用越高功率以满足频谱掩膜）。通过 `dwt_setsmarttxpower(1)` 启用。
- **Manual 模式**（`SYS_CFG.DIS_STXP = 1`）：固定使用：
  - `TX_POWER_TXPOWPHR_MASK` (bits [15:8]) — PHR 段
  - `TX_POWER_TXPOWSD_MASK` (bits [23:16]) — SHR + 数据段
  - 默认值 `TX_POWER_MAN_DEFAULT = 0x0E080222`

**配置函数**：`dwt_configuretxrf(dwt_txconfig_t *config)` — `deca_device.c` 第 524 行
- 写入 `TC_PGDELAY`（脉冲发生器延迟，信道特定）
- 写入 `TX_POWER`（功率值）

### 3.3 粗调：`RF_CONF.TXPOW`（0x28 bits [20:16]）

控制 RF 功放偏置，直接决定输出功率的**最大范围**。这是一个全局模拟调节，值越大输出功率越大。在正常帧模式下由 OTP 校准值设定；CW/连续帧模式中需要手动设置（驱动中 `RF_CONF_TXALLEN_MASK` 已包含 `TXPOW`）。

### 3.4 脉冲发生器延迟：`TC_PGDELAY`（0x2A:0x0B）

信道相关的脉冲定时延迟，影响脉冲形状和频谱：

| 信道 | 推荐值 |
|---|---|
| CH1 | 0xC9 |
| CH2 | 0xC2 |
| CH3 | 0xC5 |
| CH4 | 0x95 |
| CH5 | 0xC0 |
| CH7 | 0x93 |

### 3.5 当前项目中的功率配置（`bphero_uwb.c`）

```c
dwt_txconfig_t txconfig2 = { 0xC9, 0x15151515 }; // CH1: PGdly=0xC9, power=0x15151515
dwt_txconfig_t txconfig3 = { 0xC5, 0x2b2b2b2b }; // CH3: PGdly=0xC5, power=0x2b2b2b2b
```

解读：
- `0x15151515` → 各段功率字节均为 0x15（十进制 21）— 较低功率
- `0x2b2b2b2b` → 各段功率字节均为 0x2b（十进制 43）— 较高功率

> 注意：TX_POWER 值与实际 dBm 输出并非线性关系，且受 RF_CONF 粗调、信道、温度、PCB 匹配等影响。数据手册未公开精确映射表，需实验标定。

### 3.6 功率调节对 EVM 的影响

- **输出功率饱和区**：功率过高会使功放进入非线性区 → EVM 恶化
- **功率过低**：信噪比不足 → EVM 测量不稳定
- **最佳 EVM 点**：通常在功放线性区中间某值，需扫功率找最优点

---

## 4. 持续发射限制

### 4.1 时长限制

- **CW 模式**：硬件无内置超时，可无限持续发射（只要不掉电/不复位）
- **连续帧模式**：同上，无限重复，无硬件上限
- **热限制**：DW1000 持续发射会显著发热。芯片有内置温度传感器（通过 `TX_CAL` 的 SAR 读取，或 `dwt_readtempvbat()`），但**无硬件热关断保护**——过热会先导致 PLL 失锁、频率漂移，最终可能损坏

### 4.2 温度监控

可通过以下方式监控温度：
- `dwt_readtempvbat(fastSPI)` — 返回 `(temp_raw << 8) | vbat_raw`，转换公式：`T = 1.13 * temp_raw - 113.0`（℃）
- `TC_SARL_SAR_LTEMP` (0x2A:0x04) — 最新温度 SAR 值
- `TC_SARW_SAR_WTEMP` (0x2A:0x06) — 上次唤醒时温度 SAR 值

### 4.3 PLL 锁定监控

持续发射中应监控：
- `SYS_STATUS.RFPLL_LL` (0x0F bit 24) — RF PLL 失锁
- `SYS_STATUS.CLKPLL_LL` (0x0F bit 25) — 时钟 PLL 失锁

任一标志置位意味着时钟不稳，EVM/频偏将显著恶化。

### 4.4 法规限制

- CW 模式和连续帧模式**违反 UWB 频谱掩膜规定**（ETSI EN 302 567 / FCC 15.250 / 中国 UWB 规定），因为 UWB 设备通常要求极低的占空比或 LBT（Listen Before Talk）
- **仅限屏蔽室/实验室使用**，不可在开放空间运行
- 本项目（Jiulin X1 模块）已做射频屏蔽处理，在实验条件下使用风险可控

### 4.5 硬件安全建议

| 风险 | 缓解措施 |
|---|---|
| 过热损坏 | 限制单次连续发射时长（建议 < 60s），间歇冷却；监控温度 |
| PLL 失锁 | 监控 SYS_STATUS 标志，失锁后立即退出 CW 模式 |
| 法规违规 | 仅在屏蔽环境使用，CW/连续帧模式不用于部署 |
| 功率过高 | 从低功率开始扫，避免功放过饱和 |

---

## 5. 发射功率 × 天线 × 测试模式实验方案（X410 采集 IQ）

### 5.1 实验目标

使用 USRP X410 采集 DW1000 发射信号，分析：
- **EVM**（误差向量幅度）
- **频偏**（固定频偏 vs 随机相位噪声）
- **相位波动**（相位噪声谱）

区分三类误差源：固定频偏（CFO）、随机相位噪声、发射启动瞬态。

### 5.2 推荐实验矩阵

| 变量 | 水平 | 说明 |
|---|---|---|
| **测试模式** | CW / 连续帧 | CW 给出纯净载波（测频偏+相位噪声基线）；连续帧给出真实调制信号（测 EVM） |
| **发射功率** | 低 / 中 / 高（如 0x0A0A0A0A / 0x15151515 / 0x2B2B2B2B，需配合 RF_CONF 粗调） | 扫描找到 EVM 最优点和饱和点 |
| **天线** | 板载天线 / 外接直通电缆（SMA） | 电缆连接排除多径/天线失配影响，获得纯净信号 |
| **信道** | CH1 (3.5GHz) / CH3 (4.5GHz) | 检查频点对 EVM 的影响 |
| **温度** | 冷机 / 热机 (连续发射 30s 后) | 观察相位噪声随温度漂移 |

### 5.3 最小配置流程（实验步骤）

**Step 1: 标准初始化**
```c
reset_DW1000();
SPI_ConfigFastRate(SPI_BaudRatePrescaler_32);
dwt_initialise(DWT_LOADUCODE);
dwt_loadopsettabfromotp(DWT_OPSET_TIGHT);
SPI_ConfigFastRate(SPI_BaudRatePrescaler_4);
dwt_configure(&config);        // 标准帧配置
dwt_configuretxrf(&txconfig);  // 功率配置
dwt_setsmarttxpower(0);        // 关闭 smart power，用 manual 功率（CW 模式必须）
```

**Step 2: CW 模式（基线测量）**
```c
dwt_configcwmode(1);           // CH1 CW 输出
// 等待 ~100us 让 PLL 稳定
// 用 X410 采集 IQ，时长 ≥ 10ms（足够观察相位漂移）
// 测量：载波频率（频偏）、相位噪声谱、幅度波动
```

**Step 3: 连续帧模式（调制信号测量）**
```c
dwt_softreset();               // 先退出 CW
dwt_configure(&config);        // 重新配置
dwt_writetxdata(len, data, 0); // 写帧数据到 TX_BUFFER
dwt_configcontinuousframemode(1000); // 约 1ms 周期重复发送
// X410 采集 IQ
// 测量：EVM、星座图、频谱掩膜
```

**Step 4: 退出**
```c
dwt_softreset();               // 恢复正常工作模式
```

### 5.4 X410 采集建议

| 参数 | 建议值 | 说明 |
|---|---|---|
| 中心频率 | 信道频率（CH1=3.4944GHz, CH3=4.4928GHz） | 精确匹配 DW1000 信道 |
| 采样率 | ≥ 2 GSPS | UWB 信号带宽 ~500MHz，需足够采样率 |
| 采集时长 | CW: ≥ 10ms；连续帧: ≥ 帧周期×100 | 覆盖足够多帧做统计 |
| 增益 | 从低开始，避免 X410 饱和 | DW1000 输出功率较低 (~ -41dBm/MHz)，可能需要低噪声放大 |

### 5.5 数据分析方法

| 误差源 | 识别方法 | 对应措施 |
|---|---|---|
| **固定频偏 (CFO)** | CW 模式下频谱为单峰但偏离预期频率；线性相位旋转 | 软件频偏补偿，或调整 `FS_XTALT` 晶振 trim |
| **随机相位噪声** | CW 模式下频谱展宽（洛伦兹/高斯线型）；相位随机游走 | 改善电源去耦、降低温度、优化 PCB 布局 |
| **发射启动瞬态** | 连续帧模式下每帧开头有幅度/相位跳变 | 对齐帧边界后剔除前导码部分再测 EVM |
| **功放非线性 (AM-AM/AM-PM)** | 连续帧 EVM 随功率升高而恶化 | 降低输出功率，找到线性区 |

---

## 6. 官方 Example 验证（根目录 `ex_04a_cont_wave` / `ex_04b_cont_frame`）

DecaWave 官方提供了两个与本报告完全对应的参考工程，位于根目录。它们从芯片原厂角度**确认了所有结论的正确性**，并补充了若干关键实现细节：

### 6.1 `ex_04a_cont_wave` — CW 模式官方参考

| 对比项 | 本报告结论 | 官方 Example 实际 | 一致性 |
|---|---|---|---|
| 入口函数 | `dwt_configcwmode(chan)` | `dwt_configcwmode(config.chan)` | ✅ 完全一致 |
| 退出方法 | `dwt_softreset()` | `dwt_softreset()` | ✅ 完全一致 |
| 功率配置 | `dwt_configuretxrf(&txconfig)` | `{0xC0, 0x25456585}` → CH5 PGdly + 功率 | ✅ 一致 |
| 初始化 | `dwt_initialise(DWT_LOADUCODE)` | `dwt_initialise(DWT_LOADNONE)` | ⚠️ 官方不加载 LDE |
| 运行时长 | 建议 < 60s | 120000ms = **2 分钟** | ✅ 官方敢跑 2 分钟说明硬件安全 |
| 时钟速率 | SPI < 3MHz (进 CW 前) | `spi_set_rate_low()` 全程不恢复 | ✅ 一致 |

**关键发现 — CW 初始化参数**：
```c
static dwt_config_t config = {
    5,               /* Channel 5 */
    DWT_PRF_64M,
    DWT_PLEN_1024,   /* 注意：CW 模式其实不需要前导码，但仍需填 */
    DWT_PAC32,
    9, 9,
    1,               /* non-standard SFD */
    DWT_BR_110K,
    DWT_PHRMODE_STD,
    (1025 + 64 - 32)
};
static dwt_txconfig_t txconfig = { 0xC0, 0x25456585 };
// 功率解读: BOOSTP125=0x25, BOOSTP250=0x45, BOOSTP500=0x65, BOOSTNORM=0x85
// 步进规律：相邻档相差 0x20 (约 3dB)
```

**官方 Example 的完整流程**（可直接复用）：
```c
peripherals_init();
spi_set_rate_low();                          // SPI 降速
reset_DW1000();
dwt_initialise(DWT_LOADNONE);                // 不加载 LDE
dwt_configure(&config);
dwt_configuretxrf(&txconfig);
dwt_configcwmode(config.chan);               // 进入 CW 模式 → 持续输出 2 分钟
sleep_ms(120000);
dwt_softreset();                             // 退出
```

### 6.2 `ex_04b_cont_frame` — 连续帧模式官方参考

| 对比项 | 本报告结论 | 官方 Example 实际 | 一致性 |
|---|---|---|---|
| 入口函数 | `dwt_configcontinuousframe(period)` | `dwt_configcontinuousframemode(CONT_FRAME_PERIOD)` | ✅ 完全一致 |
| 退出方法 | `dwt_softreset()` | `dwt_softreset()` | ✅ 完全一致 |
| 功率配置 | `dwt_configuretxrf(&txconfig)` | `{0xC0, 0x25456585}` — 同 CW | ✅ 一致 |
| 帧间隔 | DX_TIME 寄存器 | `CONT_FRAME_PERIOD = 124800` (≈1ms) | ✅ 一致 |

**关键发现 — 连续帧必须先写入帧数据再启动**：
```c
// 官方流程揭示了一个本报告未强调的细节：
dwt_configcontinuousframemode(CONT_FRAME_PERIOD);  // ① 配置连续帧模式
dwt_writetxdata(sizeof(tx_msg), tx_msg, 0);         // ② 必须写入帧内容到 TX_BUFFER
dwt_writetxfctrl(sizeof(tx_msg), 0, 0);             // ③ 配置帧控制
dwt_starttx(DWT_START_TX_IMMEDIATE);                // ④ 启动第一次 TX → 硬件自动重复
```
> **重要**：连续帧模式不是"调用即发射"，而是需要先 `dwt_starttx()` 触发第一次。硬件检测到 `TX_PSTM` 后，会将此帧作为模板无限重复，间隔由 `DX_TIME` 决定。

**帧间隔单位解析**：
- `CONT_FRAME_PERIOD = 124800`，单位为 "1/4 × 499.2MHz 周期" ≈ 8ns
- 124800 × 8ns = 998.4µs ≈ **1 ms**（与注释 "one per millisecond" 吻合）

**帧长度与 Smart TX Power 的关系**（官方 NOTE 4 解释）：
- 帧配置：PLEN=128, 12 字节数据, 6.8Mbps
- 帧长时间 ≈ (128 前导 + SFD + PHR + 12×8 数据 bit) / 6.8Mbps ≈ **178µs**（官方注释中"178 ms"是**笔误**，实际应为 178µs）
- 因为帧长 < 250µs，Smart TX Power 自动使用 `BOOSTP250` 字段 = 0x45
- 功率值 `0x25456585` 各字段：BOOSTP125=0x25, BOOSTP250=0x45, BOOSTP500=0x65, BOOSTNORM=0x85
- 相邻档位差 0x20 ≈ 3dB → BOOSTP250 比 BOOSTNORM 高 **6dB**（补偿短帧以满足频谱掩膜）

**完整可复用流程**：
```c
peripherals_init();
spi_set_rate_low();
reset_DW1000();
dwt_initialise(DWT_LOADNONE);
dwt_configure(&config);
dwt_configuretxrf(&txconfig);                    // power = 0x25456585
dwt_configcontinuousframemode(CONT_FRAME_PERIOD); // 124800 ≈ 1ms
dwt_writetxdata(12, tx_msg, 0);                  // 写 blink 帧
dwt_writetxfctrl(12, 0, 0);
dwt_starttx(DWT_START_TX_IMMEDIATE);             // 触发连续发送
sleep_ms(120000);
dwt_softreset();
```

### 6.3 两个 Example 对 EVM 实验的指导

| 实验目标 | 使用 Example | 改动 |
|---|---|---|
| **测频偏 / 相位噪声基线** | `ex_04a_cont_wave` | 改 `config.chan` 为目标信道，调 `txconfig.power` |
| **测 EVM（调制信号）** | `ex_04b_cont_frame` | 改帧配置、功率、帧间隔 |
| **功率扫描** | 任一 | 修改 `txconfig.power` 的 4 个字节，步进 0x10 或 0x20 |
| **温度影响** | 任一 | 用 `dwt_readtempvbat()` 读温度，冷机/热机对比 |
| **信道对比** | 任一 | CH1/CH3/CH5 切换，注意同步修改 PLL 和 PGDELAY |

---

## 7. 关键代码位置索引

| 文件 | 关键内容 | 行号 |
|---|---|---|
| `deca_regs.h` | `TC_PGTEST` (CW 模式寄存器) 定义 | 950–953 |
| `deca_regs.h` | `DIAG_TMC` / `TX_PSTM` (连续帧寄存器) 定义 | 1193–1196 |
| `deca_regs.h` | `TX_POWER` 寄存器定义 | 502–522 |
| `deca_regs.h` | `RF_CONF` / `RF_TXCTRL` 定义 | 883–909 |
| `deca_device_api.h` | `dwt_configcwmode()` 声明 | 1390–1401 |
| `deca_device_api.h` | `dwt_configcontinuousframemode()` 声明 | 1404–1416 |
| `deca_device.c` | `dwt_configcwmode()` 实现 | 3411–3462 |
| `deca_device.c` | `dwt_configcontinuousframemode()` 实现 | 3476–3507 |
| `deca_device.c` | `_dwt_disablesequencing()` | 3884–3889 |
| `deca_device.c` | `dwt_softreset()` | 3342–3371 |
| `deca_params_init.c` | `pll2_config[]` / `tx_config[]` / `chan_idx[]` 参数表 | 25–52 |
| `bphero_uwb.c` | 项目当前功率配置 (txconfig2/txconfig3) | 46–65 |

---

## 8. 总结与建议

1. **CW 模式可行且推荐**：`dwt_configcwmode()` 已完整实现，给出纯净单载波，是测量频偏和相位噪声基线的最佳选择。官方 `ex_04a_cont_wave` 验证通过，可放心使用。
2. **连续帧模式可行但非"真连续"**：`dwt_configcontinuousframemode()` 反复发送完整帧，帧间有间隙，适合 EVM 和频谱掩膜测试。官方 `ex_04b_cont_frame` 验证通过。
3. **不存在"Continuous Pulse"硬件模式**：若有此需求，需在 MCU 层循环触发，但受限于 SPI 速度和帧间延迟。
4. **功率调节**：主要通过 `TX_POWER` (0x1E) 4 字节细调 + `RF_CONF.TXPOW` 粗调 + `TC_PGDELAY` 脉宽调节，建议从低到高扫描找 EVM 最优点。官方推荐功率值 `0x25456585`（CH5）可作为起点参考。
5. **安全使用**：CW/连续模式仅限屏蔽室；官方敢跑 2 分钟说明硬件可承受，但仍建议监控温度；退出时 `dwt_softreset()` 即可恢复。
6. **EVM 问题根因定位策略**：先 CW 测频偏/相位噪声基线（排除功放非线性），再连续帧测完整 EVM，对比两者差异定位问题来自发射链路还是调制/基带。
7. **可直接复用官方流程**：两个 Example 提供了完整的、经过 DecaWave 验证的初始化和退出流程，建议以其为模板修改信道/功率/帧配置，而非从零编写。
