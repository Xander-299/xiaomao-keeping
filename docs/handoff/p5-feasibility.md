# P5 候选可行性评估（2026-11-10 · 待用户审查，未开工）

> 状态：**草案 · 仅供决策**。本文件不代表已批准的需求；批准后才会按 `docs/spec/` 流程出 SPEC。
> 三个候选来自 `docs/spec/SPEC-refactor-ui-kit-dashboard.md` 的 P5 非目标清单。
> 所有结论都对着 master `e591a4c` 的代码核实过，行号可能随后续提交漂移。

## 结论速览

| # | 候选 | 可行性 | 规模 | 硬约束冲突 | 建议 |
|---|---|---|---|---|---|
| 1 | **非布尔模块参数**（枚举 / 数值） | ✅ 可直接做 | **中**（1 个 PR，约 6–8 文件 / 350 LOC + 测试） | 无 | **建议先做**，地基性、收益立刻可见 |
| 2 | **导航项自定义**（底部 4 槽换成哪些页） | ✅ 可做，但**有一处架构前提** | **中偏大**（1 个 PR，约 8–10 文件 / 450 LOC + 测试 + golden） | 无（但会把 `/stats` `/reports` 从 push 页改成 shell 分支） | 可做，需要先拍板「范围」 |
| 3 | **云同步布局** | ⚠️ **分三档，只有 A 档能做** | A：小（约 200 LOC）<br>B：中 + **破坏隐私约束**<br>C：否 | B / C 与「release 包无 INTERNET」直接冲突 | 只做 A（设置随备份走），B 需你改判 |

---

## 1 · 非布尔模块参数（枚举 / 数值）

### 现状（代码事实）

- `DashboardParamSpec` 只描述 bool：`id / title / defaultValue`，取值入口唯一的静态方法
  `DashboardParamSpec.boolValue()`（`lib/features/ledger/presentation/dashboard/dashboard_param.dart`）。
  `raw is bool ? raw : default` —— 非 bool 一律当「没配」。
- 写入口也是 bool 硬编码：`DashboardConfigController.setParam(moduleId, paramId, bool value)`。
- 设置页渲染同样是 bool 硬编码：`dashboard_layout_page.dart` 的子行只有一个 `Switch`（26×38，`FittedBox`）。
- `sanitize()` **已经**原样保留 `params`（`dashboard_registry.dart:59`），JSON 里多余键不会被吃掉 ——
  这是 P4 修过的坑，地基还在，非布尔值不会被静默丢弃。
- 现存参数只有两个，都是 bool：`budget_strip.show_daily`、`chat_entry.show_samples`。

### 要改什么

| 层 | 改动 |
|---|---|
| 模型 | `DashboardParamSpec` 加 `kind`（`bool / choice / int`）+ `options`（choice）+ `min/max/step/unit`（int）；`defaultValue` 从 `bool` 放宽为 `Object` |
| 取值 | 新增 `DashboardParamSpec.valueOf(params, spec)`：**按 kind 强转 + 越界夹取 + 脏值回落默认**（`int` 可能是 JSON number/double/String，`num.toInt()` 兜底，跟 `AutoBookLastRun._asInt` 同一套口径） |
| 写入 | `setParam(moduleId, paramId, Object value)`；`save()` 前用 spec 校验，非法值直接回落默认而不是写进库 |
| UI | 子行按 kind 渲染：bool → 现有 Switch；choice → 小号分段 chips（2–3 项，仍是「更小的子控件」）；int → 减 / 值 / 加 三段步进（不用滑杆，卡片里滑杆手感差） |
| 真实参数 | 见下表，先落 2–3 个证明类型系统够用 |

### 建议先落的三组真实参数

| 模块 | 参数 | 类型 | 选项 / 范围 | 为什么选它 |
|---|---|---|---|---|
| `tx_list` | `limit` 显示条数 | choice | 全部 / 10 / 20 | 需求最真实：月账单长了首屏滚不完 |
| `budget_strip` | `style` 预算呈现 | choice | 金额 / 百分比 / 进度条 | 视觉偏好，两个方向都合理 |
| `month_hero` | `metric` 大卡主指标 | choice | 本月支出 / 本月结余 | 结余派 vs 支出派，用户分歧最大 |

### 风险 / 边界

- **脏值与越界必须有测试**：`limit: 999`、`style: "xxx"`、`limit: 3.7`、`limit: null` 全部要回落默认，不能崩首页。
- **不做**：字符串自由输入、日期参数、跨模块联动参数（如「预算只看某分类」）—— 那是 P5+。
- **兼容**：旧配置只有 bool 键，新代码读缺键 → 默认值，零迁移。反向（新配置给旧版本 App）由 `sanitize` 保留 + 旧 `boolValue` 当没配处理，不炸。

### 验收

- 设置页能改、重启后保留、脏值回落；`dart analyze` 0 issue；`dashboard_registry_test` 扩到覆盖三种 kind 的 JSON 往返与夹取。

---

## 2 · 导航项自定义

### 现状（代码事实）

- 底栏是**手写的五槽**（4 tab + 中央 `+`），不是 `NavigationBar`：`_BottomNav`，
  `_labels = ['首页','日历','','资产','我的']`，`onTap` 是**硬编码 switch**：
  `case 0/1/3/4 → shell.goBranch(0/1/2/3)`，`case 2 → context.push('/record')`（`app_shell.dart:110-125`）。
- 分支**静态定义**在 `app.dart:63-95`：`StatefulShellRoute.indexedStack` 的 4 个 branch =
  `/`（家） / `/calendar` / `/assets` / `/profile`。
- 统计 `/stats`、报表 `/reports`、分类 `/categories`、设置 `/settings` 目前都是**顶层 push 路由**，
  不是 shell 分支 —— 它们没有底栏，靠返回键回。
- 结论：**能改的只有「4 个槽位放哪 4 个页」**，槽位数 5（含中央 FAB）是视觉硬约束（五槽布局刚对齐过）。

### 架构前提（这是关键，也是唯一有风险的一处）

`StatefulShellRoute` 的 branch 列表在**构建路由时定死**，运行时不能改。所以不能「按配置生成分支」。

可行方案（推荐）：**把候选页全部注册成固定的 shell 分支（比如 6 个），配置只决定「哪 4 个槽位映射到哪几个分支」**。

```
branches（固定 6 个，永不变）：
  0 home  /        1 calendar /calendar   2 assets /assets
  3 profile /profile   4 stats /stats     5 reports /reports
nav_config: {"slots": ["home", "calendar", "assets", "stats"]}   ← 运行时只换映射
```

代价：`/stats` `/reports` 从 push 路由变成分支根页 —— 现有 **6 处**入口要改成
`shell.goBranch(4/5)` 而不是 `context.push(...)`，否则会出现「同一页两个实例、返回栈错乱」：

| 入口 | 位置 |
|---|---|
| 首页 header → 统计 | `home_page.dart:213` |
| 首页「全部账单」→ 报表 | `home_page.dart:205`、`tx_list_module.dart:73` |
| 日历 → 统计 | `calendar_page.dart:317` |
| 日历「全部」→ 报表 | `calendar_page.dart:305`、`month_picker_page.dart:57` |

这一步是本候选**真正的工作量与风险所在**，不是配置本身。

### 要改什么

| 层 | 改动 |
|---|---|
| 注册表 | `NavDestinationRegistry`：id / 标签 / 图标 / branchIndex / 是否可放进槽位 |
| 配置 | `schema_meta.nav_config`（JSON：`{"slots":[4 个 id]}`），`sanitize`：去重、剔除未知 id、不足 4 个用默认补齐、`home` 必须在内 |
| 路由 | `app.dart` 扩到 6 个 branch（`/stats` `/reports` 挂进去，路径不变，深链仍可用） |
| 壳 | `_BottomNav` 的 `onTap` 从硬编码 switch 改成 `slots[i].branchIndex`；`currentIndex` 高亮改成「当前 branch 在 slots 里的位置」 |
| 设置页 | 新增「底部导航」子页：4 行槽位，每行一个选择器（候选下拉 / 底部弹层），样式沿用 `AppSettingsTile` + 树形页的小控件 |
| 测试 | 槽位映射 / 去重 / 缺失补齐 / 高亮位置；`stats` 作为分支后的首页入口回归 |

### 风险 / 边界

- **`/stats` `/reports` 改分支是破坏性重构**：涉及上表 6 处入口、返回键语义、可能的 golden。
  这是唯一可能「看起来小、做起来大」的地方，建议单独一次提交、单独 review。
- **不做**：改槽位数量（3~5 可配）、改 FAB 行为（固定 `/record`）、把任意子页塞进槽位（例如 `/import`）。
- **不做**：按账本区分导航（导航是设备级偏好，与 `dashboard_config` 同层，都存 `schema_meta` 不分账本）。

### 验收

- 换槽位后立即生效、重启保留；当前高亮永远落在「用户点的那个位置」；`/stats` 深链仍能直达；返回键不会出现空栈。

---

## 3 · 云同步布局

### 现状（代码事实）

- `dashboard_config` / `theme_seed` / `theme_mode` / `nav_config` 全在 `schema_meta` KV，**只在本机**。
- 备份 JSON（`buildBackupJson`）只含 `schemaVersion / exportedAt / book / accounts / categories /
  transactions / budgets` —— **不含任何设置**。换手机恢复后：账本回来了，布局和主题回默认。
- **release 包被刻意剥掉 `INTERNET` 权限**（`android/app/src/release/AndroidManifest.xml` 用
  `tools:node="remove"` 显式移除，注释写明「正式包必须去掉」「连 ML Kit 用量上报也物理上发不出去」）。
  debug / profile 才有 INTERNET（热重载需要）。
- `restoreBackupJson` 只按名字读已知键，**未知顶层键直接忽略** → 往备份里加 `settings` 段对旧版本是安全的。

### 三档方案

| 档 | 做什么 | 成本 | 结论 |
|---|---|---|---|
| **A** | **设置随备份走**：`buildBackupJson` 加 `settings` 段（`dashboard_config` / `theme_seed` / `theme_mode` / `nav_config` 白名单键）；`restoreBackupJson` 读到就写回 `schema_meta`，并在导入报告里显示「已恢复 N 项设置」 | **小**（约 200 LOC + 测试，不需要联网） | ✅ **建议只做这个**。它解决了真实痛点（换手机布局没了），且零隐私代价 |
| **B** | 局域网 / WebDAV 直连同步 | 中：加回 INTERNET + 域名白名单 + 冲突策略 | ⚠️ **与产品硬约束冲突**：本地优先、零上传是这个 App 的卖点（`v0.8.3` 验收里「无 INTERNET」是明确过的项）。要做必须先由你**改判产品定位**，不是技术任务 |
| **C** | 真云同步（账号 / 后端 / 多端冲突合并） | 大：账号体系 + 服务端 + 冲突合并 + 隐私合规 | ❌ **否决**。与「本地优先」定位正面冲突，且工程量远超 P5 级别 |

### A 档的实现要点（若批准）

- **白名单键**：只同步「用户偏好」，绝不碰 `active_book_id`、`autobook_last_run`、队列/批次等运行态。
- **合并策略**：**备份为准，覆盖本机**（不是 merge）—— 语义简单、可解释；导入报告里明确写「已覆盖外观与首页布局」。
- **去重口径**：用户可能只想要账本、不想被覆盖布局 → 导入页加一个开关「同时恢复外观与布局设置」，默认**开**。
- **不做的**：自动后台同步、定时同步、多设备增量。

### 验收

- 导出的 JSON 里能看到 `settings`；另一台机器导入后布局 / 主题 / 导航与导出机一致；关掉那个开关则设置不动。
- 旧备份（没有 `settings` 段）导入仍成功，设置保持本机现状。

---

## 需要你拍板的四件事

1. **导航自定义的范围**：只做「4 个槽位从 6 个候选里挑」够不够？要不要顺带允许 3 槽 / 5 槽？
2. **`/stats` `/reports` 改成 shell 分支**这件事能不能接受（会动返回栈语义，需要单独 review）？
3. **云同步**：只做 A 档（设置随备份走）是否满足你的预期？还是你确实想要跨设备自动同步（那就得先改产品定位、放回 INTERNET 权限）？
4. **非布尔参数**：先落哪 2–3 个真实参数？我建议 `tx_list.limit` / `budget_strip.style` / `month_hero.metric`。

## 建议的推进顺序（若四项都按建议走）

1. **非布尔参数**（地基，无破坏性）→ 2. **设置随备份走**（小而独立）→ 3. **导航自定义**（唯一有重构风险，放最后，单独 PR）。
