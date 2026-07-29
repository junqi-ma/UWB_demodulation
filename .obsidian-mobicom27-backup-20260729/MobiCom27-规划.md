---
project: "[[MobiCom27-Interference-Cancellation]]"
type: research-project
status: 进行中
start_date: 2026-07-01
deadline: 2026-09-04
venue: MobiCom 2027
tags:
  - project
---

# UWB ISAC

## ⏳ 倒计时

**距离DDL:** `= (this.deadline - date(today)).days` 天

---

## 🎯 核心贡献与假设

<!-- 用1-2句话说清楚:这篇论文解决了什么问题,和已有工作的区别是什么 -->

**核心贡献点:**
-

**关键假设(需要实验验证的):**
- QM35825发送的雷达波形，确实受到了DW1000，DW3000的干扰
- MATLAB可以解调X410采集的UWB波形
- UWB波形可以被重构，并且从原始信号中消除
- 干扰消除能够保证弱目标探测

---

## 🚦 Go/No-Go 决策点

<!-- 提前写好"如果实验效果不达预期,在哪个节点转向备选方案",避免在deadline前才发现方向不对 -->

| 检查点         | 判断标准                                   | 日期   | 状态     | 备选方案 |
| ----------- | -------------------------------------- | ---- | ------ | ---- |
| UWB干扰验证     | QM35825发送的雷达波形，确实受到了DW1000，DW3000的干扰   | 7.3  | 🔲 待检查 |      |
| 离线UWB信号解调   | MATLAB能直接解调DW1000等发出的packet            | 7.7  | 🔲 待检查 |      |
| 离线UWB信号分离   | MATLAB能分别还原UWB sensing和Communication波形 | 7.15 | 🔲 待检查 |      |
| 离线UWB信号干扰消除 | MATLAB能消除communication对sensing的影响      | 7.22 | 🔲 待检查 |      |

---

## 📅 里程碑总览

| 阶段      | 时间范围 | 目标  | 状态  |
| ------- | ---- | --- | --- |
| 实验/系统完善 |      |     | 🔲  |
| 初稿写作    |      |     | 🔲  |
| 内部打磨+图表 |      |     | 🔲  |
| 最终修改+提交 |      |     | 🔲  |

---

## 🧪 实验追踪

| 实验  | 日期  | 结果/关键指标 | 结论  | 笔记链接 |
| --- | --- | ------- | --- | ---- |
|     |     |         |     |      |
|     |     |         |     |      |

---

## ✅ 任务看板

```tasks
not done
path includes PhD-Vault/02-Project/MobiCom27-Interference
sort by due
```

```tasks
done
path includes PhD-Vault/02-Project/MobiCom27-Interference
sort by done reverse
limit 10
```

---

## 📝 每日进度日志

<!-- 需要 Dataview 插件。要求每篇日记里带上 #project/<项目名> 标签 -->

```dataview
TABLE WITHOUT ID
  file.link AS "日期",
  summary AS "今日进展"
FROM #02-Project/MobiCom27-Interference
SORT file.day DESC
LIMIT 14
```

---

## 📚 相关文献

<!-- 链接到 01-Literature 里的文献笔记,或用 Dataview 按标签自动汇总 -->

```dataview
TABLE authors AS "作者", year AS "年份", status AS "状态"
FROM "PhD-Vault/01-Literature"
WHERE contains(projects, this.file.link)
SORT year DESC
```

---

## 💭 阶段性复盘

### 第一周复盘 (日期: )
-

### 第二周复盘 (日期: )
-

