# HANDOFF — 小耄记账（Flutter）

本地优先的个人记账 App，目标平台 **Android**。本文件是**接手入口**：现状、硬约束、
去哪找细节。历史过程与完整参考都在 `docs/handoff/`，不必通读。

> 🤖 Agent/新人入口：[`AGENTS.md`](AGENTS.md)（指针文件，指向本文件与 docs 流程；
> 本文件仍是唯一规则承载处）。

## 现状

| 项 | 值 |
|---|---|
| 交付状态 | F1–F7.17 + **F8.1 阶段一「端上截图记账」全部交付**，最新 tag **`v0.8.3`**（2026-11-09 · A+B+C 数据一致性 + 三 ABI 包，[验收记录](docs/acceptance-v0.8.3.md)）。F8.1 真机走查 7 项全过（[验收报告](docs/acceptance-F8.1-receipt.md)）。**v0.8.2 = 改名「小耄记账」+ 橙底小猫图标首次进正式包**（同时收进 v0.8.1 之后一直未发版的 F7.18 分类树 / 预置二级 / 主题色 / 日历分段 / 问答聊天化）。阶段二：**任务 1 基准表已实测**（[报告](docs/dev/llm-benchmark.md)）+ **M1「问账本」+ 首页聊天化已交付并真机走查通过**（`/chat` 统一「记一笔 / 问一句」；`/assistant` 与 `/receipt` 已并入；MuMu + 真实微信账单 161 行） |
| 下一步 | ~~M2 本地模型~~ **⏸ 已搁置（2026-10-28 用户裁定）**。**v0.8.3 已发布（2026-11-09，三个 ABI 包）**。最近的待办：① **本地工作区还有 351 条未提交的 Design System v2 改动**（见下方「⚠️ 当前工作区」）② `docs/handoff/open-issues.md` 里 5 个 P3 未修 ③ 旧 Pages 地址 `…/yanxin-keeping/` 仍是 404（如需可建同名空仓库放跳转页）。更早的候选：分类 4 项遗留、导入规则扩容、FR-BUDGET-10 分类级预算、帧率采集 |
| 技术栈 | Flutter 3.47.2 / Dart 3.13.2 · drift 2.31.0 · Riverpod 3 · go_router 18 · **Material 3 主题（2026-10-28 换肤，seed = 森绿 `0xFF2E5E4E`，同日由琥珀改定）** · **ML Kit 文字识别（中文 bundled，离线）** · 本地 LLM 探针 = **llama.cpp `b7050`**（仅 `tool/llm_bench/`，**未进 App**） |
| 数据库 | schema **v5**（v2 加 `budgets`；v3 加 `accounts.icon/color`；v4 加 `categories.parent_id / is_archived`；**v5 把流水指纹唯一性从全局改为 `(book_id, fingerprint)`**，A1）。v4→v5 **只替换索引**，不重建表、不改既有行。**预置二级分类不需要迁移**（是数据不是结构） |
| 门禁 | 本地 = `flutter analyze` + `flutter test --concurrency=1`（**784 passed / 6 skipped**，HEAD `3b9f73f` 实测）；CI = `.github/workflows/ci.yml`，**四个并行 job**：① `analyze · 生成物同步` ② `test` ③ `build apk (debug)` ④ **`release · 插件与版本物检`**（release 构建后跑 `tool/release_preflight.py`，见下）。本机 `flutter analyze` 在这台 WSL 上会假死，用 `dart analyze lib test` 或 CI 代替；跑测试**必须** `--concurrency=1`（内存不足 OOM） |
| 仓库 | **GitHub `Xander-299/xiaomao-keeping`（public，2026-11-09 由 `yanxin-keeping` 改名）** · Pages <https://xander-299.github.io/xiaomao-keeping/> · 规则集 `check-ci`：required checks = `analyze · 生成物同步` / `test` / `build apk (debug)` / `release · 插件与版本物检`（最后一项需在 Settings 里手动勾），approvals 0，禁 force-push / 禁删默认分支（**直推 master 会被挡，必须走 PR**；管理员可 bypass） |

### 本轮交付（2026-11-09 · v0.8.3：A+B+C 数据一致性 + 发布闸门 + 三 ABI 包）

| 事项 | 结果 |
|---|---|
| A+B+C | A1 指纹按账本（schema v5）· A2 恢复前引用校验 · A3 批量撤销单事务 · B1/C1 日历竞态与 refresh 合并 · B2/C2 写失败统一反馈（**保留删除二次确认**）· P2-1 分类编辑原子性。PR #11 / #12 |
| 发布 | tag **`v0.8.3`** → `2f2c6d6`；Release 提供 **三个 ABI 包**：`arm64-v8a`（38.8 MB）/ `armeabi-v7a`（33.4 MB）/ `x86_64`（40.4 MB），同一 upload key；versionCode 因 `--split-per-abi` 为 4003 / 3003 / 6003 |
| 发布闸门 | 新增 `tool/release_preflight.py`（APK 内 `libsqlite3.so` / 插件清单 / 版本 / 签名）+ `install_device.ps1 -Smoke`（装完抓 `MissingPluginException` 与崩溃）+ CI job `release · 插件与版本物检`。PR #14 |
| 事故与修复 | v0.8.3 **首包全站白屏**：用 `--no-pub` 在无 `.flutter-plugins-dependencies` 的 worktree 里构建 → 插件注册表为空 → `sqlite3_flutter_libs` 未注册。重建后替换资产；复盘写进 [`docs/acceptance-v0.8.3.md`](docs/acceptance-v0.8.3.md) |
| 验收 | 真机（Redmi K50 / Android 14）：安装、冷启动、首页、记一笔、分类弹层、保存回显（¥12.34）、0 崩溃；**UI 文案靠 OCR 取证，逐 tab 断言与视觉细节未覆盖**；Golden 全程未验收 |
| 仓库 | 改名 `Xander-299/xiaomao-keeping`，Pages → <https://xander-299.github.io/xiaomao-keeping/>；README/网页下载入口改指 v0.8.3 三包 |
| 分支 | 已清理到只剩 `master`；仓库设置开启 **Automatically delete head branches** |

### 本轮交付（2026-11-09/10 · 组件化 P1–P4 合入 master，PR #19）

> 「组件可复用、页面可拼装、用户可自定义」地基已进 master。SPEC：
> [`docs/spec/SPEC-refactor-ui-kit-dashboard.md`](docs/spec/SPEC-refactor-ui-kit-dashboard.md)。

| 项 | 结果 |
|---|---|
| 合入 | PR **#19**（merge commit `62e01bb`），CI 四闸门全绿（analyze 1m52s / test 2m14s / build apk 2m37s / release preflight 3m34s），分支已删 |
| P1 UI Kit | `lib/ui_kit/`：`AppPageLoading` / `AppPageError` / `AppSheetHeader` / `AppSettingsTile`；9 处页面状态、3 个弹层头部、我的页 6 入口已迁移，零视觉变化 |
| P2 首页模块化 | `dashboard/` 注册表 + 5 个模块（autobook / month_hero / budget / chat_entry / tx_list），默认顺序/间距 = 旧首页 |
| P3 用户配置 | `schema_meta.dashboard_config`（JSON，零迁移）；设置 → 首页布局：开关 + 拖拽排序 + 恢复默认；`month_hero` / `tx_list` 必选 |
| P4 模块参数 | `DashboardParamSpec`（bool，缺键 = 默认值）；已落 `budget_strip.show_daily` / `chat_entry.show_samples`；**真机踩坑**：`sanitize()` 曾丢 `params` 导致参数写不进库，已修 + 回归测试 |
| 真机验证 | Redmi K50：隐藏预算/示例问题即时生效、重启持久化、恢复默认回归，全部通过 |
| P5 候选 | 非布尔参数（枚举/数值）、导航项自定义、云同步布局 |

### 本轮交付（2026-11-09 · P1 UI Kit + P2 首页模块化 + P3 用户配置 + P4 模块参数）

> 基于 `master` 新分支 `refactor/ui-kit-dashboard`：只抽公共组件与首页模块，不改业务数据流。
> SPEC：[`docs/spec/SPEC-refactor-ui-kit-dashboard.md`](docs/spec/SPEC-refactor-ui-kit-dashboard.md)。

| 事项 | 结果 |
|---|---|
| P1 UI Kit | 新增 `lib/ui_kit/`：`AppPageLoading` / `AppPageError`、`AppSheetHeader`、`AppSettingsTile`；迁移 9 处页面加载/错误态、3 个 BottomSheet 头部、我的页 6 个入口 |
| P2 首页模块 | 新增 `dashboard/{dashboard_module,dashboard_config,dashboard_registry,dashboard_view}.dart` + 5 个 modules；默认顺序/间距与旧首页一致 |
| P3 用户配置 | `DashboardConfigController` 读写 `schema_meta.dashboard_config`（JSON，零迁移）；设置 → 首页布局：开关 + 拖拽排序 + 恢复默认；`month_hero` / `tx_list` 必选 |
| P4 模块参数 | `DashboardParamSpec`（bool 开关，缺键 = 默认值，脏值回落）；已落 `budget_strip.show_daily` / `chat_entry.show_samples` 两个真实参数，随 JSON 持久化，设置页模块卡片内渲染 |
| 解耦 | 模块只依赖 `DashboardDeps`（分类解析 / 编辑 / 删除 / 翻月），`HomePage` 只保留 header、加载/错误态、删除恢复 |
| 视觉 | P1 零视觉变化（字号/间距/颜色沿用原值）；P2 首屏顺序与间距不变 |
| 测试 | 新增 `dashboard_registry_test`（含配置 JSON / sanitize / 排序）/ `ui_kit_test`；`dart analyze lib test` 0 issue；本机 Flutter 测试受沙箱写缓存限制未跑 |
| 未做 | P5：非布尔参数、导航项自定义、云同步 |

> ⚠️ **当前工作区**：本地分支 `docs/product-quality-audit @ 42f43c1`（远端分支已删）里还有 **351 条未提交改动**，
> 属 Design System v2 的剩余工作（`app_shell` FAB、页面级 `Tok` 令牌化、`toon/states.dart` 接入、DS 测试与 Golden）。
> 它**不属于** v0.8.3，也**没有**进 master；下一轮要么单独整理成 PR，要么继续搁置 —— 别当成「已交付」。

### 本轮交付（2026-10-30 · 发布 v0.8.2：新名 + 新图标真正进包）

| 事项 | 结果 |
|---|---|
| 版本号 | `pubspec.yaml` **0.8.1+2001 → 0.8.2+2002**（versionCode 只增不减）；「我的」页角标 `v0.8.2` 同步 |
| 构建 | **ASCII 副本法**：`robocopy` 到 `D:\yanxin-build`（排除 `build` / `.gradle-home` / `.git` / `__pycache__` / `*.log`）→ 副本内 `gradle.properties` 降 `-Xmx3G -XX:MaxMetaspaceSize=1G`（内存只剩 2.4 G）→ `JAVA_HOME=JDK17` + `GRADLE_USER_HOME=<repo>\.gradle-home` + 代理 → `flutter build apk --release --no-pub`。**187 s**，产物 **68,884,918 B（65.7 MB）** |
| 核验（4 条） | ① `aapt2 dump badging`：`versionCode='2002' versionName='0.8.2'`、`application-label:'小耄记账'`、ABI = arm64-v8a + armeabi-v7a；② 权限只剩 `POST_NOTIFICATIONS` / `RECEIVE_BOOT_COMPLETED`（+ 系统自加的 `DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION`），**无 `INTERNET`**；③ `apksigner` SHA-256 = `d46b65a4…e86567`（与 v0.7.16 起同一把钥匙）；④ 包内 `libapp.so` 含 `小耄记账` / `v0.8.2` / `截图记账`，`color/ic_launcher_background` = `#ffeb7118`、192 px 图标角落像素 = `(235,113,24)` |
| 文档 | CHANGELOG 新增 `[v0.8.2]` 段并把 6 段 `[Unreleased]` 收成 `[v0.8.2] 并入`；新增 [`docs/release-notes-v0.8.2.md`](docs/release-notes-v0.8.2.md)；README 下载区 / `docs/index.html` 链接与 tag 数（18 → 19）同步 |
| 发布 | tag `v0.8.2` + GitHub Release 资产 `yanxin-v0.8.2-universal-release.apk`（详见 release 页） |

> ⚠️ **包体 46 MB → 66 MB 不是回归，是 v0.8.1 那个「通用包」其实不通用**：把 v0.8.1 的资产下回来比过 ——
> 它有 `lib/armeabi-v7a/libmlkit_google_ocr_pipeline.so`，却**没有** `lib/armeabi-v7a/libflutter.so`
> 与 `lib/armeabi-v7a/libapp.so`（= 构建时带了 `--target-platform android-arm64`，只打进了 arm64 的
> Dart/引擎）。也就是说 v0.8.1 在 32 位 arm 机上是**装得上、起不来**。本次 `--release` 不带
> `--target-platform`、`abiFilters` 同时含 arm64-v8a + armeabi-v7a，两个 ABI 的引擎与 `libapp.so` 齐活，
> 所以是 66 MB 的**真通用包**。想回小包就用 `--split-per-abi`（或 `--target-platform android-arm64`，
> 体积更小，但 32 位 arm 机就装不了了）。
>
> ⚠️ **`tool/verify_apk_kernel.py` 只对 debug 包有效**（它读 `assets/flutter_assets/kernel_blob.bin`）；
> release 包是 AOT，核验要读 `lib/arm64-v8a/libapp.so`，且中文是 **UTF-16LE** 存的（按 UTF-8 搜会假阴性）。

### 本轮交付（2026-10-30 · 仓库迁移 + 改名换图标 + 安全收口）

> 仓库已从 `yanxin-flutter` 迁到 **`yanxin-keeping`**（public），旧库**已删除**；
> 迁移前做了一次 **git 历史重写**（旧 keystore 口令与本机路径全量替换），新库全历史 0 命中。

| 事项 | 结果 |
|---|---|
| 仓库迁移 | 新库 `Xander-299/yanxin-keeping`：master + 18 tags 全推；规则集 `check-ci` 重建；Pages 已开（Deploy from branch → `master` / `docs`）|
| 历史清理 | `git filter-repo`：`4076630.aa` → `***REMOVED***`、`C:\Users\<user>` → `<USER_HOME>`；新旧库全历史 0 命中；旧库连同其 `refs/pull/*` 一起删除 |
| keystore 口令 | **2026-10-29 轮换为 24 位随机值**（旧值作废、验证打不开）。值**不入库**，只在本机 `android/key.properties`（gitignored）。证书指纹未变（`d46b65a4…e86567`）→ 已发布包签名不受影响。旧 `.jks.bak` 与仓库外口令文件均已删除 |
| App 改名 | 「颜芯记账」→ **「小耄记账」**：manifest label（应用 + 自动记账服务）/ `MaterialApp.title` / 新手引导 / 我的页 / 通知文案 / 导出文件名前缀 / pubspec / README / 网页版。**Dart 包名 `yanxin` 不动** |
| 新图标 | 用户提供的橙底小猫图（`#EB7118`）：legacy 5 档 + adaptive 前景 5 档 + 网页 favicon。**没走** `gen_launcher_icons.py` 的抠底 —— 主体色距背景仅 84（阈值 100）会被抠穿，改用「整图缩进 66/108 安全区 + 底色同源」|
| 发布 | 新库已发 **v0.8.1**：`yanxin-v0.8.1-universal-release.apk`（46.44 MB，upload key 签名）；README 下载区指向它 |
| 未生效 | ⚠️ **已发布的 v0.8.1 包内仍是旧图标 + 旧名** —— 新图标/新名只在 `master` 源码与真机 QA 包里；要真正发出去需出 **v0.8.2** |

**下个 session 必读三条**：
1. `android/key.properties` 是**唯一**存签名口令的地方（仓库外的口令文件已按用户要求删除）；要出包先确认它在。
2. 构建一律 **JDK 17**（`D:\Download\Java\jdk-17.0.20.1+1`）；系统 `JAVA_HOME` 是 JDK 25。
   `tool/install_device.ps1` 与 `scripts/performance/Measure-ApkSize.ps1` 已内置「临时切 JDK17 + 还原」。
3. 直推 master 会被规则集挡（要 PR + 3 个 check）；force-push 只有管理员能 bypass。

### 本轮交付（2026-10-29 · 分类管理 UI 四轮迭代 + 预置二级）

> 全部落在**展示层 + 预置数据**：schema 仍 v4、仓储规则 / 归档·迁移·删除 / 写库路径一字未动。
> 详细对照与设备实测数字见 [`docs/spec/SPEC-F7.18-category-tree.md`](docs/spec/SPEC-F7.18-category-tree.md) §12–13。

| 批次 | 内容 | 关键文件 |
|---|---|---|
| ①② | 分类页改 Collapse + `Wrap` 块状二级 + 三点改 ActionSheet | `category_manage_page.dart` |
| ③ | 「添加」块常驻网格末尾（二级入口维持现状） | 同上 |
| ④ | 新建分类弹层 **30%**、图标选择另开 **60%** 弹层、右下角 **15%** 的 `FloatButton`（F/S 入口）、所有面板内容改 `Column` | `widgets/category_editor.dart`、`widgets/category_icon_sheet.dart`、`core/theme/toon/float_button.dart` |
| ⑤ | **预置二级分类**（支出 10 个一级 / 33 条二级）+ `ensurePresets` 两级匹配 + 问答按父级汇总 | `core/constants/preset.dart`、`data/repositories/{category,book}_repository.dart`、`features/assistant/application/finance_answer.dart` |
| ⑥ | **日历页**：分段加载（网格 → 当日账单 → 月标注）、不能翻未来月、翻月不改选中日 | `features/calendar/application/calendar_controller.dart`（`Notifier` 同步 state + 两段 `AsyncValue`）、`presentation/calendar_page.dart`、`month_picker_page.dart` |
| ⑦ | **主题色**（设置 → 主题色五选一：森绿 / 琥珀 / 黛蓝 / 藕粉 / 墨紫） | `core/theme/theme_seed.dart`（`ToonSeed`）、`palette.dart`（`lightOf/darkOf` 按 seed 缓存）、`settings/application/theme_controller.dart`（`theme_seed` KV）、`settings_page.dart` |
| ⑧ | **真机性能基准体系**（脚本 8 个 + 基线报告）：冷/热启动、PSS/CPU、APK 体积；帧率因 SurfaceView 统计不到记为「未测量」 | `scripts/performance/*.ps1`、`docs/perf/baseline-2026-10-29.md`（原始数据 `performance-results/` 已 gitignore） |

> ⑥ 的三个约束都是 2026-10-29 用户口头要求，已落到 PRD **FR-CAL-06/07/08**；
> 关键实现点：`CalendarState` 里「可见年月」与「选中日（完整日期）」是**两个独立字段**，
> 所以选中日可以不在可见月里（此时 `selectedDayInGrid` 返回 0 = 网格不高亮）。
> 翻月只重查整月聚合（`_loadMonth`），切日只重查那天（`_loadDay`）—— 两边互不牵连。

**装机/走查工具（本轮新增）**：`tool/install_device.ps1` —— 一条命令 = 临时改 gradle.properties
（内存 3G + 可选 `qaAppId`，**无论成败按字节还原**）→ `flutter build apk --{debug|release} --no-pub`
→ 核验（包名/版本码、release 比签名指纹、debug 用 `verify_apk_kernel.py` grep 新文案）→
`adb install`（debug 自动 `-t`，撞 `VERSION_DOWNGRADE` 自动补 `-d`）→ force-stop + monkey 启动。

```powershell
.\tool\install_device.ps1                                          # 模拟器
.\tool\install_device.ps1 -Serial 22041211AC -Qa -Grep 图标与颜色     # 真机走查
.\tool\install_device.ps1 -Serial 22041211AC -Mode release -Arm64Only # 真机正式包
```
⚠️ 这个 `.ps1` 也必须 **UTF-8 with BOM**（PS 5.1 会把无 BOM 的中文当 ANSI → 语法错）；
`write`/`edit` 改完记得补 BOM，再 `Parser::ParseFile` 验一遍语法。

**这次最容易被误判成「代码没生效」的两处**：

1. 加二级后，记账时点「餐饮」会**进子列表**而不是直接选中 —— 5 个老测试因此保存出没有分类的账单。
   已抽 `test/helpers/pick_category.dart`（点一级 → 自动补点「不细分」），新写用例请用它。
2. 30% 弹层在 800×600 测试视口里装不下全部字段：**第一行（名称）常驻，第二行要滚一点**，
   按钮钉底。别把「要滚」当成布局坏了。

#### 本轮遗留（4 条待拍板，都在 SPEC §13.5）
1. 一级有子分类后记账**多一次点击**（可选长按直接选一级来缓解）；
2. 预置没有 `preset_key` 列 → 用户把「早餐」改名成「早饭」后，补装会再插一条「早餐」（根治要 schema v5）；
3. 统计 / 报表按「父 · 子」**分开列**，与编辑层文案「二级计入父级统计」不一致（只有问答按父级汇总）；
4. 导入规则仍只落到一级（「地铁 / 公交」关键词 → 交通），要不要细到二级需用户确认。

> ⚠️ **本轮没有做真机走查**（用户 2026-10-29 明确要求先不做）。上面第 ④ 批的 30% / 60% / 15%
> 三个数字在 MuMu 上量过（见 SPEC §12.7），但**第 ⑤ 批（预置二级）只在单测里验证过**。
> 发包前建议补一次真机：新建账本看二级、老账本看补装、问一句「这个月餐饮花了多少」。

> 📱 **MuMu 现状（2026-10-29）**：`com.teacodeman.yanxin.qa` 是**本轮新装的 debug 包**
> （签名与旧 QA 包不同 → 装之前 `adb uninstall` 过一次，**旧 QA 数据已清空**）。
> 里面留了本轮走查的产物：一条自定义分类 `coffee`。`com.teacodeman.yanxin`（4001）没动。

### F8.1 收口快照（2026-10-24）

| 项 | 值 |
|---|---|
| 提交 / tag | `feac627` · **`v0.8.1`**（annotated）· **已推远端** `origin/master` + `origin v0.8.1` |
| 版本号 | `pubspec.yaml` = `0.8.1+2001`（versionCode 固定 2001，不随小版本递增）；README / RESUME / CHANGELOG 已对齐 |
| 手机上装了什么 | ① `com.teacodeman.yanxin` = **用户的正式包 v0.7.16，带真实账本，千万别卸**；② `com.teacodeman.yanxin.qa` = 走查用并列包（v0.8.1，**空账本 + 1 条 ¥22.98 测试记录**），随时可 `adb uninstall` |
| 真机 | Redmi K50 `22041211AC`（Android 14 / HyperOS），adb 可用；`input tap` 需在手机上开「USB 调试（安全设置）」 |
| 只差一项验收 | 支付失败截图的**真机**用例（单测已覆盖「按钮禁用 + 不写库」，缺真实失败截图样本） |

**阶段二（本地财务问答）的进度**（细节见 `docs/spec/SPEC-local-ai.md` §4 + §10）：

1. ✅ **§4.2 的「设备 × 模型」基准表已实测**：Redmi K50 上 3 个模型 × 10 轮，含冷加载 / 首 token /
   pp·tg tok/s / 峰值与逐轮 RSS / 温升。**报告 [`docs/dev/llm-benchmark.md`](docs/dev/llm-benchmark.md)**，
   复现入口 `tool/llm_bench/{build_android,run_bench}.ps1` + `bench_android.cpp`（探针源码在库，源码/产物在库外）。
   **一句话结论**：Qwen2.5-1.5B-Instruct Q4_K_M = **7.4 tok/s 生成 / 1.18 GB 常驻 / 10 轮不涨**，
   但 **首 token 3.5–5.1 s**（177 token 上下文）→ 上下文必须压到 ≤80 token，模型只做「措辞层」。
2. **候选推理方案**：llama.cpp 自建 JNI（推荐，掌控流式/取消/停止）vs MediaPipe `tasks-genai`
   （集成最快，但只支持 Gemma 系）—— 基准表已给出 Gemma-3-1B 的中文算数表现（会编数），**倾向 llama.cpp + Qwen2.5**。
3. **两条从实测得出的实现硬约束**：App 里 worker 线程必须**绑大核**（不绑 −27%，开 8 线程 −50%）、
   编译必须开 `-DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod`（首 token −45%），但后者**不支持 ≤A72 的老机**，
   真要兼容得走 `GGML_CPU_ALL_VARIANTS`。
4. 模型文件**不要打进 APK**；分发方式（手动导入 vs App 内下载=要加 `INTERNET`）属**产品决策**，
   2026-10-25 用户选择「**等基准表出来再定**」→ 目前 D4 仍未拍板，动它之前先问用户。

## 开始工作前

```bash
cp env.example.sh env.sh     # env.sh 不入库；按本机改路径或用环境变量覆盖
source env.sh
fx-qa                        # = flutter analyze && flutter test（去代理）
```

**本机路径（2026-10-24 实测，`env.sh` 里的 `$HOME/flutter` 在本机并不存在）**：

| 项 | 实际位置 |
|---|---|
| Flutter 3.47.2 / Dart 3.13.2 | `D:\Download\Flutter\flutter`（`bin\flutter.bat`） |
| JDK 17 | `D:\Download\Java\jdk-17.0.20.1+1`（**系统默认是 JDK 25，不能用**） |
| Android SDK | `D:\Download\Java\Android`（platform-tools / build-tools 36.0.0 / platforms 35-36） |
| adb | `D:\Download\Java\Android\platform-tools\adb.exe`（**注意**上表 SDK 与 `<用户目录>\AppData\Local\Android\Sdk` 都曾出现过，以能连上设备者为准） |

**门禁实测（2026-10-24）**：`flutter analyze` 直连可跑、`flutter test` 直连可跑（**必须加 `--concurrency=1`**，
本机内存紧时默认并发会让 Dart VM `Out of memory` 崩）。`tool/dart_*_fallback.py` 那套 231 变通本轮没用到。

依赖版本**锁死，不要随手升**：`drift 2.31.0` / `sqlite3 2.9.4` / `build_runner 2.15.1` /
**`jni_flutter 1.0.1`**（见下「最容易踩的坑」，升了 App 直接起不来）。
`sqlite3 3.x` 起带 native-assets 构建钩子（Windows 上需要 MSVC）；
`build_runner 2.16+` 要求 analyzer ≥13 与 `drift_dev` 冲突。

改了 `lib/core/db/tables.dart` 必须重跑 `dart run build_runner build --delete-conflicting-outputs`
并提交 `database.g.dart` —— CI 有一条硬检查会因此失败。

**出 APK**：本仓库在**中文路径**下，AGP 会拒绝构建（`Your project path contains non-ASCII characters`）。
前置一步写在**不入库**的 `$GRADLE_USER_HOME/gradle.properties`（本仓库 `GRADLE_USER_HOME=.gradle-home`）：

```
android.overridePathCheck=true
```

然后 `flutter build apk --release --no-pub`（实测 80–110 s 增量；`--no-pub` 很重要，见下「坑」）。
装机后**必跑** `python tool/verify_apk_kernel.py <本次新增字符串>` 核验包是新码。

⚠️ **本机内存不足时 Gradle 会崩**（`hs_err_pid*.log` 里 `Chunk::new`/malloc 失败）：构建前把
`android/gradle.properties` 的 `-Xmx8G -XX:MaxMetaspaceSize=4G` **临时**降到 `-Xmx3G -XX:MaxMetaspaceSize=1G`，
构建完**按字节还原**（`git diff android/gradle.properties` 必须为空）。

⚠️ **debug 包可以出、但真机启动要留意**：`flutter build apk --debug` 正常；装到手机上请用 QA 包名
（见下「真机装包别覆盖用户的正式包」）。

## 必须守住的不变量

这几条每条都有回归测试兜着，改动前先看测试为什么这么写：

1. **drift 是唯一 DB writer** —— Kotlin 侧只落盘 JSONL，不碰数据库。
   **F8.1 起同样适用截图记账**：原生只回「文字行 + 坐标」，解析是 Dart 纯函数，
   写库统一走 `TransactionRepository.importTransaction(source:'screenshot', externalId: 文本指纹)`；
   **OCR / 解析层永远不碰 DB**，也不许新增第二条写库路径。
2. **常驻 provider 要 `ref.watch(dataEpochProvider)`** —— 否则「刚记一笔后搜索搜不到」
   这类过期快照 bug 会回来（`test/features/search/search_freshness_test.dart`）。
3. **纯函数优先** —— 解析、金额、命中口径、聚合统计都是无副作用纯函数，`test()` 直接覆盖。
4. **金额一律 `int` 分**，禁止浮点。
5. **go_router 实例放在 App State**，不能是顶层 `final`；且 `context.push().then`
   在 `StatefulShellRoute` 壳下**不兑现** → 保存后刷新由被推页面自己在 pop 前做。
6. **色值一律走调色板 `context.toon`（`p.xxx`）** —— 2026-10-28 起色板是 **Material 3**：
   `ToonPalette.light/dark` 由 `ColorScheme.fromSeed(ToonPalette.seed)` 派生，**改品牌色只改 `seed` 一处**。
   组件库（`ToonCard` / `ToonButton` / …）名字保留、内部是 M3（Card / FilledButton / SegmentedButton / ripple），
   所以**换皮肤不改业务页面**；新增 UI 请继续用 `Toon*`，别直接 `Card`/`FilledButton` 各写一套。。产品代码里不出现裸 `Color(0x…)`。
   F7.17 起 `Tok` **只剩几何量**（描边宽 / 圆角）；颜色是 `ThemeExtension<ToonPalette>` 的
   **实例字段**，靠 `Theme.of` 建立依赖 —— 这样才能随浅/深主题切换重建。
   **别把颜色改回 `const`**：`const` widget 会被 Element 判 `identical` 跳过重建，切主题不刷新。
7. **对比度规则（2026-10-28 换 M3 后重写，护栏 `test/core/theme/palette_contrast_test.dart`）**
   - 色板是 M3 角色映射，**前景必须配对自己的底**：`onBrand`(onPrimary)→`brand`(primary)、
     `brandInk`(onPrimaryContainer)→`brandTint`(primaryContainer)、`onRed`(onError)→`red`(error)、
     `redInk`(onErrorContainer)→`redTint`(errorContainer)。配错在浅色下看不出来、深色下直接看不见。
   - **hero 用 `brandTint` 底 + `heroInk`（= onPrimaryContainer）字**：hero 是品牌展示面，
     用 primaryContainer 才有「品牌浅底的呼吸感」；用 `brand`(primary) 会变成深色重块。
   - 门槛：正文小字 **4.5:1**、描边/图形 **3.0:1**、发丝分割线只要可见（**1.4:1**）。
   - 改 `ToonPalette.seed` 或改映射后，**必须跑这条护栏**（它会把每一项的实际比值打进失败信息）。
8. **正式包不得出现 `INTERNET`（F8.1 起新增，实测踩到过）** —— ML Kit 的依赖链
   （`com.google.android.datatransport:transport-backend-cct`）**会自己合并进 `INTERNET` +
   `ACCESS_NETWORK_STATE`**，所以 `android/app/src/release/AndroidManifest.xml` 里用
   `tools:node="remove"` 把它们删掉。**以后任何「加个 Google/ML 库」的改动，改完必须重核**：
   `./gradlew :app:processReleaseMainManifest` → 看
   `build/app/intermediates/merged_manifest/release/.../AndroidManifest.xml` 是否只剩
   `POST_NOTIFICATIONS` / `RECEIVE_BOOT_COMPLETED`。
   ⚠️ **不要在 `src/main/` 里删**：debug 包需要 `INTERNET` 跑热重载（VM service 走 TCP）。
9. **写后刷新只有一处实现**（F8.1 收口）：`lib/core/providers/after_write.dart`，
   `Ref` 与 `WidgetRef` 两个入口。**别再复制那五行** —— 三处复制就会漏一处（HANDOFF 不变量 #2 的成因）。
10. **分类的两个读取口径不能混**（F7.18 起新增）：`categoriesProvider` **含归档**
    （历史账单 / 统计 / 报表 / 搜索解析名字用）；`categoriesByKindProvider` **排除归档**
    （记账选择器 / 导入映射用）。归档分类从「可用列表」消失但绝不能从「名字解析」里消失，
    否则历史账单会显示成「未分类」。另：`ensurePresets()` **连软删行一起查** ——
    用户删掉的预置分类不能被补装复活（真机踩过，回归测试在）。
    **2026-10-29 起补装分两级匹配**：一级只在 `parent_id IS NULL` 的行里比对；二级只在
    **同一个父级**下比对（全局 `kind|name` 集合会串味：一级「红包礼金」的别名就是二级「红包」）。
    **父级被软删 → 整棵树都不补**；预置写入只剩 `ensurePresets()` 一处（`BookRepository.create`
    也调它），别再往新建账本里手写一份预置循环。

## 最容易踩的坑（完整清单见 [`docs/handoff/pitfalls.md`](docs/handoff/pitfalls.md)）

- `flutter test` 必须**去代理**（`http_proxy` 会劫持 flutter_tester 的本地 WebSocket）；
  `flutter build` 相反要走镜像。
- **`flutter build` 会隐式跑 `pub get`，把 `pubspec.lock` 里的 transitive 版本升上去**
  （实测一次 `flutter build apk` 就把 `pubspec.lock` 改了 157 行、4 个包升版本，还顺手把
  registry 从 `pub.flutter-io.cn` 改成 `pub.dev`）。提交前**必看 `git diff pubspec.lock`**；
  变了就 `git checkout -- pubspec.lock` → `flutter pub get`（带 `PUB_HOSTED_URL` 镜像）→
  确认 diff 为空，再用 `flutter build apk --no-pub` 重出包。依赖是**锁死**的，别顺手提交。
- widget 测试里写库是真实异步，`pumpAndSettle` 会早退 → 用轮询等待；
  800×600 视口很矮，断言长页面靠下的元素前先滚动。
- 改了 UI 入口后，**全仓无上限地** grep 旧断言（`保存` / `ensureVisible` /
  `widgetWithText(AppBar`）—— 曾因 grep 加了上限而漏掉一个文件，用户终端直接挂。
- **一级分类有子分类后，`tap(一级名)` 是「进子列表」不是「选中」**（2026-10-29 踩到，一次挂了 5 个测试）：
  widget 测试里选分类一律用 `test/helpers/pick_category.dart` 的 `pickCategory(tester, '餐饮')`，
  它会自动补点「餐饮（不细分）」；要断言真正落到二级就用 `pickSubCategory(tester, '餐饮', '早餐')`。
- **改预置分类清单要先想「补装会不会重复插」**：`ensurePresets` 只按「名字 / 别名」认领，
  用户改过名的那条认不出来 → 会再插一条原名（预置没有 `preset_key` 列）。给新预置起名时，
  别名表要覆盖老叫法。
- 真机走查见 [`docs/dev/android-ui-smoke.md`](docs/dev/android-ui-smoke.md)：
  语义树是「有没有 / 在哪」的真值，截图才是「颜色 / 遮挡」的真值，**两者交叉验证**。
- **出 release 包必须走 ASCII 副本**：项目在中文路径下，`gen_snapshot` 会因路径含非 ASCII
  直接挂（报 `Unable to read file: …\.dart_tool\flu`）。做法是 robocopy 到 `D:\yanxin-build`
  （排除 `build` / `.gradle-home` / `.git`）+ 带上仓库的 `pubspec.lock` 与 `.dart_tool` +
  `--no-pub` 构建。keystore 口令、核验三步、发布命令见
  [`docs/dev/release-v0.7.17.md`](docs/dev/release-v0.7.17.md)。
- **换签名 = 用户必须卸载重装 = 丢本地账本**：release 签名只用
  `<用户目录>\upload-keystore.jks`（`CN=yanxin`），**不是** `~/.android/debug.keystore`。
  ⚠️ **口令 2026-10-29 已轮换为随机值**（旧口令作废）：值**不入库**，只在本机 `android/key.properties`
  与仓库外 `upload-keystore-password.txt`；证书指纹未变，已发布包签名不受影响。
  装机前先 `apksigner verify --print-certs` 比对指纹。
- **本机内存余量不足时 Gradle 守护进程会崩**（F8.1 实测两次）：`hs_err_pid*.log` 里是
  `Chunk::new` / `malloc` 失败，而系统 commit 只剩 ~0.9 GB。临时处理：把
  `android/gradle.properties` 的 `-Xmx8G -XX:MaxMetaspaceSize=4G` 降到 `-Xmx3G`，
  构建完**按字节还原**（`git diff android/gradle.properties` 必须为空）。
  `flutter test` 全量在内存紧张时也会 `Out of memory` 崩 → 用 `--concurrency=1`。
- **`flutter build` 目前直接可用**（2026-10-24 实测 `flutter build apk --debug --no-pub` 成功，
  442 s）；`tool/dart_*_fallback.py` 那套 231 变通本轮**没有用到**（analyze / test 直连也都能跑）。
- **⚠️ `jni_flutter 1.0.3` 会让 App 启动即崩（2026-10-24 真机定位，已 pin 回 1.0.1）**：
  现象是 `Fatal signal 11` + `Abort message: 'JNI is not initialized … before main()'`，
  **debug / release 都崩，未改动的 HEAD 也崩**。来源是 `path_provider_android 2.3.1`
  （已改用 jnigen）带进来的 `jni / jni_flutter`。修法 = `pubspec.yaml` 的 `dependency_overrides`
  锁 `jni_flutter: 1.0.1`。**别顺手升它**（升了就得重新真机验证启动）。
- **⚠️ release 包必须关 R8，否则 ML Kit 端上识别必崩（2026-10-24 真机定位）**：
  现象是选图成功、OCR 抛 `NullPointerException: … Object.getClass() on a null object reference`
  （栈里是 `r51/b61/rg0` 这类 ML Kit 混淆内部类）。**同一张图 debug 包正常、release 包必崩**。
  `android/app/build.gradle.kts` 的 `release` 里已显式 `isMinifyEnabled = false; isShrinkResources = false`
  （APK 61.6 → 64.6 MB）。要瘦身请加 ML Kit keep 规则后**重新真机验证**，别直接开回来。
- **选图不要用 `file_picker`**（F8.1 实测：release 包里点「选图 / 选文件」直接返回 null，系统 Activity 都不起）。
  截图记账已改用自家通道 `yanxin/ocr` 的 `pickImage`（Android 13+ Photo Picker，老系统 SAF 兜底）；
  「导入账单」页仍是 `file_picker` → **存量问题，待单独处理**。
- **真机装包别覆盖用户的正式包**：走查机上的 `com.teacodeman.yanxin` 带真实账本，
  且 versionCode 4001 > 仓库的 2001、签名不同 → `adb install -r` 只会失败或逼你卸载（=丢账本）。
  用 QA 包名并列安装：`android/gradle.properties` 临时写 `qaAppId=com.teacodeman.yanxin.qa`
  再 `flutter build apk --release --no-pub`，装完 `adb uninstall` 清掉。
- **模拟器走查（2026-10-27 实测，MuMu 12 / Android 12）——四个坑**：
  ① `uiautomator dump` 会偶发返回 `null root node`，**千万别读上一轮的 `/sdcard/ui.xml` 当现状**
     （本轮真踩到：误以为改了代码没生效）。用 `tool/ui_mumu.ps1`，它会「删旧 → dump → 校验非空 → 重试 3 次 → 失败抛错」；
  ② Flutter 里**一个可点按钮常被合并成整张卡片**的语义节点（例：导入页「选择文件」的节点是 [0,244]-[900,722]），
     点卡片中心没反应 —— 要沿 y 扫一遍找真命中点（本轮实测 y≈600 才中）；
  ③ `adb shell input text` **打不了中文**（只能 ASCII）→ 想测「问账本」这类中文输入，
     要么点页面上的示例 chip，要么用 root 把模拟器时间改到目标月份（`date MMDDhhmmYYYY.ss`，测完记得改回来）；
  ④ MuMu 的 adb 端口是 `127.0.0.1:16384`（`adb connect` 后 `adb devices` 会列出多个 transport，留一个即可）。
- **MIUI 上 `adb shell input tap` 会打偏**：uiautomator 给的语义节点常是**整张卡片**，
  按它的中心点可能落在按钮外 —— 在目标区域扫一遍 y（如 640–780）才稳；
  手机被人同时使用时，事件会落到别人的 App 上；`input` 被 `INJECT_EVENTS` 拦时需开「USB 调试（安全设置）」。
- **不走 UI 的排查手段**：`tool/ocr_probe_main.dart`（`flutter build apk -t tool/ocr_probe_main.dart`）
  启动即对一张固定路径的图跑 OCR + 解析并打日志 —— 用于区分「OCR/解析坏了」还是「UI/构建坏了」。
- **release 包体积/ABI（F8.1 实测）**：64.6 MB（关 R8），ABI = `arm64-v8a` + `armeabi-v7a`；
  ML Kit 占 `libmlkit_google_ocr_pipeline.so` 10.5 MB(arm64) + 6.5 MB(v7a) + 模型 2.4 MB。
  `defaultConfig.ndk.abiFilters` 只放 ARM，**debug 里额外 `add("x86_64")`** 给模拟器 ——
  ⚠️ AGP 的 `abiFilters` 在 buildType 层是**并集**，不是覆盖（实测过）。
- **端上基准（阶段二任务 1）踩到的五个坑**（复现细节见 [`docs/dev/llm-benchmark.md`](docs/dev/llm-benchmark.md) §6–7）：
  ① **HyperOS 屏蔽 thermal zone**：`/sys/class/thermal/**` 对 shell 是 `Permission denied`，
     温度只能 `dumpsys battery`（电池温度，滞后，别当 SoC 温度用）；
  ② **toybox 的 `taskset` 没有 `-c`**：只吃十六进制掩码 → `taskset f0 ./bin`（cpu4–7 大核）；
  ③ **本机只有 Windows PowerShell 5.1（无 `pwsh`）**：`.ps1` 必须 **UTF-8 with BOM**；
     `$ErrorActionPreference='Stop'` 会被 cmake/adb 的正常 stderr 打断；
     `adb shell "... 2>/dev/null"` 里的 `2>` 会被 PowerShell 当自己的重定向（报 `D:\dev\null` 不存在）；
  ④ **NDK 的 `clang++.cmd` 会丢 `-L<dir> -lxxx`**（`ld.lld: unable to find library -llama`，文件明明在）→
     改成把 `.so` 全路径传给编译器；
  ⑤ **llama.cpp 必须在库外编**（`D:\yanxin-llm-bench`）：仓库在中文路径下，且源码+产物 1–2 GB 不该进库。
- **切换视图时别把 state 切成 `AsyncLoading`**（2026-10-28，用户报「日历翻月很生硬」）：
  `AsyncNotifierProvider` 每次重查都 `state = AsyncLoading()` 的话，页面 `when(loading:)` 会
  闪一整屏转圈再瞬切内容。正确做法是**保留旧数据、拿到新数据再一次性替换**
  （`calendar_controller._reload`），过渡动画交给页面（`AnimatedSwitcher` + `SlideTransition`）。
- **`ref.read(FutureProvider).value` 首次是 null**（2026-10-28 踩到）：聊天页发图时用
  `ref.read(categoriesProvider).value ?? []` 取分类，结果永远是空 → 待确认卡显示「请选择分类」、
  点确认永远失败。**要 `await ref.read(provider.future)`**。同类写法在别处也要查一遍。
- **性能两条（同一台 K50 实测，别在 App 里忘了）**：worker 线程**绑大核**（不绑 −27%，开 8 线程 −50%）；
  编 ggml 开 `-DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod`（首 token −45%，但只影响预填不影响生成）。

## 目录导航

```
lib/
├── app.dart                 路由表（go_router：壳路由 + 全屏页）
├── main.dart                入口
├── core/                    基础设施（不依赖任何 feature / data）
│   ├── db/                  drift：tables / database / schema_v1 / schema_v2 / schema_v4（v4 = 分类两级+归档）
│   ├── providers/           data_epoch（写操作后的统一失效信号）+ after_write（写后刷新的唯一实现）
│   ├── theme/               palette.dart（调色板 · 浅/深两套）+ theme_mode.dart（外观三选一）
│   │                        + tokens.dart（几何量 + buildToonTheme）+ toon.dart（通用件；
│   │                          含 float_button.dart = `ToonFloatMenu`，Ant Design FloatButton 语义）
│   ├── utils/               money / id / fingerprint / date / highlight
│   └── constants/           preset.dart（PresetCategory + PresetChild 预置两级分类）
│                            + category_icons.dart（图标 key / 颜色目录，44 个 key）
├── data/
│   ├── providers/           数据层 DI：database + book / account / category 等
│   └── repositories/        6 个仓储
├── features/                按业务垂直切分：application（逻辑）+ presentation（UI）
│   └── category/            F7.18 分类树（application/category_actions + presentation 管理页/编辑弹层 30%/图标弹层 60%/浮动入口）
└── （其余 feature 同构：chat / ledger / record / calendar / stats / reports / search / import / receipt / autobook / assets / book / profile …）
```

- **F8.1 新增**：`lib/features/receipt/`（`data/{ocr_engine,mlkit_ocr_engine,receipt_rules,receipt_parse}`
  + `application/{receipt_draft,receipt_write}` + `presentation/receipt_page` & `widgets/receipt_bits`），
  `lib/core/platform/media_picker.dart`（选图/选文件，截图记账与导入页共用），
  原生侧 `android/app/src/main/kotlin/com/teacodeman/yanxin/ocr/OcrChannel.kt`（通道 `yanxin/ocr`：
  `recognize` / `pickImage` / `pickDocument` / `release`），`android/app/src/release/AndroidManifest.xml`（剔除 INTERNET），
  入口「我的 → 截图记账」（路由 `/receipt`）。
  诊断工具 `tool/ocr_probe_main.dart`（`flutter build apk -t tool/ocr_probe_main.dart` 后启动即跑一遍
  OCR + 解析并打日志，用于**区分**「OCR/解析坏了」还是「UI/构建坏了」）。

- **首页聊天化新增**（2026-10-28）：`lib/features/chat/`（`application/{answer_question,chat_controller}`
  + `presentation/chat_page` + `presentation/widgets/{chat_bubbles,receipt_card,chat_entry_card}`）+
  `ledger/presentation/widgets/budget_strip.dart`。首页顺序 = `hero → 预算一行 → 记一笔/问一句入口卡 → 本月账单`；
  聊天页 `/chat` 同时处理**文字问账本**与**图片记账**（OCR → 待确认卡 → 确认才写库）。
  ⚠️ 旧的 `assistant_page` / `assistant_controller` / `receipt_page` / `receipt_bits` / `budget_card` **已删除**，
  但 `features/receipt/{data,application}`（OCR、解析、写库）与 `finance_intent`/`finance_answer` 纯函数**全部保留**。

- **阶段二 M1 新增**（2026-10-27，**产品代码，只读不写库**）：`lib/features/assistant/`
  （`application/{finance_intent,finance_answer,assistant_controller}` + `presentation/assistant_page`），
  入口「我的 → 问账本」（路由 `/assistant`）。链路 =
  `parseFinanceIntent`（纯函数选区间与口径）→ `listByRange` / `getForMonth` →
  既有口径纯函数（`summarize` / `categoryBreakdown` / `buildBudgetView`）→ 模板回答。
  **没有模型、没有网络、没有新依赖**；不认识的问题回示例，绝不编数字。
  ⚠️ 新增/修改意图词表后，先跑 `test/features/assistant/`（46 例）再动 UI。

- **阶段二任务 1 新增**（2026-10-25，**只加工具与文档，零产品代码**）：
  `tool/llm_bench/bench_android.cpp`（端上探针：冷加载 / 首 token / pp·tg tok/s / 逐轮 RSS / 频率，
  `KEY=value` 行输出）+ `tool/llm_bench/build_android.ps1`（NDK 交叉编译 llama.cpp + 探针）+
  `tool/llm_bench/run_bench.ps1`（推模型 → 跑 → 主机侧采温度/频率 → 直接吐一行 markdown）+
  `tool/llm_bench/prompts_finance.txt`（8 段中文财报问答，逐轮轮换）。
  **源码与产物都在库外** `D:\yanxin-llm-bench`（llama.cpp 克隆 + 3 个 gguf）；仓库里只有探针源码与脚本。
  ⚠️ 两个 `.ps1` 必须存成 **UTF-8 with BOM**（Windows PowerShell 5.1 会把无 BOM 的 UTF-8 当 ANSI，
  中文注释直接语法错；`write`/`edit` 工具写文件会丢 BOM，改完记得补）。

- 纯 UI 的 feature（`book` `category` `profile` `nav`）只有 `presentation/`，
  数据与状态在 `lib/data/providers/` 或对应 controller 里 —— 这是有意的例外，不是漏了。
- `docs/` 下：`spec/` 签字的 SPEC、`dev/` 开发运维手册、`acceptance-*.md` 走查报告、
  `handoff/` 交接档案。

## 档案索引

| 文档 | 内容 |
|---|---|
| [`docs/spec/SPEC-local-assistant.md`](docs/spec/SPEC-local-assistant.md) | **阶段二 · 本地财务问答（已签字）**：三层架构（T0 无模型 / T1 可选模型 / T2 云端不做）、为什么先做 M1、M1 文件级交付、口径表、验收 8 条、已知限制、M2 计划 |
| [`docs/dev/llm-benchmark.md`](docs/dev/llm-benchmark.md) | **阶段二任务 1 基准报告**：设备/构建/口径、3 模型 × 10 轮实测表、dotprod 与线程亲和性对比、质量抽查、已知限制、复现命令 |
| [`docs/spec/SPEC-local-ai.md`](docs/spec/SPEC-local-ai.md) | **F8 本地 AI 路线的总 SPEC**：阶段零架构分析 + 阶段一文件级计划 + **§9 实施记录**（交付清单 / 偏差 / 门禁 / 真机阻塞排查 / 已知限制）+ **§10 阶段二任务 1 记录** |
| [`docs/spec/SPEC-F7.18-category-tree.md`](docs/spec/SPEC-F7.18-category-tree.md) | **F7.18 分类树（已实现，事后补档）**：schema v4（parent_id / is_archived）、任务书需求对照表（原文已存档 `docs/spec/prompts/`）、关键决策（老名字别名映射 / 上移下移排序）、5 条偏差、测试与真机证据索引；**§12 是 2026-10-29 的四轮交互迭代**（Collapse / 块状二级 / 30%-60% 弹层 / 浮动入口 / 设备实测数字）、**§13 是预置二级分类**（清单、补装规则、问答 bug、4 条待拍板） |
| [`docs/acceptance-F7.18-category-tree.md`](docs/acceptance-F7.18-category-tree.md) | **F7.18 真机验收**：v3→v4 迁移 154 笔零丢失、管理页 8 步链路、迁移删除（7 笔购物→其他，总额不变）、ensurePresets 复活 bug 的发现与复测 || [`docs/acceptance-F8.1-receipt.md`](docs/acceptance-F8.1-receipt.md) | **F8.1 真机验收报告**：7 项走查结果、3 个阻塞的根因与修法、复现命令 |
| [`docs/handoff/reference.md`](docs/handoff/reference.md) | **开工前读**：环境事实 / 架构决策 / 关键资料 / 接手指南 |
| [`docs/handoff/pitfalls.md`](docs/handoff/pitfalls.md) | 盲区防护清单：踩过的坑与判据 |
| [`docs/handoff/open-issues.md`](docs/handoff/open-issues.md) | 未解决问题、待确认事项 |
| [`docs/handoff/history.md`](docs/handoff/history.md) | 已完成的工作、已尝试但放弃的方案（**别重复做**） |
| [`docs/handoff/status-log.md`](docs/handoff/status-log.md) | 逐版本状态流水 + 极简版摘要（历史，不是现状） |
| [`docs/handoff/session-log.md`](docs/handoff/session-log.md) | 逐轮会话记录（根因、取证、验证过程） |
| [`CHANGELOG.md`](CHANGELOG.md) | 版本变更 + tag 表 |
| [`docs/RESUME.md`](docs/RESUME.md) | 简历用项目介绍（规模 / 难点 / 迭代记录） |
| [`docs/spec/`](docs/spec/) | 各阶段签字的 SPEC |
| [`docs/spec/prompts/`](docs/spec/prompts/) | **需求原文存档区**（按日期命名）。⚠️ 根目录 `Prompt.md` 只是**临时提示词暂存位**，会被下一次任务覆盖；SPEC 引用的任务书必须先存档到这里 |
| [`docs/dev/`](docs/dev/) | 真机走查、Windows 环境重建 |
| [`docs/dev/release-v0.7.17.md`](docs/dev/release-v0.7.17.md) | **出 release 包 + 发布**：keystore / 口令 / ASCII 副本构建法 / 核验三步 |
| [`tasks/todo-flutter.md`](tasks/todo-flutter.md) | 迁移任务清单 |
