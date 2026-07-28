# QM35825 非睡眠发射与起始相移测试可行性调研结论

## 总体结论：可行

QM35825 芯片提供了多种电源管理配置和测试模式，**可以通过软件配置避免每次发射前的 PLL 重新初始化，并支持连续发射模式以稳定相位**。但 SDK 以 UCI 命令和高层 API 抽象了寄存器级操作，具体的电源状态切换由固件内部处理。

---

## 1. 芯片的睡眠、待机和持续工作模式

### 1.1 ACPI 兼容的电源状态（QPM 模块）

QM35 固件使用 Qorvo Power Management (QPM) 模块实现 ACPI 兼容的多级睡眠状态。源码位置：`Samples/Cherry/qosal/include/qpm.h`

| 状态 | 枚举值 | Zephyr PM 映射 | 说明 |
|------|--------|---------------|------|
| **S0** | `QPM_STATE_S0` | `PM_STATE_ACTIVE` | 全速运行，所有外设工作 |
| **S0ix** | `QPM_STATE_S0ix` | `PM_STATE_RUNTIME_IDLE` | 运行时空闲，CPU 空闲但外设可快速恢复 |
| **S1** | `QPM_STATE_S1` | `PM_STATE_SUSPEND_TO_IDLE` | CPU 停止，RAM 保持刷新 |
| **S2** | `QPM_STATE_S2` | `PM_STATE_STANDBY` | 待机模式 |
| **S3** | `QPM_STATE_S3` | `PM_STATE_SUSPEND_TO_RAM` | 挂起到 RAM，大部分逻辑断电，RAM 保持 |
| **S4** | `QPM_STATE_S4` | `PM_STATE_SUSPEND_TO_DISK` | 深度睡眠/休眠，需较长时间唤醒 |
| **S5** | `QPM_STATE_S5` | `PM_STATE_SOFT_OFF` | 软关机，需外部事件唤醒 |

**关键机制**：
- `qpm_sleep_state_lock(state, substate)` / `qpm_sleep_state_unlock(state, substate)`：锁住指定状态，阻止进入该状态及更深状态
- `qpm_set_low_power_mode(bool enabled)`：总开关，禁用时自动 lock S3 及以下所有状态
- `qpm_set_min_inactivity_s4(uint32_t time_ms)`：设置进入 S4 前需要空闲的最短时间

**源码位置**：
- 头文件：`Samples/Cherry/qosal/include/qpm.h` (L34-42, L87-126)
- Zephyr 实现：`Samples/Cherry/qosal/src/zephyr/qpm.c` (L164-197)
- FreeRTOS 实现（空壳）：`Samples/Cherry/qosal/src/freertos/qpm.c` (L35-53)

### 1.2 UCI 设备状态

通过 `get_uwbs_state` / `get_config(DeviceState)` 查询，源码：`Samples/Cherry/uci/uci_core/include/uci/uci_spec_fira.h` (L490-507)

| 状态 | 值 | 说明 |
|------|-----|------|
| `READY` | 0x01 | 就绪，可执行命令 |
| `ACTIVE` | 0x02 | 正在执行测距/通信 |
| `INITIALIZING` | 0x80 | 初始化中（Vendor Specific） |
| `ERROR` | 0xFF | 错误，需复位 |

### 1.3 配置参数中的电源相关寄存器

源码：`Samples/Cherry/uci/uci_core/include/uci/uci_spec_fira.h` (L713-720)

| 参数 | 值 | 说明 |
|------|-----|------|
| `UCI_DEVICE_PARAMETER_DEVICE_STATE` (0x00) | 只读 | 读取当前设备状态 |
| `UCI_DEVICE_PARAMETER_LOW_POWER_MODE` (0x01) | 读写 | 低功耗模式开关 |

Python 层封装：`Samples/Python/UWB-Qorvo-Tools/lib/uwb-uci/uci/fira_conf.py` (L12-24)

```python
Config.LowPowerMode = 0x1  # 0=禁用, 1=启用
```

### 1.4 电源统计（验证电源状态）

Python API：`client.get_power_stats()` 返回 `(idle, tx, rx, wakeup_cnt, uptime, s1, s3)` 毫秒数。

源码：`Samples/Python/UWB-Qorvo-Tools/lib/uwb-uci/uci/qorvo.py` (L481-492)
脚本：`Samples/Python/UWB-Qorvo-Tools/scripts/device/get_power_stats/get_power_stats.py` (L67)

**用途**：通过 S1/S3 累计时间可确认芯片是否进入过睡眠状态。

---

## 2. 能否避免每次发射前重新初始化 PLL/射频链路

### 答案：可以

存在三种互补机制：

#### 机制 A：禁用低功耗模式（最有效）

```
set_config LowPowerMode 0
```

这会通知固件不进入任何睡眠状态，从而避免 PLL 重新锁定。对应固件实现：`qpm_set_low_power_mode(false)` → `qpwr_disable_lpm()` + `qpm_sleep_state_lock(QPM_STATE_S3, QPM_ALL_SUBSTATES)`。

#### 机制 B：增大 S4 空闲超时

```
set_config PmMinInactivityS4 4294967295   # 0xFFFFFFFF ≈ 49.7 天
```

源码：`Samples/Python/UWB-Qorvo-Tools/lib/uwb-uci/uci/qorvo.py` (L212-234)
- `Config.PmMinInactivityS4` = 0xA9
- 单位：毫秒
- 默认值为 0，意味着空闲即进入 S4

#### 机制 C：使用连续发射测试模式保持 RF 常开

`test_tx_cw(1)` 启动连续波发射，PA 和 PLL 在整个期间保持工作状态。

### 关键发现：发射间隔与睡眠的关系

SDK 代码和 power stats 显示：
- 芯片有 **WAKEUP 计数器**，每次从睡眠唤醒会递增
- 如果两次发射之间的间隔 **> PmMinInactivityS4**，芯片会自动进入 S4 并重新初始化 RF
- 如果间隔 < 触发阈值且低功模式关闭，则保持在 S0/S0ix

---

## 3. 保持 PLL/本振/PA 持续工作的 API 与配置顺序

### 3.1 完整配置流程（最小可工作序列）

```bash
# 步骤 1: 初始化测试会话（session ID 0 = 测试模式）
session_init -s 0 --type test

# 步骤 2: 设置通道
session_set_conf -s 0 ChannelNumber 9

# 步骤 3: 禁用低功耗模式 —— 核心步骤
set_config LowPowerMode 0

# 步骤 4: (可选但推荐) 设置 S4 超时为最大值，防止意外进入 S4
set_config PmMinInactivityS4 4294967295

# 步骤 5: 启动连续波发射（保持 PA/PLL 常开）
run_qorvo_test_tx_cw -c 9 -t -1
# 或使用周期性 TX 测试：
# run_fira_test_periodic_tx -c 9 --run-forever
```

### 3.2 对应的 UCI 命令序列（十六进制）

| 步骤 | GID | OID | Payload | 作用 |
|------|-----|-----|---------|------|
| SetConfig LowPowerMode=0 | 0x00 | 0x04 | 01 01 00 | 禁用低功耗 |
| SetConfig PmMinInactivityS4=MAX | 0x00 | 0x04 | 02 A9 FF FF FF FF | S4 超时最大化 |
| TestTxCw Start | 0x0B | 0x01 | 01 | 启动连续波 |

### 3.3 校准参数：PLL Locking Code

源码位置：`Samples/Cherry/uwbs_config/utest/resources/config1/settings.yml` (L8-11)

```yaml
ch5:
    pll_locking_code: 255   # 通道 5 的 PLL 锁定码
ch9:
    pll_locking_code: 1     # 通道 9 的 PLL 锁定码
```

设置命令：

```bash
set_cal ch9.pll_locking_code 1
```

此参数控制 PLL 锁定行为，影响相位稳定性。值 255 表示默认，1 表示特定锁定码。

### 3.4 Python API 直接调用示例

```python
from uci import Client, Config, Int32, Status

client = Client(port="ftdi://FT4222")

# 禁用低功耗模式
rts, failed = client.set_config([(Config.LowPowerMode, 0)])
assert rts == Status.Ok

# 最大化 S4 空闲超时
rts, failed = client.set_config([(Config.PmMinInactivityS4, Int32(0xFFFFFFFF))])
assert rts == Status.Ok

# 验证：读取电源统计，确认 S1/S3 时间不再增长
rts, idle, tx, rx, wakeup_cnt, uptime, s1, s3 = client.get_power_stats()
print(f"S1={s1}ms, S3={s3}ms, wakeups={wakeup_cnt}")
```

---

## 4. 适合观察起始相位的测试模式

### 4.1 测试模式总览

| 模式 | 脚本/API | 说明 | 适合观察相位？ |
|------|----------|------|---------------|
| **TX CW（连续波）** | `run_qorvo_test_tx_cw` / `test_tx_cw(1)` | 连续未调制载波 | **最适合** — 相位连续，无中断 |
| **Periodic TX** | `run_fira_test_periodic_tx` / `test_periodic_tx(psdu)` | 周期性发送测试帧 | 适合 — 可观察每次起始 |
| **PER RX** | `run_fira_test_per_rx` | 接收端 PER 测试 | 配合 TX 使用 |
| **Loopback** | `run_fira_test_loopback` | 内部环回 | 不适合空口观测 |
| **RX Test** | `run_fira_test_rx` | 连续接收 | 用于校准接收端 |
| **PLL Lock Test** | `run_qorvo_test_pll_lock` | 测试 PLL 锁定状态 | 诊断用 |

### 4.2 推荐：TX CW 模式（连续波）

源码：`Samples/Python/UWB-Qorvo-Tools/scripts/qorvo/run_qorvo_test_tx_cw/run_qorvo_test_tx_cw.py`

**优势**：
- PLL 和 PA 在整个发射期间持续锁定和工作
- 无帧间间隙，相位完全连续
- 无 PA 开启/关闭瞬态
- 配置简单，只需通道号和持续时间

**关键代码**：`Samples/Python/UWB-Qorvo-Tools/lib/uwb-uci/uci/qorvo.py` (L409-413)

```python
def test_tx_cw(self, switch_op):
    payload = self.command(fira.Gid.Qorvo, OidQorvo.TestTxCw, switch_op.to_bytes(1, "little"))
    return fira.Status(payload[0])
```

**UCI 命令**：
- GID = 0x0B (QORVO_EXT2), OID = 0x01
- Payload: 0x01 = 启动, 0x00 = 停止

### 4.3 推荐：Periodic TX 模式（周期性帧）

源码：`Samples/Python/UWB-Qorvo-Tools/scripts/fira/run_fira_test_periodic_tx/run_fira_test_periodic_tx.py`

**关键参数**：
- `TestParam.TGap` (0x1)：帧间间隙，单位微秒（设为最小值可减少 PLL 空闲时间）
- `TestParam.NumPackets` (0x00)：包数量（设为 0xFFFFFFFF = 永久）
- `TestParam.RMarkerTxStart` (0x06) / `RMarkerRxStart` (0x07)：可输出 GPIO 标记信号

**配置最小间隙**：

```python
(TestParam.TGap, 2000),  # 2000us = 2ms 间隙，足够短以保持 PLL 热启动
```

### 4.4 GPIO 标记输出（用于示波器/X410 同步）

HW Test Mode 提供 GPIO 输出功能，可输出 TX/RX 时序标记信号：

```bash
# 配置 GPIO 输出时钟（用于同步观测）
run_qorvo_clock_out_config --soc qm358 --pin-id 33 --clock-id 2
run_qorvo_clock_out_control --start --clock-id 2
```

源码：`Samples/Python/UWB-Qorvo-Tools/lib/uwb-uci/uci/addin_hw_test.py` (L30-238)

---

## 5. 功耗、温度、发射时长与硬件安全限制

### 5.1 功耗限制

| 模式 | 典型功耗 | 说明 |
|------|---------|------|
| S0 Active TX | ~150-300mA（估算，取决于 TX 功率等级） | 连续发射时最高 |
| S0 Active RX | ~80-150mA | 接收模式 |
| S3 挂起 | <1mA | RAM 保持 |
| S4 深度睡眠 | <0.1mA | 需长时间唤醒 |

**监测方法**：

```bash
get_power_stats
# 输出: IDLE, TX, RX, WAKEUP, UPTIME, S1, S3
```

源码：`Samples/Python/UWB-Qorvo-Tools/lib/uwb-uci/uci/qorvo.py` (L481-492)

### 5.2 温度限制

**监测 API**：`client.get_uwb_device_stats()` → 返回 `chip_temp_celsius`（精度 0.01°C）

源码：`Samples/Python/UWB-Qorvo-Tools/lib/uwb-uci/uci/qorvo.py` (L514-519)

```python
def get_uwb_device_stats(self):
    payload = self.command(fira.Gid.Qorvo, OidQorvo.GetUwbDeviceStats, b"")
    b = Buffer(payload)
    rts = fira.Status(b.pop_uint(1))
    chip_temp_celsius = b.pop_int(2) / 100
    return (rts, chip_temp_celsius)
```

**注意**：SDK 中未找到显式的过温保护阈值或自动降功率机制。固件内部可能有保护，但 API 未暴露。

### 5.3 发射时长限制

| 限制来源 | 说明 | 阈值 |
|---------|------|------|
| **TX CW 模式** | 无固件强制时间限制 | 可持续运行直到手动停止或设备 Error |
| **Periodic TX** | 由 `NumPackets` 参数控制 | 最大 0xFFFFFFFF 包（约 4.3×10⁹ 包）|
| **法规限制** | UWB 占空比法规（如 FCC 15.517）| 通常 < 1% 占空比 @ 1ms 窗口 |
| **热限制** | 无显式 API 限制 | 取决于散热设计 |

**注意**：对于连续波（CW）模式，无占空比概念（100% 占空比），这违反常规 UWB 法规。仅限实验室屏蔽环境使用。

### 5.4 硬件安全限制

SDK 中未发现以下保护机制的 API：
- PA 过流保护
- 天线开路/短路检测
- 显式过温关断

这些保护（如果存在）由固件/硬件透明处理，设备可能进入 `ERROR` 状态（需 `reset_device` 恢复）。

---

## 6. 最小配置流程

### 6.1 方案 A：连续波（CW）模式 — 最简单，相位最稳定

```bash
# 1. 禁用低功耗模式
set_config LowPowerMode 0

# 2. 最大化 S4 超时
set_config PmMinInactivityS4 4294967295

# 3. 启动连续波（永久运行，按 ENTER 停止）
run_qorvo_test_tx_cw -c 9 -t -1 -p ftdi://FT4222
```

### 6.2 方案 B：Periodic TX 模式 — 更接近真实通信时序

```bash
# 1-2. 同上：禁用低功耗 + 最大化 S4 超时
set_config LowPowerMode 0
set_config PmMinInactivityS4 4294967295

# 3. 启动周期性 TX（最小间隙，永久运行）
run_fira_test_periodic_tx -c 9 --run-forever -t -1 -p ftdi://FT4222
```

### 6.3 方案 C：Ranging 模式（真实业务场景）

```bash
# 1-2. 同上
set_config LowPowerMode 0
set_config PmMinInactivityS4 4294967295

# 3. 初始化测距会话
session_init -s 45 ranging

# 4. 配置参数（RangingRoundUsage 使用 Non-Deferred 以减少空闲）
session_set_conf -s 45 DeviceRole 0x1 DeviceType 0x1 MultiNodeMode 0x0 \
    RangingRoundUsage 0x3 DeviceMacAddress 0x0 DstMacAddress 0x1 \
    RangingInterval 192 SlotDuration 24 SlotsPerRR 1

# 5. 开始测距
ranging_start -s 45 -t -1
```

---

## 7. 对比实验设计：默认睡眠 vs 非睡眠模式

### 7.1 实验目标

比较 QM35 在**默认模式**（每次发射后可进入睡眠）vs**非睡眠模式**（强制保持 S0）下，UWB 信号起始阶段的：
- 相位轨迹
- 相位稳定时间
- 消除残差

### 7.2 实验设备

| 设备 | 用途 | 连接方式 |
|------|------|---------|
| QM35825 DK-05/06 | 被测设备，UWB 发射 | HSSPI (FT4222) 接主机 |
| USRP X410 | IQ 采集 | 射频电缆接 QM35 TX 端口 |
| 主机 (PC) | 运行 UQT 脚本控制 QM35 | USB → FT4222 → HSSPI → QM35 |

### 7.3 实验步骤

#### Phase 1: 默认模式（对照组）

```bash
# 重置设备到默认状态
reset_device

# 确认默认低功模式为启用
get_config LowPowerMode
# 预期输出: LowPowerMode = 1 (默认启用)

# 确认默认 S4 超时
get_config PmMinInactivityS4
# 预期输出: PmMinInactivityS4 = 0 (立即进入 S4)

# 启动 Periodic TX（带间隙以允许进入睡眠）
run_fira_test_periodic_tx -c 9 --num-packets 1000 --t-gap 100000 -v -p ftdi://FT4222
```

**X410 采集设置**：
- 中心频率：7987.2 MHz（通道 9）
- 采样率：2 GSPS
- 采集时长：覆盖 ≥100 个 TX 帧
- 触发：外部触发或使用 QM35 GPIO RMarker 输出

#### Phase 2: 非睡眠模式（实验组）

```bash
# 重置设备
reset_device

# 关键：禁用低功耗模式
set_config LowPowerMode 0

# 关键：最大化 S4 超时
set_config PmMinInactivityS4 4294967295

# 验证配置
get_config LowPowerMode
# 预期: LowPowerMode = 0
get_config PmMinInactivityS4
# 预期: PmMinInactivityS4 = 4294967295

# 启动完全相同的 Periodic TX
run_fira_test_periodic_tx -c 9 --num-packets 1000 --t-gap 100000 -v -p ftdi://FT4222
```

**同步采集**：X410 设置与 Phase 1 完全相同。

#### Phase 3: 连续波模式（基准参考）

```bash
set_config LowPowerMode 0
set_config PmMinInactivityS4 4294967295
run_qorvo_test_tx_cw -c 9 -t 10 -v -p ftdi://FT4222
```

CW 模式提供"理想"的相位基准（无起始瞬态）。

### 7.4 数据分析方法

对采集到的 IQ 数据，按以下步骤分析：

```python
import numpy as np

def analyze_phase_transient(iq_samples, sample_rate=2e9):
    """
    分析 IQ 数据中的相位起始瞬态。
    """
    # 1. 计算瞬时相位
    instantaneous_phase = np.unwrap(np.angle(iq_samples))

    # 2. 转换为度数
    phase_deg = np.degrees(instantaneous_phase)

    # 3. 去除线性趋势（载波频偏）
    time_axis = np.arange(len(phase_deg)) / sample_rate
    coeffs = np.polyfit(time_axis, phase_deg, 1)
    linear_trend = np.polyval(coeffs, time_axis)
    residual_phase = phase_deg - linear_trend

    # 4. 找到相位稳定点（导数 < 阈值）
    phase_derivative = np.diff(residual_phase) / (1/sample_rate)
    stable_threshold = 1e6  # 度/秒
    stable_point_idx = np.where(np.abs(phase_derivative) < stable_threshold)[0]

    if len(stable_point_idx) > 0:
        stable_time = stable_point_idx[0] / sample_rate
    else:
        stable_time = None

    return {
        'phase_trace': residual_phase,
        'stable_time_us': stable_time * 1e6 if stable_time else None,
        'initial_phase_offset': residual_phase[:100].mean(),
        'phase_std_after_stable': residual_phase[stable_point_idx].std() if len(stable_point_idx) > 0 else None
    }
```

### 7.5 预期结果与判据

| 指标 | 默认模式（睡眠） | 非睡眠模式 | CW 基准 |
|------|----------------|-----------|---------|
| **起始相移幅度** | 大（预计 30°-180°） | 小（预计 < 10°） | 0° |
| **相位稳定时间** | 长（预计 1-10 µs） | 极短（< 1 µs） | N/A |
| **消除残差** | 大 | 小 | 0 |
| **帧间相位一致性** | 差（每次重新锁定） | 好（PLL 保持锁定） | 完美 |

**判断标准**：若非睡眠模式的相位稳定时间 < 1 µs 且起始相移 < 15°，则"非睡眠方案有效"。

### 7.6 额外验证：通过 Power Stats 确认睡眠行为

```python
from uci import Client

client = Client(port="ftdi://FT4222")

# 发射前
rts, idle1, tx1, rx1, wakeup1, uptime1, s1_1, s3_1 = client.get_power_stats()

# 执行发射测试...
# run_fira_test_periodic_tx ...

# 发射后
rts, idle2, tx2, rx2, wakeup2, uptime2, s1_2, s3_2 = client.get_power_stats()

print(f"S3 增长: {s3_2 - s3_1} ms")
print(f"唤醒次数增长: {wakeup2 - wakeup1}")
# 默认模式: S3 显著增长，wakeup 计数增加
# 非睡眠模式: S3 不增长，wakeup 不变
```

---

## 8. 代码位置索引

| 功能 | 文件路径 | 行号/位置 |
|------|---------|----------|
| QPM 电源状态枚举 | `Samples/Cherry/qosal/include/qpm.h` | L34-42 |
| 低功耗模式 API | `Samples/Cherry/qosal/include/qpm.h` | L87-103 |
| Zephyr PM 映射实现 | `Samples/Cherry/qosal/src/zephyr/qpm.c` | L21-41, L164-197 |
| UCI 设备状态枚举 | `Samples/Cherry/uci/uci_core/include/uci/uci_spec_fira.h` | L490-507 |
| 低功耗配置参数 | `Samples/Cherry/uci/uci_core/include/uci/uci_spec_fira.h` | L713-720 |
| Python Config 封装 | `Samples/Python/UWB-Qorvo-Tools/lib/uwb-uci/uci/fira_conf.py` | L12-24 |
| Python PmMinInactivityS4 | `Samples/Python/UWB-Qorvo-Tools/lib/uwb-uci/uci/qorvo.py` | L212-234 |
| Power Stats API | `Samples/Python/UWB-Qorvo-Tools/lib/uwb-uci/uci/qorvo.py` | L481-492 |
| Power Stats 脚本 | `Samples/Python/UWB-Qorvo-Tools/scripts/device/get_power_stats/get_power_stats.py` | L67 |
| 温度监测 API | `Samples/Python/UWB-Qorvo-Tools/lib/uwb-uci/uci/qorvo.py` | L514-519 |
| TX CW 测试客户端 | `Samples/Python/UWB-Qorvo-Tools/lib/uwb-uci/uci/qorvo.py` | L409-413 |
| TX CW 测试脚本 | `Samples/Python/UWB-Qorvo-Tools/scripts/qorvo/run_qorvo_test_tx_cw/run_qorvo_test_tx_cw.py` | L90-164 |
| Periodic TX 脚本 | `Samples/Python/UWB-Qorvo-Tools/scripts/fira/run_fira_test_periodic_tx/run_fira_test_periodic_tx.py` | L258-407 |
| PLL Lock 测试客户端 | `Samples/Python/UWB-Qorvo-Tools/lib/uwb-uci/uci/qorvo.py` | L415-422 |
| PLL Lock 测试脚本 | `Samples/Python/UWB-Qorvo-Tools/scripts/qorvo/run_qorvo_test_pll_lock/run_qorvo_test_pll_lock.py` | L100-157 |
| HW Test GPIO 扩展 | `Samples/Python/UWB-Qorvo-Tools/lib/uwb-uci/uci/addin_hw_test.py` | L30-238 |
| TestParam 定义 (TGap 等) | `Samples/Python/UWB-Qorvo-Tools/lib/uwb-uci/uci/fira_app.py` | L197-222 |
| set_config 脚本 | `Samples/Python/UWB-Qorvo-Tools/scripts/device/set_config/set_config.py` | L136-198 |
| get_config 脚本 | `Samples/Python/UWB-Qorvo-Tools/scripts/device/get_config/get_config.py` | L112-188 |
| get_caps (能力查询) | `Samples/Python/UWB-Qorvo-Tools/scripts/device/get_cap/get_cap.py` | L76-98 |
| 设备状态通知回调 | `Samples/Cherry/cherry/src/cherry.c` | L355-408 |
| SetConfig 响应处理 | `Samples/Cherry/cherry/src/uci_client/cherry_core_client.c` | L552-600, L690-694 |
| Get UWBS State 实现 | `Samples/Cherry/cherry/src/uci_client/cherry_core_client.c` | L912-939 |
| UCI SetConfig OID | `Samples/Cherry/uci/uci_core/include/uci/uci_spec_fira.h` | L174-175 |
| QORVO_EXT2 Test OIDs | `Samples/Cherry/uci/uci_core/include/uci/uci_spec_qorvo.h` | L128-148 |

---

## 9. 注意事项与风险提示

1. **SDK 限制**：本 SDK 以 UCI 命令抽象了底层寄存器操作。直接寄存器级控制 PLL/PA 使能位的代码**未在 SDK 中暴露**，位于固件内部（闭源二进制）。所有电源状态控制通过 `set_config(LowPowerMode)` 和 `PmMinInactivityS4` 实现。

2. **文档保护**：SDK 中的 PDF 文档（Datasheet、UCI Spec、L1 Config 等）均为密码保护，无法直接读取具体寄存器地址和电气参数。以上结论基于开源的 Cherry 固件代码和 Python 工具代码。

3. **固件版本差异**：不同版本的 QM35 固件可能对 LowPowerMode 的处理行为不同。建议在目标硬件上先运行 `get_caps` 确认 `suspend_ranging` 能力是否支持。

4. **法规合规**：CW 模式和持续 TX 模式（100% 占空比）违反常规 UWB 发射法规。**仅限屏蔽室/实验室环境使用**。

5. **相移根因确认**：即使禁用睡眠后相位稳定，相移仍可能来自：
   - PA 增益切换瞬态（如果 TX 功率在帧间变化）
   - 通道切换时的 PLL 重新调谐
   - 温度漂移导致的相位缓慢变化
   
   建议配合 `get_uwb_device_stats` 监测温度，确认温度与相位漂移的相关性。

6. **替代方案**：如果禁用睡眠后仍有不可接受的相移，可考虑：
   - 使用 CW 模式作为相位参考，对 Periodic TX 结果做相对校准
   - 在接收端（DW1000）实现自适应相位补偿
   - 延长 TX 前导码，使相移在 preamble 期间完成稳定
