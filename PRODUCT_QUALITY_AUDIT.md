# PRODUCT_QUALITY_AUDIT.md

> 审计对象：`D:\new file\yanxin-flutter`（小耄记账）  
> 审计日期：2026-11-03  
> 审计性质：**只读产品质量审计**。本轮未修改生产代码、业务逻辑、测试、Golden、配置或依赖；只新增本报告。  
> 结论依据：当前工作区代码、当前测试套件、真实执行的 `flutter analyze` / `flutter test --concurrency=1`。无法从代码或测试直接证明的事项均标记为“待验证”。

## 0. 总览

### 0.1 质量概览

| 维度 | 结论 |
|---|---|
| 静态检查 | `flutter analyze --no-pub`：**0 issue**。 |
| 测试门禁 | `flutter test --concurrency=1`：**820 passed / 13 skipped / 0 failed**。 |
| 数据模型基础 | 金额统一整数分，时间统一毫秒 epoch，业务表使用软删除；核心表无外键约束，依赖 Repository / UI 校验维护一致性。 |
| 多账本隔离 | 主要查询按 `bookId` 隔离；但导入 / 自动记账 / 截图记账的去重指纹是**全局唯一**，跨账本会误判重复，是本轮最重要的产品级问题。 |
| 稳定性 | 常规成功路径有较完整的 Loading / Empty / Error / Success 处理；但部分写库入口缺少 UI catch，自动记账批量撤销不是原子操作。 |
| 测试质量 | Repository、聚合函数、核心 Widget、Golden、真实样本解析覆盖较好；但缺少跨账本指纹、分类改名后搜索快照、批量撤销中断等高风险回归测试。 |

### 0.2 总体判断

**PASS WITH ISSUES。**

应用的核心记账、查询、统计、导入和自动记账链路整体可用，常规数据口径基本一致，测试基础比一般早期产品更完整。但存在 1 个会直接影响多账本导入能力的 P1 问题，以及若干与异常恢复、数据一致性、产品能力缺口相关的 P2 问题。当前不建议继续扩大 UI 重构范围，应优先修复数据正确性与稳定性问题。

## 1. 门禁与执行证据

本轮在当前工作区真实执行：

```bash
flutter analyze --no-pub
flutter test --concurrency=1
```

结果：

| 命令 | 结果 |
|---|---|
| `flutter analyze --no-pub` | `No issues found!` |
| `flutter test --concurrency=1` | `820 passed / 13 skipped / 0 failed` |

测试中的 skip 主要包括两类：

1. 真实微信 / 支付宝账单 fixture 缺失导致的真实样本导入测试跳过。
2. 已知的 1.3x 文本缩放页面 Golden 跳过，属于此前设计验收已记录的 UI 布局遗留，不是本轮功能失败。

此外，`test/features/ledger/swipe_action_test.dart` 在本轮测试输出中出现一次 `tap()` 未命中目标 offset 的 warning。测试最终通过，不是失败，但说明该用例对渲染位置较敏感，建议后续改用 key 或显式 offset 定位。

## 2. 核心业务流程覆盖矩阵

下表中：

- **代码**：主要入口与关键实现。
- **数据链路**：涉及的模型 / Repository / 聚合逻辑。
- **测试**：当前已有覆盖。
- **残余风险**：现有测试或实现仍暴露的风险。

| # | 流程 | 入口 / 核心代码 | 数据链路与关键规则 | 已有测试 | 残余风险 |
|---:|---|---|---|---|---|
| 1 | 新增记账 | 首页 FAB：`lib/features/nav/presentation/app_shell.dart`；记账页：`lib/features/record/presentation/record_page.dart` | 当前账本、账户、分类、金额、发生时间写入 `transactions`；`source='manual'` 时 `fingerprint=null`，允许同金额同时间重复记账；金额必须正整数分 | `test/widget_test.dart`、`test/features/record/*`、`test/data/repositories/transaction_repository_test.dart` | 手动保存只有 `finally`，没有 `catch`；数据库异常可能冒泡为未捕获异步异常。 |
| 2 | 编辑记账 | 记账页 `txId` 模式：`record_page.dart:178-236` | `TransactionRepository.update()` 只更新金额、分类、账户、时间、备注，不改变 `bookId`；更新 `dirty=1` | 金额 / 账户 / 保存入口测试覆盖较好 | 编辑模式下数据库异常同样缺 UI catch；跨账本编辑的理论边界缺少集成测试。 |
| 3 | 删除记账与 Undo | 首页：`home_page.dart:128-160`；日历：`calendar_page.dart:130-163`；搜索：`search_overlay.dart:159-196` | 软删除 `deleted_at`；`restoreTx()` 写回 `deleted_at=null`；同指纹活跃行冲突时 Undo 返回 false；恢复保留原 id / 金额 / 分类 / 账户 / 时间 / 备注 | `transaction_repository_test.dart`、首页 / 日历 / 搜索删除用例 | 低风险删除成功路径完整，但软删除失败的 UI catch 不统一；自动记账批量撤销另有独立风险。 |
| 4 | 账户管理 | 资产页：`lib/features/assets/presentation/assets_page.dart`；表单：`account_form_sheet.dart` | `accounts` 按 `bookId` 隔离；余额 = 初始余额 + Σ收入 − Σ支出，transfer 不计入；有流水账户 UI 禁止删除 | `account_repository_test.dart`、`asset_aggregate_test.dart`、`assets_page_test.dart` | 数据层无唯一名约束；导入 / 自动记账按账户名匹配账户，可能命中用户自建同名账户。 |
| 5 | 账本管理 | `lib/features/book/presentation/book_manage_page.dart`；`BookRepository` | 新建账本事务内创建默认账户与预置分类；`active_book_id` 持久化；主要查询按 `bookId` 隔离 | `book_repository_test.dart`、首页切账本用例 | UI 只有新建 / 切换；Repository 支持编辑 / 软删但无编辑 / 删除入口，产品能力不完整。 |
| 6 | 分类管理 | `lib/features/category/presentation/category_manage_page.dart`；`lib/features/category/application/category_actions.dart` | 支持一级 / 二级、归档、无引用删除、迁移后删除、排序；`ensurePresets()` 幂等补预置分类 | `category_repository_test.dart`、`category_manage_page_test.dart`、`category_sheets_test.dart` | 分类改名 / 新建后不会 bump `dataEpochProvider`，常驻搜索快照可能保留旧分类名。 |
| 7 | 预算管理 | 首页预算条：`budget_strip.dart`；编辑弹层：`budget_edit_sheet.dart`；`BudgetRepository` | 预算按 `bookId + YYYY-MM` 存；已删除预算可重设；消费口径为当月 expense | `budget_repository_test.dart`、`budget_metrics_test.dart`、`budget_strip_test.dart` | 当前 UI 只能编辑首页当前月，不能直接设置历史月或未来月。 |
| 8 | 日历查询 | `lib/features/calendar/presentation/calendar_page.dart`；`calendar_controller.dart` | 网格先渲染，选中日账单与整月聚合分两段加载；翻月不改变选中日；未来月禁止进入 | `calendar_page_test.dart`、`calendar_aggregate_test.dart`、`month_picker_page_test.dart` | 翻月 / 选日并发有基础守卫；但真实设备长时间驻留跨午夜场景未验证。 |
| 9 | 搜索 | `lib/features/search/presentation/search_overlay.dart`；`search_controller.dart`；`search_query.dart` | 一次载入当前账本全量流水、分类名、账户名后在内存过滤；支持备注 / 分类 / 账户 / 金额 / 类型 / 时间区间 | `search_query_test.dart`、`search_overlay_test.dart`、`search_freshness_test.dart` | `searchProvider` 只 watch `dataEpochProvider`；分类编辑不 bump epoch，改名后快照可能过期。 |
| 10 | 资产统计 | `lib/features/assets/application/assets_controller.dart`；`asset_aggregate.dart` | 当前账本账户 + 全时间未删流水；transfer 不计入账户余额；净资产可负 | `assets_page_test.dart`、`asset_aggregate_test.dart` | 账户软删后历史流水仍指向原账户 id；UI 有防护，但数据层无外键。 |
| 11 | 收支统计 | `lib/features/stats/presentation/stats_page.dart`；`stats_controller.dart`；`stats_aggregate.dart` | 分类占比只统计指定方向；近 6 月趋势跨年补零；transfer 不计收支 | `stats_aggregate_test.dart`、`stats_page_test.dart` | 统计页月份状态独立；长时间驻留后月份不会自动跟随真实日期，属低风险产品语义。 |
| 12 | 报表 | `lib/features/reports/presentation/reports_page.dart`；`reports_controller.dart`；`report_aggregate.dart` | 明细 / 分类 / 账户三档；`dataEpochProvider` 变化后静默刷新但保留月份和档位 | `report_aggregate_test.dart`、`reports_page_test.dart` | 已删除账户归入“其他账户”是明确展示策略；但删除账户后历史账单关联关系仍是软关联。 |
| 13 | 数据导入 | `lib/features/import/presentation/import_page.dart`；`lib/features/import/application/bill_importer.dart` | 逐行解析、文件内去重、单事务导入、异常整体回滚；指纹命中则跳过 | `bill_importer_test.dart`、`bill_normalize_test.dart`、`bill_csv_test.dart`、`import_page_test.dart` | 指纹唯一索引不带 `bookId`，同一外部账单无法导入到第二个账本，详见 P1。 |
| 14 | 自动记账 | `lib/features/autobook/application/auto_book_controller.dart`；`auto_book_notice.dart`；`auto_book_batches.dart` | 队列 drain → 解析 → 按 source 分组 → 复用导入事务 → 批次记录 / 回执；失败把原始行回写队列 | `auto_book_flow_test.dart`、`auto_book_rules_test.dart`、真实样本测试 | 批量撤销逐笔软删后再 `forget(batchId)`，非原子；批次记录在入账与落库之间也有崩溃窗口。 |
| 15 | AI 聊天 / 截图记账 | `lib/features/chat/application/chat_controller.dart`；`lib/features/receipt/application/receipt_write.dart` | 文字问答复用本地账本聚合；截图 OCR 只生成待确认草稿，确认后走 `importTransaction(source='screenshot')`；未确认不写库 | `chat_controller_test.dart`、`receipt_parse_test.dart`、`receipt_write_test.dart`、真实样本测试 | 截图记账复用全局指纹，跨账本重复确认会被误判重复；OCR / 语义解析精度依赖真实设备样本。 |
| 16 | 设置 / 主题 / 偏好 | `lib/features/settings/presentation/settings_page.dart`；`theme_controller.dart` | 外观模式和主题色写入 `schema_meta`；读库失败或脏值回落默认值，不阻断启动 | `settings_page_test.dart`、`theme_controller_test.dart` | 偏好写入失败时当前会话仍生效，重启回落旧值；这是明确设计，不视为数据风险。 |

## 3. 数据正确性审计

### 3.1 金额精度与舍入

**结论：当前金额基础口径是可靠的。**

- `Transactions.amountCents` 为整数分，且表级 CHECK 约束要求 `amount_cents > 0`，见 `lib/core/db/tables.dart:174-219`。
- `yuanToCents()` 使用字符串解析和整数拼接，不引入浮点；`centsToYuan()` 输出两位小数，见 `lib/core/utils/money.dart:9-38`。
- 手工输入限制最多两位小数和 9 位整数位，见 `lib/features/record/presentation/widgets/amount_keyboard.dart` 与 `test/features/record/amount_input_test.dart`。
- 预算百分比、日均支出等展示计算使用整数分和整数运算，见 `lib/features/ledger/application/budget_metrics.dart:82-127`、`lib/features/calendar/application/calendar_aggregate.dart:58-71`。

已有测试包括 `test/core/utils/money_test.dart`，明确覆盖 `0.1 + 0.2` 的整数分结果。

### 3.2 收入、支出、转账口径

**结论：常规收支与展示口径一致；transfer 的产品入口与数据口径存在不对称。**

- `MonthSummary.summarize()` 只统计 `income` 和 `expense`，transfer 不计入收支，见 `lib/features/ledger/application/month_summary.dart`。
- `AssetSummary` 中 transfer 被明确跳过，不计入任何账户余额，见 `lib/features/assets/application/asset_aggregate.dart:62-94`。
- `StatsAggregate.categoryBreakdown()` 只匹配指定方向，transfer 天然排除，见 `lib/features/stats/application/stats_aggregate.dart:64-95`。
- 报表的账户档会把 transfer 单独聚合，分类档也会单列转账，见 `lib/features/reports/application/report_aggregate.dart:104-159`。

需要说明：数据模型支持 `transfer`，搜索 / 报表也有展示路径，但当前记账页只提供“支出 / 收入”两个入口，导入解析方向也限定为 `expense` / `income`。因此 transfer 目前更接近预留数据能力，不是完整业务流程。未发现错误计算，但这是功能口径不完整的已知边界。

### 3.3 账户余额与编辑 / 删除后的回算

**结论：余额不是持久化字段，而是从初始余额和未删流水实时聚合，编辑 / 删除 / Undo 后可通过刷新得到一致结果。**

- 账户余额公式：`initialBalanceCents + Σincome - Σexpense`，见 `asset_aggregate.dart:31-37`。
- `AssetSummary.netCents` 是各账户余额之和，允许负值。
- `TransactionRepository.update()` 更新金额 / 分类 / 账户 / 时间后，`AssetsController` 通过 `dataEpochProvider.bump()` 重新聚合，见 `record_page.dart:222-231`、`assets_controller.dart:20-32`。
- 软删除后默认查询过滤 `deletedAt`；`restoreTx()` 恢复同一条记录，不重建对象，见 `transaction_repository.dart:200-242`。

### 3.4 预算周期与金额口径

**结论：预算存储与计算口径清楚，但产品入口限制较强。**

- `BudgetRepository.periodOf()` 使用零填充 `YYYY-MM`，部分唯一索引约束“账本 + 月份”只有一条未删除预算，见 `budget_repository.dart:20-104`、`lib/core/db/schema_v2.dart:8-15`。
- 预算消费 = 当前月 `expense` 合计，收入与 transfer 不计入。
- 当月日均按已过天数计算，历史月按整月天数计算，未来月按整月天数摊剩余额度，见 `budget_metrics.dart:92-127`。
- UI 通过 `ledgerProvider` 获取当前月，因此首页翻月时预算会跟随，见 `budget_controller.dart:1-60`。

限制：预算编辑弹层只绑定首页当前显示月份，没有独立的历史 / 未来预算管理入口。

### 3.5 分类统计

**结论：一级 / 二级分类在统计和问答中的口径已有明确区分，聚合函数有测试。**

- `categoryBreakdown()` 按分类 id 汇总，查不到名字统一归“未分类”，见 `stats_aggregate.dart:64-95`。
- 问答中“问父级计入二级”与“问二级只算二级”的规则在 `test/features/assistant/finance_answer_test.dart` 有覆盖。
- 报表分类档按展示名合并，未分类统一一行，见 `report_aggregate.dart:104-126`。

风险：搜索快照中的分类名不会在分类改名后自动刷新，详见问题 P2-006。

### 3.6 跨月、跨年、闰年和时区

**结论：本地时区口径明确，常规边界有测试；极端设备时间状态未做真实验证。**

- `TransactionRepository.listByMonth()` 使用本地 `DateTime(year, month, 1)` 与 `DateTime(year, month + 1, 1)` 构造半开区间。
- `listByYear()`、`trendRange()`、搜索时间窗、问答时间区间均按本地时区构造。
- `test/core/utils/date_test.dart` 覆盖月末最后一刻、下月第一刻、闰年 2 月、跨年。
- `test/features/stats/stats_aggregate_test.dart` 覆盖趋势跨年。
- `test/features/assistant/finance_intent_test.dart` 覆盖“上个月”在 1 月跨年、显式年月、“最近三个月”等场景。

限制：`ledgerProvider` / `statsProvider` / `reportsProvider` 在 build 时读取 `DateTime.now()`，页面或 provider 长时间驻留时不会自动跨到新一天 / 新一月。日历 `CalendarController.build()` 同样如此。该行为是否算问题取决于产品预期，当前按 P3 风险记录。

### 3.7 多账本隔离

**结论：查询层按账本隔离基本完整，但导入 / 自动记账 / 截图记账的去重指纹全局唯一，破坏了实际导入语义。**

所有核心查询都带 `bookId`：

- `TransactionRepository.listByMonth()`、`listByYear()`、`listByRange()`、`listByBook()`。
- `AccountRepository.listByBook()`。
- `CategoryRepository.listByBook()`。
- `BudgetRepository.getForMonth()`。

测试也覆盖了切换账本后首页刷新、账本间流水隔离、预算账本隔离。

但是 `transactions.fingerprint` 的唯一索引只按 `fingerprint` 建立唯一，没有 `bookId`：

```sql
CREATE UNIQUE INDEX IF NOT EXISTS idx_tx_fingerprint
ON transactions(fingerprint)
WHERE fingerprint IS NOT NULL AND deleted_at IS NULL
```

见 `lib/core/db/schema_v1.dart:17-22`。

`importTransaction()` 查重时也只按 fingerprint 查询：

```dart
..where((t) => t.fingerprint.equals(fp) & t.deletedAt.isNull())
```

见 `transaction_repository.dart:278-287`。因此同一笔真实外部账单导入 A 账本后，再导入 B 账本会被判 `ImportDuplicate`。该问题适用于微信 / 支付宝账单导入、通知自动记账、截图记账三条链路。

### 3.8 导入重复识别

**结论：同一账本内的重复导入识别可靠，跨账本语义错误。**

`importRows()` 的设计是：

1. 文件内先按指纹去重。
2. 分批 500 条 `IN` 预查已存在指纹。
3. 单事务内逐条 `importTransaction()`。
4. 非 duplicate 异常整体回滚。

见 `bill_importer.dart:128-256`。相关测试覆盖同文件重复导入、软删后重导、文件内重复行、异常回滚、分批边界。

问题是预查 SQL 也不带 `bookId`：

```sql
SELECT fingerprint FROM transactions
WHERE fingerprint IN (...) AND deleted_at IS NULL
```

见 `bill_importer.dart:190-206`。因此跨账本重复不是“防重复入账”，而是“第二个账本无法入账”。

### 3.9 Undo 是否完整恢复数据

**结论：单条流水 Undo 与无引用分类 Undo 是真实恢复，不是假 Undo。**

流水：

- 删除只写 `deletedAt`，不物理删除。
- Undo 调 `restoreTx()`，恢复的是同一条记录；id、金额、分类、账户、时间、备注、`fingerprint` 等字段保留。
- 若恢复时同指纹活跃行已存在，`restoreTx()` 返回 false，UI 显示“无法撤销：同指纹记录已存在”。

见 `transaction_repository.dart:214-242`、`home_page.dart:145-159`、`calendar_page.dart:147-160`。

分类：

- 只有“无账单引用且无子分类”的分类才会直接删除。
- `undelete()` 恢复原记录，并要求原父分类仍存在；同名活跃分类冲突或父分类已删除时返回 false。
- 不做“父分类没了就自动升一级”的部分恢复。

见 `category_repository.dart:445-508`、`category_manage_page.dart:493-520`。

自动记账批次撤销不是单条流水 Undo，而是批量撤销，存在非原子风险，详见问题 P2-002。

### 3.10 删除关联数据与孤儿记录

**结论：UI 层有较多防护，但数据层没有外键约束，存在理论上可产生孤儿引用的边界。**

`transactions.account_id`、`transactions.category_id`、`transactions.book_id` 都没有数据库级外键约束。账本、账户、分类、预算的删除全部是软删除。

现有防护：

- 账户删除前，资产页读取当前快照中账户流水数；有流水时阻止删除，见 `account_form_sheet.dart:161-205`。
- 分类直接删除前检查账单引用和子分类；有引用 / 子分类则要求归档或迁移，见 `category_repository.dart:445-468`。
- 分类迁移和删除在事务内完成，子分类先删，父分类后删，见 `category_repository.dart:510-564`。

风险：

- 如果未来新增写入口绕过 UI 校验，或直接调用 Repository，可以留下指向已软删账户 / 分类 / 账本的流水。
- 软删账本、账户、分类本身不会级联软删下级数据；设计上可能是有意的“数据永不物理删除”，但当前缺少统一的孤儿数据检查与数据修复视图。

### 3.11 异步写入与数据竞争

**结论：常规路径有防重入和统一刷新机制，但写入异常处理和数据版本号约定仍有遗漏。**

已有的保护：

- `AutoBookController.drain()` 使用 `_draining` 防重入，见 `auto_book_controller.dart:75-85`。
- `CalendarController.refresh()` 使用 `_busy` 防重入，并且 `_disposed` 防止 provider 释放后写 state，见 `calendar_controller.dart:137-217`。
- 导入使用单事务，异常整体回滚，见 `bill_importer.dart:187-256`。
- 账本创建在事务内创建默认账户和预置分类，见 `book_repository.dart:23-69`。
- 写后刷新统一到 `refreshAfterWrite()`，并吞掉刷新异常，避免刷新失败影响主流程，见 `lib/core/providers/after_write.dart:24-47`。

仍有风险：

- 手动记账 / 编辑保存、首页 / 日历 / 搜索低风险删除没有统一 catch。
- `CategoryActions` 成功后只 invalidate 分类 provider，不 bump `dataEpochProvider`，导致常驻搜索快照过期。
- 自动记账按 source 分组、每组一次事务；第二组失败时第一组可能已提交，但原始队列会回写，下次 drain 靠指纹避免重复。该行为可恢复，但当前 drain 会表现为失败。
- 自动记账“先写流水、后记录批次”之间存在崩溃窗口；如果进程在窗口内退出，流水已入账但批次记录 / 回执缺失。此为代码路径推断，未做真实崩溃复现，标记待验证。

## 4. 稳定性审计

### 4.1 页面重复进入与退出

主要 Provider 的状态设计基本能避免明显生命周期问题：

- 日历使用同步首帧 + 两段异步加载，`_disposed` 防止迟到结果写 state。
- 搜索是常驻 Provider，浮层关闭再打开不会重复重建；写后通过 `dataEpochProvider` 失效。
- 报表使用 `ref.listen(dataEpochProvider)` 而不是直接重建，保留用户翻到的月份和档位。
- 记账页在异步补载编辑数据前检查 `mounted`。

未见明显页面重复进入导致重复 Provider 或重复写库的证据。

### 4.2 异步请求完成时页面已销毁

多数 UI 在异步返回后检查 `mounted`：

- 记账页 `_loadTx()`、`_save()` 检查 `mounted`。
- 账户 / 预算表单在 pop 前先取 `NavigatorState` / `ScaffoldMessengerState`，避免销毁后使用失效 context。
- 自动记账和写后刷新吞异常，不把后台失败冒泡到 UI。

风险：首页 / 日历 / 搜索删除的 Undo 回调如果发生在页面或浮层销毁后，数据恢复仍会执行，但错误提示可能无法展示。当前代码有 `context.mounted` / `mounted` 检查，但没有真实设备连续快速操作验证，标记待验证。

### 4.3 连续点击提交

- 记账页有 `_saving` 状态，保存按钮在 saving 时禁用。
- 导入页有 `_importing` 状态，确认导入按钮在导入中禁用。
- 账户 / 预算表单有 `_busy` 状态。
- 自动记账 drain 有 `_draining` 防重入。

未发现明显的重复提交漏洞，但缺少针对“数据库写入慢 / 连续点击”的专项测试。

### 4.4 快速连续删除和撤销

单条流水删除会立即软删，并展示 4 秒 SnackBar Undo。连续删除时新反馈会替换当前反馈，只保留最近一次 Undo。这个行为与既有统一反馈 API 一致。

风险：

- 连续删除 A、B 后只展示 B 的 Undo，A 无法从 UI 再撤销。这是设计行为，不是 Bug。
- 如果 A 的 SnackBar 还在展示、页面被销毁或切换路由，Undo 回调的 UI 反馈可能受影响；数据层恢复逻辑仍会执行。未做真实设备验证。

### 4.5 网络 / AI 服务失败

当前聊天不是远程 LLM 服务：

- 文字问答是本地意图解析 + 本地账本数据聚合。
- 截图记账使用端上 ML Kit OCR。
- OCR 失败有专用 `OcrFailure`，聊天层转换成用户可读提示。
- 未识别问题返回示例问题，不伪造答案。

相关测试覆盖空问题、不认识的问题、OCR 通道不可用、支付失败截图、重复截图确认等。

### 4.6 数据库读写失败

Repository 层多数异常会向上抛出，导入 / 账本创建依赖事务回滚。UI 层处理不一致：

| 入口 | 数据库异常处理 |
|---|---|
| 导入确认 | 有整体 catch，显示“导入失败”。 |
| 自动记账写库 | 捕获后回写队列，等下次重试。 |
| 截图记账确认 | `writeReceipt()` 返回 `ReceiptWriteFailed`，UI 显示错误。 |
| 手动记账 / 编辑 | 只有 `finally`，无 `catch`。 |
| 首页 / 日历 / 搜索单条删除 | 无明显 catch。 |
| 账户 / 预算表单 | 有 catch，显示错误。 |

### 4.7 导入中断

导入主事务会整体回滚，避免半截数据。页面有 `_importing` 状态防止重复提交。

风险：

1. 用户在导入中杀进程：SQLite 事务应回滚，但当前没有真实中断测试。
2. 导入完成后、UI setState 前页面退出：数据已入库，用户看不到报告。这不是数据不一致，但属于体验边界。

### 4.8 应用退出和重启一致性

正向路径可靠：

- `active_book_id`、主题、搜索历史、自动记账批次都落在本地数据库 `schema_meta`。
- 流水、账户、分类、预算均落库。
- 新建账本和导入使用事务。

自动记账是重点边界：

- 原始队列“取走即清空”，写库失败会回写队列。
- 指纹去重保证回写后不会重复入账。
- 但如果入账成功后、批次记录 `store.remember()` 前崩溃，重启后流水可见但没有可撤销批次。该窗口未实测，标记待验证。

### 4.9 Loading / Empty / Error / Success

主要页面状态覆盖较好：

| 页面 / 模块 | Loading | Empty | Error | Success / 数据态 |
|---|---|---|---|---|
| 首页 | 有；翻月 / 写后刷新不闪 loading | 有空月引导 | 有统一错误态 | 有 |
| 日历 | 网格先出，日 / 月数据分两段加载 | 有 | 有 | 有 |
| 资产 | 有 | 有 | 有 + 重试 | 有 |
| 统计 | 翻月保留旧内容 | 有 | 有 | 有 |
| 报表 | 静默刷新，不重置状态 | 有 | 有 | 有 |
| 账本抽屉 | 有 | 有 | 统一错误态 + 重试 | 有 |
| 月份选择 | 有 | 空年视为 Success | 统一错误态 + 重试 | 有 |
| 导入 | 有 | 文件无可导入行有报告 | 有 | 有 |
| 自动记账 | 页面状态较多，测试覆盖 | 有 | 有诊断 / 错误信息 | 有 |
| 聊天 | busy | 示例问题 | 用户可读错误 | 有 |
| 设置 | 默认值渲染 | N/A | 读库失败回落默认 | 有 |

## 5. 测试覆盖审计

### 5.1 数量与分布

当前测试套件共 **820 passed / 13 skipped / 0 failed**。

覆盖重点：

| 类型 | 覆盖情况 |
|---|---|
| Repository 单元测试 | transaction、account、book、category、budget、app meta 均有直接测试。 |
| 纯聚合测试 | MonthSummary、AssetSummary、StatsAggregate、ReportAggregate、BudgetMetrics、日历聚合、金额 / 日期 / 指纹均有测试。 |
| Widget 测试 | 首页、日历、资产、统计、报表、搜索、导入、自动记账、分类、账本、预算、聊天、设置、导航壳均有测试。 |
| Golden 测试 | 既有组件 + 页面 Golden 基线共 52 张；本轮全量非更新模式通过。 |
| 真实样本 | 自动记账通知、微信 / 支付宝账单解析、OCR 截图均有真实或近似真实样本测试。 |

### 5.2 高风险覆盖不足

以下缺口与当前发现直接相关：

1. **跨账本指纹去重没有测试**  
   现有 duplicate 测试基本在同一个账本内。没有“同一笔外部账单导入 A/B 两个账本，B 是否应入账”的测试。

2. **分类改名后搜索快照没有测试**  
   `searchProvider` 只在 `dataEpochProvider` 变化时重建；`CategoryActions` 不 bump。没有“改名后搜索新分类名 / 显示新名称”的回归测试。

3. **自动记账撤销中断没有测试**  
   现有测试覆盖整批撤销成功与重复撤销，但没有覆盖第一笔成功、第二笔失败、批次记录是否保留、再次撤销是否可恢复。

4. **手动记账 / 编辑数据库异常没有 UI 测试**  
   现有测试主要覆盖成功路径和输入校验，没有模拟 Repository 抛异常后页面是否保留表单、是否显示错误。

5. **低风险删除数据库异常没有测试**  
   首页 / 日历 / 搜索删除成功路径有覆盖，但没有验证数据库失败时是否残留 UI 展开态或未处理异常。

6. **真实账单 fixture 缺失导致部分测试跳过**  
   `test/features/import/real_bills_test.dart` 中真实微信 / 支付宝账单样本缺失，降低了对真实导入格式的端到端保障。

### 5.3 测试质量观察

优点：

- 聚合逻辑大量抽成纯函数，测试稳定。
- Repository 使用内存数据库，验证持久化语义。
- 多数测试命名明确表达业务口径。
- 自动记账测试覆盖大量真实通知样本文案。

需注意：

- `swipe_action_test.dart` 出现一次 `tap()` hit-test warning，建议改用 key 定位。
- 部分 Widget 测试侧重 UI 状态，但对数据库最终状态也有检查，例如搜索删除、导入流程。
- 少数测试依赖真实文件 fixture，当前因文件缺失跳过。

## 6. 问题清单

### P0

未发现 P0 问题。

未发现明确的：

- 数据丢失路径；
- 金额计算错误；
- 严重安全或隐私泄露路径；
- 常规核心流程完全不可用。

---

### P1-001 外部交易指纹全局唯一，跨账本无法导入同一笔账单

| 项 | 内容 |
|---|---|
| 问题描述 | `transactions.fingerprint` 唯一索引不包含 `bookId`；`importTransaction()` 与 `importRows()` 查重也不带 `bookId`。同一笔外部账单导入 A 账本后，无法导入 B 账本。 |
| 复现条件 | 1) 在 A 账本导入或自动记入某笔微信 / 支付宝账单；2) 切换到 B 账本；3) 再次导入同一份账单或同一笔通知；4) 第二次命中 `ImportDuplicate`。 |
| 影响范围 | 文件导入、通知自动记账、截图记账。多账本用户会把同一笔真实账单分别记入不同账本的能力被阻断。 |
| 相关文件 | `lib/core/db/schema_v1.dart:17-22`；`lib/data/repositories/transaction_repository.dart:278-287`；`lib/features/import/application/bill_importer.dart:190-235`；`lib/features/receipt/application/receipt_write.dart:84-99`。 |
| 根因 | 指纹被设计成全局防重复，但业务语义应是“同一账本内同一笔外部交易只入一次”。指纹值本身也不包含账本维度。 |
| 建议修复 | 短期：将查重 SQL、`importTransaction()` 查重和唯一索引语义改为 `bookId + fingerprint`。若不改表结构，可先生成含 `bookId` 的指纹，但这会破坏旧数据去重，需要迁移。长期：新增 `book_id + fingerprint` 部分唯一索引，并清理旧全局指纹索引；评估软删后重导、备份导入、旧数据迁移。 |
| 建议测试 | 1) A 账本导入后 B 账本再导入同一文件应新增；2) 同一账本重复导入仍全 duplicate；3) A 账本删除后重导仍可入账；4) 自动记账 / 截图记账分别在两个账本确认不互相阻断；5) 老库迁移后既有数据不丢失、去重行为符合迁移策略。 |
| 优先级 | P1 |
| 证据与确认程度 | 代码证据明确。复现步骤可从当前实现直接推导；本轮未实际操作真机，但属于高置信度问题。 |

---

### P2-001 手动记账 / 编辑保存缺少数据库异常 catch

| 项 | 内容 |
|---|---|
| 问题描述 | `RecordPage._save()` 使用 `try { ... } finally { ... }`，没有 `catch`。数据库写入失败或 Repository 校验异常会继续向上冒泡。 |
| 复现条件 | 保存时数据库关闭、磁盘异常、约束异常或 Repository 抛错。 |
| 影响范围 | 新增记账 / 编辑记账。用户可能看不到保存失败提示；Flutter 侧可能出现未处理异步异常。 |
| 相关文件 | `lib/features/record/presentation/record_page.dart:178-236`。 |
| 根因 | UI 成功路径完整，但异常路径没有统一包装。 |
| 建议修复 | catch 数据库 / 参数异常；保持页面不关闭；显示统一错误反馈；恢复 `_saving=false`；必要时提供重试。 |
| 建议测试 | 模拟 `TransactionRepository.create()` / `update()` 抛异常，断言页面不 pop、按钮恢复、表单内容保留、显示错误。 |
| 优先级 | P2 |
| 证据与确认程度 | 代码证据明确；未在真实设备复现数据库异常。 |

---

### P2-002 自动记账批量撤销非原子

| 项 | 内容 |
|---|---|
| 问题描述 | `AutoBookNoticeNotifier.undo()` 循环调用 `softDelete()`，全部完成后才 `store.forget(batchId)`。中途异常或崩溃会留下部分撤销状态，且批次记录可能仍存在。 |
| 复现条件 | 批次包含多笔流水；撤销过程中第一笔成功、后续数据库失败或进程被杀。 |
| 影响范围 | 自动记账撤销入口，包括首页横幅和通知栏跨启动撤销。 |
| 相关文件 | `lib/features/autobook/application/auto_book_notice.dart:38-56`；`lib/features/autobook/data/auto_book_batches.dart:73-141`。 |
| 根因 | 多笔软删和批次元数据更新不在同一个事务。 |
| 建议修复 | 在一个事务内：按批次软删全部目标流水，成功后删除批次记录；然后刷新 UI。若部分目标已删，可继续软删，保持幂等。 |
| 建议测试 | 模拟第 N 笔 `softDelete()` 抛异常；断言事务回滚、批次记录仍在、再次撤销可完成。另覆盖重复撤销、跨启动撤销。 |
| 优先级 | P2 |
| 证据与确认程度 | 代码证据明确；崩溃窗口未真实复现。 |

---

### P2-003 导入 / 自动记账按显示账户名匹配账户，可能归属错账户

| 项 | 内容 |
|---|---|
| 问题描述 | 导入使用 `ensureImportAccount()` 查找名为“导入账户”的账户；自动记账使用 `ensureSourceAccount()` 查找“微信”“支付宝”“分享记账”。匹配依据只是账户显示名。 |
| 复现条件 | 用户先手动创建一个名为“微信”的储蓄账户并设置初始余额，然后开启自动记账；新通知会写入该账户，而不是新建的自动记账账户。 |
| 影响范围 | 导入流水、自动记账流水的账户归属和资产余额分布。金额本身不变，但账户语义可能不符合用户预期。 |
| 相关文件 | `lib/features/import/application/bill_importer.dart:73-88`；`lib/features/autobook/application/auto_book_accounts.dart:16-31`。 |
| 根因 | 用显示名作为业务身份；账户名没有唯一约束，也没有独立的系统账户标识。 |
| 建议修复 | 为导入 / 自动记账来源引入稳定的账户元数据字段或预设账户标识，不依赖用户可编辑显示名。同时设计老数据迁移策略。 |
| 建议测试 | 1) 用户已有同名账户时导入 / 自动记账是否使用该账户；2) 改名后是否仍保持原身份；3) 新老数据迁移后余额不变。 |
| 优先级 | P2 |
| 证据与确认程度 | 代码路径明确；未复现用户真实数据错账案例。 |

---

### P2-004 预算只能编辑首页当前显示月份

| 项 | 内容 |
|---|---|
| 问题描述 | 预算弹层读取 `ledgerProvider` 当前年月，没有选择月份入口；首页通常只能翻到当前月，因此不能直接编辑历史月或未来月预算。 |
| 复现条件 | 用户想提前设置下月预算，或补设上个月预算。 |
| 影响范围 | 预算管理产品能力，不造成金额错误。 |
| 相关文件 | `lib/features/ledger/presentation/widgets/budget_edit_sheet.dart:76-130`；`lib/features/ledger/application/budget_controller.dart:31-60`。 |
| 根因 | 预算 UI 与首页当前月强绑定。 |
| 建议修复 | 如果产品确认需要历史 / 未来预算，增加月份选择；否则在文案中明确“仅当前月”。 |
| 建议测试 | 设置 / 清除任意指定月份预算；首页切到该月时读取正确；跨年边界正确。 |
| 优先级 | P2 |
| 证据与确认程度 | 代码证据明确。 |

---

### P2-005 软删除不级联，数据层缺少孤儿引用防御

| 项 | 内容 |
|---|---|
| 问题描述 | 账本、账户、分类均只软删自身，不会级联处理下属数据；表之间无外键约束。 |
| 复现条件 | 直接调用 Repository 软删账户 / 分类 / 账本，或未来新增绕过 UI 的写入口。 |
| 影响范围 | 历史流水可能继续指向已软删账户 / 分类 / 账本；统计展示层多归入“其他账户”或“未分类”，但缺少数据一致性检查。 |
| 相关文件 | `lib/data/repositories/account_repository.dart:111-123`；`lib/data/repositories/book_repository.dart:125-137`；`lib/data/repositories/category_repository.dart:382-508`；`lib/core/db/tables.dart`。 |
| 根因 | 当前架构以软删除保留历史数据，未建立数据库级关系约束或统一清理策略。 |
| 建议修复 | 不必贸然加外键；可先建立孤儿引用扫描 / 诊断工具，明确业务策略：保留历史关联、展示兜底、还是禁止删除。 |
| 建议测试 | 对每类删除构造关联数据，验证查询与展示口径；对直接 Repository 删除路径断言当前策略。 |
| 优先级 | P2 |
| 证据与确认程度 | 结构性风险明确；当前 UI 路径有防护。 |

---

### P2-006 分类变更不会刷新搜索快照

| 项 | 内容 |
|---|---|
| 问题描述 | `SearchController` 常驻，只在 `dataEpochProvider` 变化时重建。`CategoryActions` 修改分类后只 invalidate 分类相关 provider，不 bump `dataEpochProvider`。 |
| 复现条件 | 1) 打开或初始化搜索；2) 到分类管理把分类 A 改名为 B；3) 回搜索页搜索 B；4) 搜索仍使用旧分类名快照，旧名称可命中，B 不命中；列表中该分类仍显示旧名。 |
| 影响范围 | 搜索结果分类名展示和按分类名搜索。金额、流水数据不丢，但用户看到过期信息。 |
| 相关文件 | `lib/features/search/application/search_controller.dart:47-81`；`lib/features/category/application/category_actions.dart:28-105`；`lib/core/providers/data_epoch.dart`。 |
| 根因 | “分类写操作”未被纳入 `dataEpochProvider` 的失效信号。 |
| 建议修复 | `CategoryActions._refresh()` 成功后同时 `ref.read(dataEpochProvider.notifier).bump()`；或让搜索额外 watch `categoriesProvider`。 |
| 建议测试 | 分类改名 / 新建 / 删除 / 迁移后，搜索 provider 快照和搜索结果使用最新分类数据。 |
| 优先级 | P2 |
| 证据与确认程度 | 代码证据明确；行为可从 Provider 依赖关系推导。 |

---

### P2-007 低风险删除与保存的 UI 异常处理不一致

| 项 | 内容 |
|---|---|
| 问题描述 | 手动保存、首页 / 日历 / 搜索单条删除直接 await Repository；数据库异常缺少统一用户反馈。导入、账户、预算、截图记账等入口已有 catch。 |
| 复现条件 | 删除或保存时数据库抛异常。 |
| 影响范围 | 用户体验和稳定性；不改变成功路径数据正确性。 |
| 相关文件 | `record_page.dart:178-236`；`home_page.dart:128-160`；`calendar_page.dart:130-163`；`search_overlay.dart:159-196`。 |
| 根因 | 多个 UI 入口没有统一包装写操作异常。 |
| 建议修复 | 建议为“写操作 + 统一反馈”建立轻量 wrapper，或在各入口补 catch，保证按钮状态恢复、页面不崩溃、用户可重试。 |
| 建议测试 | 模拟 `softDelete()` / `create()` / `update()` 抛异常，断言 UI 不 pop、不假成功、错误可读。 |
| 优先级 | P2 |
| 证据与确认程度 | 代码证据明确；真实数据库异常未复现。 |

---

### P3-001 长时间驻留后月份状态可能过期

| 项 | 内容 |
|---|---|
| 问题描述 | 首页 / 日历 / 统计 / 报表在 build 时读取 `DateTime.now()`，驻留跨天后不会自动切到新日期。 |
| 复现条件 | 昨晚打开首页，今天不杀 App 直接查看。 |
| 影响范围 | 页面显示的“当前月”可能与真实日期不一致；不影响数据库数据。 |
| 相关文件 | `ledger_controller.dart:47-56`；`calendar_controller.dart:144-163`；`stats_controller.dart:86-95`；`reports_controller.dart:132-150`。 |
| 建议方案 | 监听 lifecycle resumed 或系统日期变化，决定是否刷新当前月；或提供手动“回到本月”。 |
| 建议测试 | 注入可变 clock，模拟跨日 / 跨月。 |
| 优先级 | P3 |
| 证据与确认程度 | 代码证据明确；真实设备场景待验证。 |

---

### P3-002 Undo 反馈在页面销毁后的表现待验证

| 项 | 内容 |
|---|---|
| 问题描述 | 首页 / 日历 / 搜索 Undo 回调有 `context.mounted` / `mounted` 检查，但没有专项覆盖“SnackBar 未消失时页面销毁 / 路由切换后点撤销”。 |
| 复现条件 | 删除后 4 秒内快速切换页面或关闭搜索浮层，再点撤销。 |
| 影响范围 | 数据恢复大概率仍会执行；错误或成功反馈可能不可见。 |
| 相关文件 | `home_page.dart:141-159`；`calendar_page.dart:143-161`；`search_overlay.dart:171-195`。 |
| 建议方案 | Undo 回调通过 Provider / global messenger 展示反馈，避免依赖页面 context；补真实交互测试。 |
| 优先级 | P3 |
| 证据与确认程度 | 待验证。 |

---

### P3-003 账本管理缺少编辑 / 删除 UI

| 项 | 内容 |
|---|---|
| 问题描述 | `BookRepository` 支持更新和软删除，但页面只有新建 / 切换。用户无法改账本名或删除账本。 |
| 复现条件 | 进入账本管理页。 |
| 影响范围 | 产品能力不完整；不是数据错误。 |
| 相关文件 | `book_manage_page.dart:1-101`；`book_repository.dart:91-137`。 |
| 建议方案 | 若确认需要，补充长按或编辑入口；删除必须保留确认 Dialog，并处理 active book、关联数据与孤儿子数据策略。 |
| 优先级 | P3 |
| 证据与确认程度 | 代码证据明确。 |

---

### P3-004 `dataEpochProvider` 刷新约定不完整

| 项 | 内容 |
|---|---|
| 问题描述 | 手动保存仍逐个刷新首页 / 日历 / 统计；分类操作不 bump；资产 / 搜索 / 报表依赖 epoch。新增写入口容易漏刷新。 |
| 复现条件 | 新增一个写入口后忘记 bump 或手工刷新。 |
| 影响范围 | 架构维护风险，可能导致旧快照问题复发。 |
| 相关文件 | `record_page.dart:222-231`；`category_actions.dart:28-105`；`after_write.dart:24-47`。 |
| 建议方案 | 统一“成功写入 -> bump epoch -> 相关 Provider 自动刷新”的约定，逐步减少手工刷新。 |
| 优先级 | P3 |
| 证据与确认程度 | 架构观察明确。 |

---

### P3-005 自动记账入账成功与批次记录之间存在崩溃窗口

| 项 | 内容 |
|---|---|
| 问题描述 | 自动记账先通过 `importRows()` 写入流水，成功后才 `store.remember(batch)` 和展示回执。若中途崩溃，流水已入账但批次不可撤销、回执缺失。 |
| 复现条件 | 在 `importRows()` 成功后、`store.remember()` 前杀进程。 |
| 影响范围 | 自动记账撤销完整性；不造成重复入账，下次 drain 指纹会跳过。 |
| 相关文件 | `auto_book_controller.dart:207-277`；`auto_book_batches.dart:109-141`。 |
| 建议方案 | 评估把批次记录写入入账事务，或在 drain 开始时预写 pending 批次，入账成功后转为 done。 |
| 优先级 | P3 |
| 证据与确认程度 | 代码路径明确；未真实复现。 |

## 7. 推荐修复顺序

1. **修复外部交易指纹的账本作用域**  
   这是唯一 P1，直接影响多账本导入能力。先定义迁移策略，再补跨账本测试。

2. **补齐分类变更后的搜索新鲜度**  
   成本低、影响明确。优先给 `CategoryActions` 接入 `dataEpochProvider` 或让搜索 watch 分类 provider，并补回归测试。

3. **统一关键写操作的异常处理**  
   覆盖手动记账 / 编辑、低风险删除。目标是用户始终能理解失败、可重试，且页面不崩溃。

4. **原子化自动记账批量撤销**  
   用事务包裹软删与批次记录更新，避免部分撤销和二次撤销语义混乱。

5. **收敛账户身份与软删除策略**  
   先不要贸然加外键。明确导入 / 自动记账账户身份，以及账本 / 账户 / 分类软删后的数据展示与修复策略。

6. **补齐预算管理产品入口**  
   若产品确认需要历史 / 未来预算，增加月份选择；若不需要，更新文案与规格。

7. **补稳定测试与真实样本 fixture**  
   特别是跨账本指纹、分类改名搜索、自动记账中断、数据库异常、真实微信 / 支付宝账单。

## 8. 暂时不建议修改的模块

| 模块 | 原因 |
|---|---|
| Design System / Theme / Toon 组件 | 刚冻结并通过视觉验收；本轮问题不属于视觉问题。 |
| NavigationBar / FAB 布局 | 已有 Batch 1 修复和布局测试，未发现新功能正确性问题。 |
| Golden 基础设施 | 当前 52 张基线稳定；应只随功能修复补测试，不批量重构。 |
| 数据库迁移 | 除 P1 指纹作用域外，不要顺手调整 schema。P1 修复前先设计迁移和备份策略。 |
| 软删除架构 | 不应贸然改物理删除或加外键；先明确孤儿数据策略。 |
| 自动记账原生队列 / 补抓链路 | 已有真机事故回归测试；只应针对撤销原子性和批次窗口做小范围修复。 |
| 聊天问答 / OCR 解析 | 当前意图与样本测试较多；除非有真实失败样本，不建议本轮扩规则。 |

## 9. 下一阶段建议

1. **建立“数据修复优先”小批次**  
   第一个批次只修 P1 指纹作用域和 P2-006 分类搜索新鲜度，附带回归测试。

2. **建立“异常稳定性”小批次**  
   覆盖 P2-001、P2-002、P2-007，统一写操作错误反馈与按钮状态。

3. **建立“账户与删除一致性”设计决策**  
   先出小型 ADR，明确：账户业务身份、软删除级联、孤儿数据展示、是否需要诊断页。

4. **补高风险测试资产**  
   增加跨账本导入测试、分类改名搜索测试、自动记账撤销中断测试、数据库异常 UI 测试，并恢复缺失的真实账单 fixture。

5. **对真实设备做一轮数据走查**  
   重点验证：多账本导入、分类改名后搜索、自动记账跨启动撤销、删除 Undo、导入中断、1.3x 字体和跨日驻留。

## 10. 本轮未修改内容

本轮仅生成 `PRODUCT_QUALITY_AUDIT.md`。

未修改：

- 生产代码；
- 测试代码；
- Golden；
- 依赖；
- 数据库 schema；
- 配置；
- 文档中的既有状态记录。
