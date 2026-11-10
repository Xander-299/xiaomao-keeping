# SPEC · P5 第一批：非布尔模块参数 + 设置随备份走

> 状态：**已实现（2026-11-10）**，代码见 `feat/p5-params-settings-backup` 分支。
> 来源：用户在 2026-11-10 审阅 [`docs/handoff/p5-feasibility.md`](../handoff/p5-feasibility.md) 后裁定
> 「导航自定义暂时不做；先做非布尔参数和设置随备份」。导航项自定义（P5 第二项）**不在本 SPEC 范围**。

## 1. 背景与目标

P4 只做了布尔开关（`DashboardParamSpec.boolValue`），能表达的偏好太窄：
「账单显示几条」「预算副行看剩余还是已花」「示例问题几条」都不是「开/关」能说清的。
同时备份 JSON 只带账本数据（`book/accounts/categories/transactions/budgets`），换机后**布局与外观回默认**，
用户得重新摆一遍首页。

本批做两件事：

| # | 目标 | 一句话 |
|---|---|---|
| A | 模块参数类型系统 | 在 toggle 之外支持 `choice`（几选一）与 `count`（小整数），并把脏值容错钉死 |
| B | 设置随备份走 | 备份 JSON 加 `settings` 段（白名单键），换机恢复时外观与首页布局一起回来 |

## 2. 目标 1：非布尔模块参数

### 2.1 数据模型（`dashboard/dashboard_param.dart`）

```dart
enum DashboardParamKind { toggle, choice, count }

class DashboardParamOption { final String value; final String label; }

class DashboardParamSpec {
  final String id, title;
  final DashboardParamKind kind;
  final Object defaultValue;          // toggle→bool / choice→String / count→int
  final List<DashboardParamOption> options;
  final int min, max;                 // 仅 count
  Object value(Map<String,Object?>? params);   // 读：容错
  Object coerce(Object? raw);                   // 写：归一
  bool boolOf(...); String choiceOf(...); int countOf(...);
}
```

**兼容**：`DashboardParamSpec.boolValue(params, spec)` 静态入口保留（P4 调用方与测试都在用），
内部转调 `boolOf`。

### 2.2 容错口径（本 SPEC 的核心，逐条有测试）

| 输入 | 结果 |
|---|---|
| toggle 缺键 / 非 bool | 默认值 |
| choice 值不在 `options` 里 | 默认值 |
| choice 非字符串 | 默认值 |
| count 整数区间内 | 原值 |
| count 是 `10.0`（JSON number 常见形态） | 10 |
| count 是 `"4"` / `" 4 "`（手改 JSON） | 4 |
| count 是真小数 `3.7` | 默认值（**不四舍五入**） |
| count 越界（`999` / `0` / 负数） | 默认值（**不夹到边界**，见下） |
| count 非数字 / bool / null | 默认值 |

> 为什么越界不夹到边界：夹取等于「帮用户做了个他没要过的选择」——
> 手改 JSON 成 999 之后显示「50 条」会让人以为设置真的生效了。回落默认更容易被发现。

### 2.3 写入路径

`DashboardConfigController.setParam(moduleId, paramId, Object value)`：

1. `DashboardRegistry.specOf(moduleId, paramId)` 找声明；**找不到就忽略**（模块/参数已被删）；
2. `spec.coerce(value)` 归一（脏值不落库，否则下次启动读回来还是脏的）；
3. 走原有 `save()`（内部仍过 `DashboardRegistry.sanitize`）。

### 2.4 设置页（`dashboard_layout_page.dart`）

树的规矩不变：子项**只在展开父模块后**出现，字号仍比一级小。按 kind 渲染：

| kind | 控件 | key |
|---|---|---|
| toggle | 小开关 26×38（`FittedBox`，整行可点） | `dashboard_param_<模块>_<参数>` |
| choice | 一排小 chips（只有 chip 可点，行本身不响应，避免误触） | `dashboard_param_<模块>_<参数>_<值>` |
| count | 减 / 值 / 加 步进器，到边界那一侧置灰（不隐藏，避免行高跳动） | `..._minus` / `..._plus` |

### 2.5 本批落地的真实参数

| 模块 | 参数 | 类型 | 取值 | 行为 |
|---|---|---|---|---|
| `tx_list` | `limit` | choice | `all` / `10` / `20` | 首页只显示最近 N 笔（明细仍在「全部账单」里看全） |
| `budget_strip` | `detail` | choice | `remaining` / `spent` | 副行「还剩 ¥X」或「已花 ¥X」；**超支时两种口径都显示「已超支」** |
| `chat_entry` | `sample_count` | count | 1–3（默认 3） | 示例问题显示几条 |

## 3. 目标 2：设置随备份走

### 3.1 备份格式（向后兼容）

```jsonc
{
  "schemaVersion": 5,
  "exportedAt": "...",
  "book": {...}, "accounts": [...], "categories": [...],
  "transactions": [...], "budgets": [...],
  "settings": {                        // 新增，可选；空则不写这个键
    "dashboard_config": "<原样 JSON 字符串>",
    "theme_seed": "amber",
    "theme_mode": "light"
  }
}
```

值存**原始字符串**（`schema_meta` 的原值），备份层不复制各 feature 的 schema 解析逻辑；
新版本加字段时旧版本 App 原样写回也不会丢数据。

### 3.2 白名单（`import/application/backup_settings.dart`）

**能走**：`dashboard_config` / `theme_seed` / `theme_mode`。

**明确不走**（文件里写明理由，防止下次有人顺手加）：
- `active_book_id` —— 换机后账本 id 全变，写回旧 id 等于把用户指到一个空账本；
- `autobook_last_run` / `autobook_batches` —— 运行态诊断与待撤销批次，跨设备无意义；
- `onboarding_done` —— 「这台机器上是否看过引导」是设备级状态。

### 3.3 恢复流程（导入账单 → 选中备份文件）

1. `parseBillFileAuto` 识别为备份 → `backupHasSettings(bytes)` 嗅探有没有 `settings` 段；
2. 有 → 弹确认框「备份里带外观与布局」：**一并恢复**（默认）/ **只恢复账本**；
3. `restoreBackupJson(..., restoreSettings: bool)`：账本数据恢复完成后才写设置
   （数据恢复失败不该顺手改掉用户的外观）；
4. `settingsRestored > 0` 时导入页 `ref.invalidate` 三个 AsyncNotifier
   （`themeSeedProvider` / `themeModeProvider` / `dashboardConfigProvider`）——
   设置是直接写库的，不失效的话「恢复完看着还是旧主题，得杀进程才生效」；
5. 报告页多一行「恢复外观与布局 · N 项」。

### 3.4 幂等与失败

- 设置是**覆盖写**（备份为准），不是合并 —— 语义简单可解释，报告里写明覆盖了哪些；
- 单键写失败不影响其余键，更不影响账本数据恢复（`applyBackupSettings` 内部逐键 try）；
- 旧备份（无 `settings`）→ `settingsRestored = 0`，设置保持本机现状。

## 4. 非目标（明确不做）

- **导航项自定义**（P5 第二项）：用户 2026-11-10 裁定暂缓；
- 云同步 / 局域网同步（需要加回 `INTERNET` 权限，与「本地优先、零上传」冲突，见可行性文档）；
- 字符串自由输入参数、日期参数、跨模块联动参数；
- 设置的「合并」语义（只做覆盖）。

## 5. 验收 / 测试

| 文件 | 覆盖 |
|---|---|
| `test/features/ledger/dashboard_param_test.dart` | 三种 kind 的容错矩阵、越界回落、`specOf`、JSON 往返不吃 params |
| `test/features/ledger/dashboard_layout_page_test.dart` | 不展开看不到子项；chips 点击落库；步进器到边界置灰；账单条数三选一 |
| `test/features/import/backup_settings_test.dart` | 导出→新库导入设置落地；白名单挡住运行态键；「只恢复账本」不动设置；旧备份兼容 |

门禁：`dart analyze lib test` 0 issue + CI 四个 job 全绿。

## 6. 已知取舍

- **`count` 越界回落默认**而非夹取：更容易被发现、不替用户做选择；
- **设置恢复是覆盖**：多设备下最后导入的那份说了算（本项目无云同步，接受）；
- **一次问一句**：只有备份里真的带 `settings` 时才弹确认框，普通 CSV 导入流程零打扰。
