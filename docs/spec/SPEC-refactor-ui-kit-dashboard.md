# SPEC — UI Kit 收敛 + 首页模块化（P1/P2/P3）

> 目标：让新增页面/区块优先复用公共组件，并让首页由可排序、可隐藏的模块组成。
> P1 抽组件，P2 拆模块，P3 接用户配置（显示/隐藏 + 排序 + 持久化）。

## P1 — UI Kit（零视觉变化）

新增 `lib/ui_kit/`：

| 组件 | 用途 | 迁移 |
|---|---|---|
| `AppPageLoading` | 页面整块加载中 | 首页 / 统计 / 报表 / 账本 / 分类 / 抽屉 / 搜索 / 资产 / 导入 |
| `AppPageError` | 页面整块加载失败（文案口径保持 `加载失败：<error>`） | 同上（资产保留自己的错误卡） |
| `AppSheetHeader` | BottomSheet 抓手 + 标题 + 副标题 | 预算 / 账户表单 / 数据导出 |
| `AppSettingsTile` | 设置/我的页条目行 | 「我的」6 个入口 |

约束：

- 不改变现有间距、字号、颜色和业务回调；
- 业务专用组件（交易行、分类选择、金额键盘等）不强行上提；
- 后续要改错误文案，只改 `AppPageError` 一处。

## P2 — 首页 Dashboard 模块

新增 `lib/features/ledger/presentation/dashboard/`：

```text
dashboard_module.dart     DashboardModule 契约 + DashboardDeps
dashboard_config.dart     enabledIds（null = 全部启用）
dashboard_registry.dart   默认 5 个模块 + resolve/filter/sort
dashboard_view.dart       按注册表拼 CustomScrollView
modules/                  autobook / month_hero / budget / chat_entry / tx_list
```

默认顺序与当前首页一致：

| 模块 | order | spacingBefore |
|---|---:|---:|
| `autobook_banner` | 0 | 0 |
| `month_hero` | 10 | 0 |
| `budget_strip` | 20 | 24 |
| `chat_entry` | 30 | 20 |
| `tx_list` | 40 | 20（内部底部留 24） |

约束：

- 模块返回 sliver 列表；`DashboardView` 负责插间距；
- 模块只依赖 `DashboardDeps`（分类解析 / 编辑 / 删除 / 翻月），不 import `HomePage` 私有方法；
- `HomePage` 只保留 header、加载/错误态和删除恢复逻辑。

## P3 — 用户配置

- `dashboard_config_controller.dart`：读写 `schema_meta.dashboard_config`（JSON，零 schema 迁移）；
  - 读库失败 / 脏数据 → 回落默认全量；
  - 保存先更新 UI 再写库，写失败本次会话仍生效；
- `dashboard_layout_page.dart`：`ReorderableListView` 拖拽排序 + Switch 显示/隐藏 + 「恢复默认」；
- 入口：设置 → 首页 → 首页布局（`/dashboard-layout`）；
- 必选模块：`month_hero`、`tx_list`（`canHide = false`），开关锁定为开；
- `DashboardRegistry.sanitize` 丢弃未知 id、补齐缺失模块、强制必选模块启用。

## 非目标（P4+）

- 每个模块自己的参数（预算显示方式、图表类型、快捷操作）；
- 导航项顺序 / 自定义 tab；
- 云同步首页布局。

## 验证

- `dart analyze lib test`：0 issue（本机沙箱无法跑 Flutter 测试时以静态分析 + CI 为准）；
- 现有首页空态 / 删除 / 预算 / 账本切换用例保持通过；
- 新增 `dashboard_registry_test` 与 `ui_kit_test`。
