# 盲区防护与易错避坑（针对缺失信息自查）

1. **开终端先 `source env.sh`**（含 PATH 兜底 / 机器识别 / JDK17 / `GRADLE_USER_HOME` / 代理 / unset 会话 ID）
2. **Bash 工具默认 PATH 缺 `/usr/bin:/bin`**：不补则 `grep/head/tail/date/find/dirname` 全「command not found」，`flutter` 还会误报 `PROGRAM BLOCKED BY SECURITY POLICY ... wsl.exe`（**同一根因，别去改用 flutter.bat**）
3. **沙箱里 `env` 命令返回空**：`env -u ... cmd` 写法静默失效 → 用 bash `unset` 或子 shell
4. **`flutter test` 必须去代理**（http_proxy 劫持 flutter_tester 本地 WebSocket）；**`flutter build` 相反需要代理/镜像**
5. **不 `source env.sh` 就跑 `pub get` 会污染 `pubspec.lock`**：113 个包的 `url` 会从 `pub.flutter-io.cn` 被改写成 `pub.dev`
6. **Gradle 缓存绝不复制**（复制 → 挂死，伪装成网络慢）
7. **本地 `refs/remotes` 偶发写不进**：`git status -sb` 的 `[gone]` / behind 不可全信，用 `git ls-remote origin master` 核对
8. **换机器后 `git pull` 是第一步**：本机曾在 F7.1 停了一周才同步（差 13 个提交）
9. **版本号别凭记忆升**：锁死矩阵见「已确认事实」
10. **drift 与 matcher 都导出顶层 `isNull`** → 测试里 `import 'package:drift/drift.dart' hide isNull;`
11. **改 `lib/core/db/tables.dart` 必须重跑 `dart run build_runner build`**，`database.g.dart` 一并提交
12. Riverpod 3：未公开导出 `Override` 类型；`AsyncValue.valueOrNull` 已移除 → 用 `.value`
13. **Riverpod 3.4.3 没有可用的 `AsyncNotifierProvider.family` 取参入口**（`FamilyAsyncNotifier` 已移除）→ 需要「按参数取数」时改成 **watch 已有状态**（如 `monthBudgetProvider` watch `ledgerProvider`）
14. **go_router 实例不能是顶层 `final`**；且 `context.push().then` 在 `StatefulShellRoute` 壳下**不兑现** → 保存后刷新由被推页面在 pop 前自己做
15. widget 测试：写库是真实异步，`pumpAndSettle` 会早退 → 用 `pumpUntil(finder)` 轮询；视口 800×600 小，tap 前 `ensureVisible`
16. `expect(repo.create(...), throwsA(...))` 同步抛错要先执行 → 写 `expect(() => repo.create(...), throwsA(...))`
17. drift companion：非空无默认列传**裸值**，其余 `Value(x)`；可选更新 `const Value.absent()`
18. `gbk_codec` 解码非法序列**静默不产 U+FFFD** → 判坏件用「重编码回环」校验
19. 杀构建后重跑前 `taskkill //F //IM java.exe`（Git Bash 双斜杠），否则新构建挂起零字节
20. **drift 迁移只能在真机验**：内存库单测只证明 `onUpgrade` 逻辑，**证明不了覆盖安装路径** → 发版前 `adb install -r` 覆盖旧包确认老数据还在
21. **别在一条消息里并行编辑同一个文件**：并发 Edit 同文件会静默丢改动，analyze 才暴露 → 同文件编辑要串行
22. **涉及手势命中与「点完再敲字」的连续操作，widget 测试会绿但必须上真机**
    （F7.5-a 真机抓到 3 个：`SingleChildScrollView` 以 `HitTestBehavior.opaque` 吃掉「点空白关闭」手势 → 改 `Align`；`ChoiceChip` 默认 `showCheckmark` 选中变宽致位移 → `showCheckmark: false`；chip 填入词与后续输入之间缺空格 → 类型指令失配）
23. **`SegmentedButton` 的回调是 `onSelectionChanged`**（Flutter 3.32+ 已移除 `onSelected`）
24. **两条无共同祖先的历史合并**：`git merge origin/master --allow-unrelated-histories -X ours`；但 `-X ours` 对「我方已删、远端仍在」的文件**不生效**（会复活，如 `budget_card_placeholder.dart`）→ 合并后必须 `git diff --stat <合并前HEAD> HEAD` 复核
25. **A 机特有**：`<ANDROID_SDK>` 曾于 2026-09-11 被磁盘清理误删进回收站 → **别把 `<JAVA_HOME>\` 当垃圾目录**
26. **B 机特有**：缺 `<SQLITE3_DIR>\sqlite3.dll` → 60 条测试报 `near "RETURNING": syntax error`；A 机实测不需要
27. **资产页口径**：账户余额 = **初始余额 + Σ收入 − Σ支出**，**transfer 不计**（方向语义未落库）；
    净资产 = 各未删账户余额之和，**全时间累计**；初始余额**不允许负数**
28. **widget 测试开 bottom sheet 后要先 `pumpAndSettle` 再找按钮**：滑入动画途中调 `ensureVisible`
    会按「还没到位」的视口算滚动，把按钮顶到屏幕外 → tap 报 offset 越界（像「按钮不存在」，极具误导性）
29. **写操作刷新优先用 `dataEpochProvider`**（`ref.read(dataEpochProvider.notifier).bump()`），
    别再逐个 provider 手工 `refresh()` —— 已因漏刷 `statsProvider` 出过 bug
30. **`find.text` 默认 `skipOffstage: true`，会跳过「视口之外」的列表子项**（不只是 `Offstage`）：
    `SliverMultiBoxAdaptorElement.debugVisitOnstageChildren`（`widgets/sliver.dart:1289`）只把
    `layoutOffset ∈ [scrollOffset, scrollOffset+remainingPaintExtent)` 的子项算 onstage → 800×600 视口里
    **滚不到的内容即使已构建也搜不到**。断言长页面靠下的元素前先
    `scrollUntilVisible(find.xxx(..., skipOffstage: false), 200)`。
    注意 `tester.ensureVisible` 的 finder **必须**带 `skipOffstage: false`，否则它自己就找不到目标。
31. **`tester.tap(find.widgetWithText(AppBar, '保存'))` 是陷阱**：它命中 **AppBar 自身**，`tap` 取 AppBar 的
    **中心点**（标题区）→ 点不到右上角按钮，而且 `warnIfMissed` 不报警（中心点确实在 AppBar 内）→ **静默无操作**。
    要点按钮里的 `Text`：`tap(find.text('保存'))`（`record_save_entry_test.dart` 就是这么写的）。
32. **真机 adb 命令一律加 `MSYS_NO_PATHCONV=1`**：Git Bash 会把 `/sdcard/...` 转成 Windows 路径 →
    `adb push` 报 `remote secure_mkdirs failed`、`uiautomator dump` + `pull` 找不到文件（**报错文案完全不提路径转换，极难联想**）
33. **`tool/ui_dump.py` 报的坐标可能是「整张卡的容器中心」而不是真实按钮** → 点了没反应时别怀疑没改包，
    用原始语义树按 node `bounds` 自己换算（踩过：投放卡的 `选择文件` 按钮真实 y=639，dump 报 y=483）
34. **清走查残留 / 造数据**：`run-as com.teacodeman.yanxin sqlite3 app_flutter/yanxin.sqlite "..."`（设备自带 sqlite3 可用）；
    **改前先 `cp` 备份**成 `app_flutter/yanxin.sqlite.bak-<日期>`。详见 `mumu-flutter-ui-smoke` 对应小节
35. **`git push -q 2>&1 | tail -N` 在本沙箱会静默失败**（远端没更新、退出码仍 0）→ **直接 `git push` 不加重定向**，
    推完用 `git ls-remote origin refs/heads/master` 核对哈希（别信 `git status -sb` 的 `[ahead N]`）
36. **本机（2026-09-23 起）Dart 起不了「需要管道 stdio」的子进程** → `flutter analyze / test / pub / build_runner`
    在本机直连**全废**（**仅限本机** —— 用户在自己的 Git Bash 终端里这些命令**正常**，已实测跑通 `flutter test`）。
    看到 `CreateFile failed 231 (所有的管道范例都在使用中)` + `process_win.cc:744` **别怀疑代码**，是主机级命名管道问题；
    **别去换 Dart 版本、别去杀进程、别去开 `dangerouslyDisableSandbox`**（都试过，无效）。
    本机自查用替代（**均已入库**）：① `python tool/dart_analyze_fallback.py` —— ≡ `flutter analyze`
    （Python 起同一个 `analysis_server_aot.dart.snapshot` + Dart **原生协议**，含全部 lint，全项目 19s）；
    ② `python tool/dart_test_fallback.py` —— ≡ `flutter test`（Python 起 `frontend_server` 编译 + `flutter_tester.exe`
    执行；**纯 `test()` 292/292 实测全绿**（`v0.7.11` 基线），⚠️ `testWidgets` 跑不了）；③ `python tool/data_layer_probe.py`（数据层脱离 Flutter 真跑）；
    ④ **构建 APK**：`python tool/build_kernel_fallback.py`（≡ `flutter assemble` 的 kernel 步骤）+
    `./gradlew assembleDebug -x compileFlutterBuildDebug` —— ⚠️ **`gradlew assembleDebug` 不加 `-x` 也会撞 231**
    （`:app:compileFlutterBuildDebug` 内部是 `flutter.bat → dart → frontend_server`；2026-09-23 那次能通是偶发）；
    **装机前必从 APK 读 `assets/flutter_assets/kernel_blob.bin` 比 sha256 + grep 新文案**（防「装到旧包」）。
    **注意**：`analysis_server.dart.snapshot` 要 `dart.exe` 跑，`analysis_server_aot.dart.snapshot` 要 `dartaotruntime` 跑；
    ⚠️ **别再走 LSP / 进程内 analyzer 这两条老路**：LSP 全量推送极慢（116 文件 30min 仍未收敛），
    进程内 analyzer 拿不到 lint（analyzer 10 已把 lint 规则移到 `package:linter`）。原生协议的三坑见第 1 条。
37. **进程内跑单测的边界**：只有**不（间接）import `package:flutter`** 的测试才能脱离 `flutter_tester` 跑；
    `core/db/database.dart` 会把 drift + Flutter 一起拉进来 → 纯 Dart VM 没有 `dart:ui`，必失败。
38. **测试文件别在 `main()` 里做 IO / 解析**（2026-09-23 踩到）：加载期的任何异常都会被
    flutter_tools 的 listener 转成 `IsolateSpawnException` → 整个文件报成 `loading <路径>`，
    **真实原因和其余用例结果全丢**。真实件按需读（懒 + 记忆化 + `try/catch` 降级为 `markTestSkipped`）。
39. **`testWidgets` 需要真正的 test 运行器驱动帧**：给一个自造 bootstrap 时它会「启动首例后永不完成」
    （计数停在 `+0`、进程 `rc=0`）—— 极易误判成「全绿」。**判绿必须要求终态汇总行**
    （`All tests passed!` / `Some tests failed.`），只看计数会假绿。
40. **常驻 provider 必须 `ref.watch(dataEpochProvider)`**（2026-09-24 D 批走查抓到的真 bug）：
    非 autoDispose 的 provider 会**永久缓存快照** —— `searchProvider` 只 watch 了 `activeBookIdProvider`，
    于是「刚加账户 / 刚记一笔」后回搜索**搜不到**（实测搜新账户名、新流水金额都落空，杀进程重启才命中）。
    项目既有信号 = `core/providers/data_epoch.dart` 的 `dataEpochProvider`（写操作成功后 bump）。
    **凡「进页面一次性取快照 + 内存过滤」的 provider 都要 watch 它**（`assets_controller` 已如此；
    `reports_controller` 用 `ref.listen` 以免 build 重跑把月份 / 档位重置）。回归测试：`search_freshness_test.dart`。
41. **bottom sheet 的 widget 用例必须用竖屏视口**（2026-09-24 修 3 例失败）：默认 800×600 又宽又矮，
    而底部弹窗高度 = 内容高度（`isScrollControlled: true` 时可逼近整个视口高）→ **弹窗顶边贴到 y=0，遮罩区被吃光**，
    `tapAt` 点哪都在弹窗里。做法：`tester.view.physicalSize = const Size(1080, 2400); tester.view.devicePixelRatio = 2.0;`
    （逻辑 540×1200）+ `addTearDown(tester.view.reset)`；点遮罩取「0 → 弹窗顶边」的中点，
    并断言 `sheet.top > 100`（失败信息带实际几何，避免盲猜）。M3 默认 `constraints(maxWidth: 640)` 会包
    `Align(heightFactor: 1.0)` 纵向 shrink-wrap，`getRect(find.byType(BottomSheet)).top` 就是真实顶边。
42. **实施前先核 SPEC 前提**（F7.7 三批连续踩到）：**A/C/D/E 批的 SPEC 都写过不成立的前提** ——
    C 批说「accounts 已有 icon/color」（实际在 books/categories 上 → 真做了 schema v2→v3）、
    D 批说「要新建 `app_meta` 表 + schema v2→v3」（实际复用既有 `schema_meta` KV → 零迁移）、
    E 批说 `/record?date=YYYY-MM-DD`（实际是**毫秒**）。**照 SPEC 干活前先读代码核一遍**，
    有出入就写回 SPEC §G 并在 CHANGELOG 标明，别默默照抄。
    （F7.9 又踩一次：SPEC 写「吸底栏用 `Scaffold.bottomNavigationBar`」→ 实际它按 `size.height - h`
    贴**屏幕**底、**不随键盘上移**，会被键盘盖住 → 实现前改成 body 内 `Column` 并回写 §3/§6。）
43. **改 UI 入口后，测试断言口径要「无上限」全仓扫**（2026-09-25 F7.9 血案）：删掉 AppBar 的「保存」后，
    `test/features/ledger/home_empty_state_test.dart` 里 `expect(find.widgetWithText(AppBar, '保存'), findsOneWidget)`
    仍留着 → 用户终端回归**直接失败**。两个坑：① 找同类断言时 grep 带了 `head_limit`（当时 40）→ **静默截断**，
    文件根本没出现在结果里；② 关键词太窄（只搜 `AppBar`）。**做法**：搜 `保存` / `ensureVisible` /
    `widgetWithText(AppBar`，**不设上限**，逐条判断「是不是被本批改动影响的页面」（预算卡 / 资产页也有
    「保存」，属各自独立页面，别误改）。
44. **吸底 / 常驻元素的 widget 用例不能再 `ensureVisible`**（F7.9）：`tester.ensureVisible` 内部调
    `Scrollable.of` → 目标**不在任何 `Scrollable` 内时直接抛错**（不是静默跳过）。把按钮从滚动区末尾移到
    `Column` 的兄弟节点后，指向它的 `ensureVisible` 必须一起删（本批删了 3 处）。
45. **用 `Edit` 做「整段替换」时，务必确认 `new_string` 保留了被替换段的标题行**（F7.9 收尾时抓到）：
    给 CHANGELOG 插 F7.9 段时把紧邻的 `## [Unreleased] · 启动图标（adaptive icon）` 标题行吃掉了，
    只剩正文引用块 → 段落在文件里「没有名字」，转正时会直接漏掉一整段。**改完扫一遍
    `grep -n "^## \|^### " <文件>` 核对层级**，别只看 diff 的增删行数。
46. **`gradlew` 必须在 `source env.sh` 之后跑**（F7.13 收尾时踩到）：不 source 就没有
    `GRADLE_USER_HOME`（= `<repo>/.gradle-home`）→ Gradle 退回 `<USER_HOME>\.gradle`，
    而该目录**拒绝删除** → `journal-1.lock (拒绝访问。)`，**2 秒即 BUILD FAILED**。
    表现极像「构建链路坏了 / 缓存损坏」，实为**环境变量没注入** —— 先看有没有 `source env.sh`，别急着清缓存。
47. **验证 `CustomPainter` 用「记录型 Canvas」**（F7.13 新增手法）：`class _Recorder implements Canvas`
    + `noSuchMethod` 只实现要断言的 `drawArc` / `drawCircle`，把入参记下来 → **纯 `test()` 就能锁死画笔行为**
    （如断言 `useCenter == false`、缝隙角度均等），不必上 golden（golden 在无 GPU 的 CI/沙箱里更脆）。
    范例：`test/features/stats/category_pie_test.dart`。
48. **本机 analyze 等效工具会报「同文件两种盘符大小写身份」的假阳性**（2026-09-25 F7.14 发现，全项目 5 条）：
    形如 `Map<int, DayAgg> (where DayAgg is defined in D://…)` 与 `…d://…` 并存。根因 = 代码里
    `package:yanxin/…` 与相对导入（`import '../db/database.dart'`）**混用**，本机路径大小写不一致时
    同一库出现两个身份。**判别手法**：把**未改动**的目录单独当根跑 ——
    `python tool/dart_analyze_fallback.py lib/features/ledger` → 若同样报，就是环境假阳性而非你的改动。
    **别按它去改代码**（真要根治需另开一批统一导入风格 `always_use_package_imports`）。
    ✅ 自查新增文件可用「只传自己目录」的窄根：`python tool/dart_analyze_fallback.py lib/features/onboarding`。
49. **加「首启弹窗」这类全局副作用后，必须同步改测试基建**（F7.14）：`pumpApp` 用**内存库** →
    每个用例对 App 而言都是「全新安装」→ 首启引导会盖住首页，**一次打断 9 个既有测试文件**。
    做法：基建里默认 `set(kOnboardingDoneKey, '1')`（既有用例零改动），只给首启专项用例留逃生口
    （`onboardingDone: false`）。同类风险：将来加「启动广告 / 强制更新 / 权限弹窗」照此处理。
50. **用户报「某后台功能不生效」时，先看它有没有可观测性，再谈修 bug**（2026-10-07 F7.15 走查教训）：
    自动记账有**四个断点**（系统绑定服务 → 服务抓通知 → Dart 触发消费 → Dart 入账），**每层原本都静默** →
    用户只看到「没记上」，开发者也只能靠猜。**定式**：每个断点记「最后一跳」（是否连接 / 最后捕获时间与来源 /
    待处理条数 / 上次处理结果 + 各过滤计数），并在 UI 上**按证据给一句可执行提示**。
    Kotlin 跨进程场景要**落盘**（App 冷启动时 Service 可能已被系统重启，纯内存值会丢），
    但**高频计数只在内存**、随低频事件一起写（否则任意 App 发通知都触发一次写盘）。
    ⚠️ **「用户开关是开的」≠「功能在工作」**：`Settings.Secure` 里查到的只是系统开关，
    国产 ROM 解绑服务后它照样显示「已开启」→ 必须另记 `onListenerConnected` 之类的**活性信号**。
51. **「取走即清空」的队列必须配回写**（F7.15 P0 缺陷）：`drain()` 读出后立刻清文件，
    若消费端有任何 early return（依赖未就绪 / 写库异常）→ 数据**永久消失**。
    要区分**临时性失败**（回写重试）与**永久性失败**（解析不出 → 丢弃，否则无限重试）。
52. **`adb shell cmd notification post` 伪造不了 `packageName`**（F7.15 走查）：发出来是 shell/android 的包名，
    被包名白名单第一层就挡掉 → **该方式只能验「通知能弹出」，验不了「被本 App 捕获」**。
    模拟器上验监听链路只能把 `com.android.shell` 临时加白名单，或**上真机**。
    ✅ 唯一能在无微信/支付宝的模拟器上跑通「落盘 → drain → 解析 → 入账 → 撤销 → 回执」的是
    **`ACTION_SEND` 分享路径**（不受包名白名单限制）。
53. **中文参数传 `adb shell` 必须整串引号**：`adb shell "am start ... --es KEY '中文 文本'"`。
    少这层引号 → 本地 shell 先剥引号、设备端再按空格拆 → `pkg=你已付款成功，优惠`，命令静默跑歪。
54. **debug 包里会出现 `INTERNET` 权限**（F7.15 走查）：Flutter 模板在 `android/app/src/debug/` 与
    `src/profile/` 声明（热重载用），**release 包没有**。走查核对权限列表时**别把这条当成「说好的不联网」矛盾**。
55. **断言卡片上「可能同值的数字」别用裸 `find.text(x)` + `findsOneWidget`**（2026-09-30 预算卡血案）：
    预算卡的「剩余额度」（指标）与「剩余每日可消费」（说明行）在**当月最后一天**必然相等（只剩 1 天）→
    命中 2 个 → **只在每月最后一天必挂**的日期 flake。做法：**按「标签所在最近容器」取同行/同列数值**
    （`find.ancestor(...).first` 最近优先，已核 SDK `finders.dart`）；**日期相关的值不要写字面量**
    （否则把「只在月末挂」换成「天天挂」）—— 期望值用同一个纯函数按真实今天推导。
    另：`test()`（非 widget）能跑时，用 `fail(StringBuffer)` 把可疑中间值打出来，是**最快的取证手法**。
56. **改 UI 入口 / 加新页面后，测试断言口径要「无上限」全仓扫**（第 43 条的复述，F7.15 又踩）：
    grep 别加 `head_limit`（会静默截断），关键词多写几个（`保存` / `ensureVisible` / `widgetWithText(AppBar` /
    具体文案），逐条判断「是不是本批改动的页面」（预算卡 / 资产页也有同名按钮，属独立页面别误改）。

57. **`git fetch/push` 报 "correct access rights / repository exists" ≠ 凭证坏了**（2026-10-17 实测）：
    这是**瞬时网络故障**的通用报错，极易误判成「SSH key 失效」而去做无用排查。
    **30 秒判据**：`ssh -T git@github.com` → 返回 `Hi Xander-299! You've successfully authenticated`
    即凭证与 22 端口都通，**直接重试即可**。
    两条附带事实：① 远端是 **SSH**（`git@github.com:`）→ **不吃 `http_proxy` 环境变量**，配代理对它无效；
    ② `curl https://github.com` 在本沙箱会 **15s 超时**（出口限制）但 **SSH 通**
    → **别用 curl 测通性来判断 git 能不能推**。

58. **Windows `flutter.bat pub get` 会把 `package_config.json` 改写成 Windows 绝对路径 → WSL 里
    `dart analyze` 报**几千个假错误**（2026-11-13 实测 7543 条，`undefined_identifier` /
    `Target of URI doesn't exist` 满地）：
    - 根因：`rootUri` 变成 `file:///C:/Users/<你>/AppData/Local/Pub/Cache/...` 与
      `file:///D:/Download/Flutter/flutter/...`，WSL 读不到 → 所有包都成了「不存在」。
    - 判据：`python3 tool/fix_package_config.py --check` 会直接告诉你当前指向 windows 还是 linux。
    - 修法：`fx-pkgcfg`（= `python3 tool/fix_package_config.py`，默认改成 Linux 路径，秒级、幂等）。
      出包前在 Windows 侧则反向：`--to windows`，或干脆 `flutter.bat pub get`。
    - 口诀：**出了包就别信第一次 analyze 的红**，先看 package_config 指向哪边。

59. **`tool/install_device.ps1` 曾会在「构建失败」时悄悄装上一次留下的旧包**（2026-11-13 踩到）：
    现象是 flutter 已经报 `kernel_snapshot_program failed`，脚本仍打印一个 APK 的包名/版本，
    差点把 `app-x86_64-release.apk` 推到 arm64 真机（换个包名场景就会**装错包**）。
    已改：① 只认「本次构建新产出 且 与 `-Mode` 匹配」的 APK，否则直接 `Fail` 并给出
    「WSL 改过 package_config → 先 Windows 侧 pub get」的提示；② 复用旧包必须显式 `-NoBuild`（且会大声提示）；
    ③ 装前用 `aapt dump badging` 的 `native-code` 与设备 `ro.product.cpu.abi` 比对，ABI 不匹配直接挡。
    附带：debug 包构建失败时**先看是不是第 58 条**，别急着找代码问题。
