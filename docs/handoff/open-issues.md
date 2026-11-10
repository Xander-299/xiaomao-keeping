# 未解决问题

> 说明：**F7.7 五批（A→E）+ F7.8 左滑删除 + F7.9 吸底保存 + 启动图标 adaptive + 统计页图表绘制修复
> + F7.14 新手引导 + F7.15 自动记账 全部实现并交付**（`v0.7.7`–`v0.7.15` 已打 tag），**无待签字批次、无遗留项**；
> 第 **1** 条是**环境级阻塞**（本机 Dart 起不了子进程），**只影响本机** —— 已由 9 个等效 / 核验 / 生成工具绕开
> （analyze / test / 数据层 / **APK 构建** / **装机前 kernel 核验** / 图标链 / pubspec 体检，见第 1 条末尾的「构建路径」）；
> 第 **2** 条**已闭合**（F7.13 统计页图表绘制修复收尾完毕；其下含 F7.9 / F7.8 留档）；
> 第 **6** 条**已闭合**（F7.14 新手引导，`v0.7.14` 已交付并推远端，2026-09-25）；
> 第 **7** 条**已闭合**（F7.15 自动记账，`v0.7.15` 已交付并推远端，2026-10-08 —— 真机断点 ①–⑤ + 用户终端 `flutter test` 479 全过）。
> F2 / F5 已裁定保持现状（2026-09-23）。

1. 【**最高优先 · 环境阻塞**】本机 **Dart VM 起不了任何子进程**（2026-09-23 发现）。
   - **现象**：`ProcessException: 所有的管道范例都在使用中 (CreateFile failed 231)`（`runtime/bin/process_win.cc:744`）。
     受影响：`flutter analyze` / `dart analyze` / `flutter test` / `dart pub get` / `dart run build_runner` / debug APK 构建。
     **精确边界（2026-09-23 实测）**：只影响需要管道 stdio 的 `ProcessStartMode.normal` 与 `Process.runSync`；
     `inheritStdio` / `detached` 不建管道、**可用**（但仍救不了 `flutter test`，见下）。
   - **根因（已定位到 Win32 调用级）**：Dart 在 Windows 上用**命名管道**做 stdio —— 先
     `CreateNamedPipeW(PIPE_ACCESS_OUTBOUND | FILE_FLAG_OVERLAPPED, nMaxInstances=1, ...)`，
     再 `CreateFileW(pipe, GENERIC_READ, ...)` 打开客户端；**本机第二步恒返回 `ERROR_PIPE_BUSY (231)`**。
     stdin 是第一个被创建的管道 → **凡需要管道 stdio 的 spawn 都在第一步就死**。
   - **复现矩阵（Python ctypes 直调 Win32，不经 Dart）**：

     | 服务端 access | 客户端 access | 结果 |
     |---|---|---|
     | `PIPE_ACCESS_OUTBOUND` | `GENERIC_READ` | ❌ 231 |
     | `PIPE_ACCESS_OUTBOUND` | `GENERIC_READ\|GENERIC_WRITE` | ❌ 231 |
     | `PIPE_ACCESS_DUPLEX` | `GENERIC_READ` | ❌ 231 |
     | `PIPE_ACCESS_DUPLEX` | `GENERIC_READ\|GENERIC_WRITE` | ✅ |
     | `PIPE_ACCESS_INBOUND` | `GENERIC_WRITE` | ✅ |

     即「**只读语义的管道客户端打开被拒**」（`nMaxInstances` 改 255 无效、`FILE_FLAG_OVERLAPPED` 无关、
     `dwShareMode` 无关）。**纯主机行为，与项目代码无关**；Python 的 `subprocess`（走 `CreatePipe`，无名管道）**完全不受影响**。
   - **已排除**：Dart/Flutter 版本问题（`dart.exe` 连 `cmd /c echo` 都起不来）；沙箱开关（`dangerouslyDisableSandbox` 无效）；
     句柄/进程数耗尽（245 进程、命名管道命名空间仅 186 个）；无注入 DLL 迹象（模块快照被拦，拿不到）。
   - **解除方式（用户侧，按推荐顺序）**：
     ① **在自己的 Git Bash 终端**里跑 `source env.sh && fx-qa`（**不在 WorkBuddy 沙箱内，最可能直接可用**）；
     ② 重启 Windows / 重启 WorkBuddy Desktop 后再试；
     ③ 若 WorkBuddy 安全中心能关闭「文件 / IPC 审计」类拦截，关掉后再试。
   - ✅ **`flutter analyze` 的等效门禁（已入库：`tool/dart_analyze_fallback.py`）**：
     `dart analyze` 的真实实现就是「起 `dartaotruntime + analysis_server_aot.dart.snapshot` 子进程 + Dart 原生协议」，
     本脚本用 Python 起**同一个 snapshot**、喂**同一套 `analysis_options.yaml`** → 口径一致（含全部 lint）。
     - 跑法：`python tool/dart_analyze_fallback.py`（可传目录，默认整个项目）。
     - **结果：`No issues found!`**（全项目 19s，退出码 0）。
     - **已校准（别省这步）**：临时探针文件（双引号 + `final int`）能被正确报出
       `prefer_single_quotes` / `prefer_const_declarations` → 证明 **lint 规则在线**，不是「lint 没生效所以 0 issue」。
       服务器对干净文件也推空数组 → 「0 诊断」无歧义。
   - **协议三坑（改脚本前必读）**：① 原生协议在 stdio 上是**行分隔 JSON**（`stdin.writeln`），
     **不是** LSP 的 `Content-Length` 帧；② `setAnalysisRoots.included` 必须 **OS 路径且无尾斜杠**
     （URI / 尾斜杠会让服务器报 `INVALID_FILE_PATH_FORMAT` 且**不回响应**，伪装成挂死）；
     ③ 完成信号 = `server.status` 的 `analysis.isAnalyzing` 由 true → false。详见 `docs/spec/SPEC-F7.7-backlog.md` §G。
   - ✅ **`flutter test` 的等效门禁（已入库：`tool/dart_test_fallback.py`）** —— 2026-09-23 新突破，推翻此前「无解」结论。
     `flutter test` 本体就是 flutter_tools 起**两个原生子进程**：
     ① `dartaotruntime + frontend_server_aot.dart.snapshot` 把测试文件编译成 dill；
     ② `<flutter>/bin/cache/artifacts/engine/windows-x64/flutter_tester.exe <dill>` 执行之。
     两者都是**原生进程** → Python `subprocess` 可直接起（不受命名管道 231 影响）。
     参数一律**抄 flutter_tools 源码**：`compile.dart`（编译）、`test/flutter_platform.dart:143
     generateTestBootstrap`（引导文件）、`test/flutter_tester_device.dart`（tester 参数）。
     关键发现：真身的引导文件会连 websocket 拉结果，**不连也能跑**（无远程监听器时 flutter_test 自己跑完并打 `+N:`）。
     - **实测结果（本机全量 37 个测试文件）**：**纯 `test()` 226 例全绿、0 失败 0 跳过**。
     - ⚠️ **能力边界**：`testWidgets` 跑不了 —— `AutomatedTestWidgetsFlutterBinding` 需要真运行器驱动帧，
       只给 bootstrap 时它会「启动首例后**永不完成**」（计数停 0、rc 仍 0）。故含 widget 的文件报「未跑完」
       而**不会假绿**（终态汇总行是硬门槛）。
     - ✅ **那 63 个 `testWidgets` 已由用户在自己的终端补齐（2026-09-23 下午）：整个套件全部通过。**
       即 **`flutter test` 门禁已闭合**；本机这个脚本从此只作「本机自查」手段，**不再算门禁前置**。
     - ⚠️ 解析坑：计数顺序是 `+通过 ~跳过 -失败`（不是 `+ - ~`）且只打非零项；进度行时间戳自带冒号，
       先剥 `^\d\d:\d\d ` 再切。**上线前务必用「必然失败」的探针校准**。
   - ✅ **构建（APK）：2026-09-24 找到可行路径**（推翻此前的「无替代方案」结论）——
     `flutter build` 与 `cd android && ./gradlew assembleDebug` **都会撞 231**
     （`:app:compileFlutterBuildDebug` 里是 `flutter.bat → dart → frontend_server`；2026-09-23 那次
     `gradlew` 直连能通，是当时的偶发宽松期，**现在已稳定复现失败**）。
     新路径（**Python 当父进程**，`subprocess` 走匿名管道不受影响）：
     ```bash
     source env.sh                                       # GRADLE_USER_HOME 必须指进工作区
     python tool/build_kernel_fallback.py                 # ≡ flutter assemble 的 kernel_snapshot + copy_flutter_bundle
     cd android && ./gradlew assembleDebug -x compileFlutterBuildDebug
     ```
     参数逐字照抄构建日志里 `kernel_snapshot_program` 的命令行；**上线前必须核验** APK 内
     `assets/flutter_assets/kernel_blob.bin` 的 sha256 与盘上一致 + grep 本次新增文案（防「装到旧包」）。
     细节见 `docs/acceptance-F7.7-DE.md` 文末。**2026-09-24 D/E 批走查即用这条路完成装机。**
2. 【**已闭合** · **F7.13 统计页图表两处绘制修复** → `v0.7.13` 已交付并推远端】
  功能代码 `8826b57`（修复 + 新增测试）→ `c5847b4`（角标）→ `0773333`（CHANGELOG 转正 = tag 指向），工作区干净：
   - ✅ `flutter analyze`：**0 issue**（`python tool/dart_analyze_fallback.py` → `No issues found!`）。
   - ✅ `flutter test`：**383 passed / 0 skipped**（用户终端，2026-09-25；= `test()` **302** + `testWidgets` **81**，
     本轮 **+11** = `category_pie_test` 5 + `trend_bars_test` 5 + `stats_page_test` 1）。
   - ✅ **真机走查**（F7.13，MuMu 12，AI 经 adb 全包）：圆环无楔形、缝隙均匀；4–7 月零柱、8/9 月柱位置与高度**零漂移**；
     `logcat -b crash` **0 崩溃**。报告 `docs/acceptance-F7.13-stats-charts-fix.md`（含前后对比图，
     截图在 `.workbuddy/qa-stats/`）。
   - ⚠️ **本轮踩坑**：`gradlew` 必须在 `source env.sh` **之后**跑 —— 否则 `GRADLE_USER_HOME` 没注入 →
     `journal-1.lock (拒绝访问。)` **2 秒即 BUILD FAILED**（看着像「构建链路坏了」，实为环境变量缺失）。
   - ✅ **收尾四步已执行**：① CHANGELOG 新增 `## [v0.7.13]`（A/B 小节）+ tag 表补行；
     ② 我的页 `_BrandTip` 角标 `v0.7.12` → `v0.7.13`（`c5847b4`）；③ `git tag -a v0.7.13`
     （tag 对象 `19fb246` → 提交 `0773333`）→ `git push && git push --tags` →
     `git ls-remote --tags` 核对通过（远端 master 亦 `0773333`）；
     ④ 文档收尾：本文件 + `tasks/todo-flutter.md`。

   **以下为 F7.9 记一笔吸底保存 + 启动图标（`v0.7.12`，已闭合）细节留档** ——

   - 功能代码 `d0ab794`（F7.9）→ `ec55229`（图标）→ `661ec6b`（回归修复）→ `004f10a`（pubspec 重排）→
     `5ccb7c2`（角标）→ `1f3ec96`（CHANGELOG 转正 = tag 指向）。
   - ✅ `flutter analyze`：**0 issue**（`python tool/dart_analyze_fallback.py` → `No issues found!`；
     顺带修掉 `sort_pub_dependencies` 1 条 info）。
   - ✅ **真机走查**（F7.9，MuMu 12）：D1 / D2 / D3 / D5 / D6 / D8 通过、**0 崩溃**；**D4（键盘）未直接取证** ——
     MuMu 有硬件键盘映射不弹软键盘，改矮视口做等价验证。报告 `docs/acceptance-F7.9-record-sticky-save.md`。
     走查造的 `12.34` 一笔已用左滑删除清掉，首页回到 286.88。
   - ✅ **启动图标**：装机后桌面 = 黄底圆角方 + 「记账」，**无白底白圈**（`ec55229`）。
   - ✅ `flutter test`：**372 passed / 0 skipped**（用户终端，2026-09-25；= `test()` **292** + `testWidgets` **80**）。
     ⚠️ 首轮曾 1 例失败（`home_empty_state_test.dart` 仍断言 `AppBar` 有「保存」）→ 已改口径（`661ec6b`）。
   - ✅ **收尾四步已执行**：① CHANGELOG 两个 `[Unreleased]` 段**合并转正** `## [v0.7.12]`（A/B 小节）+ tag 表补行；
     ② 我的页 `_BrandTip` 角标 `v0.7.11` → `v0.7.12`（`5ccb7c2`）；③ `git tag -a v0.7.12`
     （tag 对象 `dcab296` → 提交 `1f3ec96`）→ `git push && git push --tags` →
     `git ls-remote --tags` 核对通过（远端 master 亦 `1f3ec96`）；
     ④ 文档收尾：本文件 + `docs/spec/SPEC-F7.9-record-sticky-save.md` §8 + `tasks/todo-flutter.md`。

   **以下为 F7.8（`v0.7.11`，已闭合）细节留档** ——

   - ✅ `flutter test`：**371 passed / 0 skipped**（**2026-09-25 用户终端全量通过**，本批 +10,
     = `test()` **292** + `testWidgets` **79**）；本机纯 `test()` 新增 5 例亦实测全绿。
   - ✅ **真机走查**（2026-09-25，MuMu 12 / 900×1600 @320dpi，AI 经 adb 全包）——
     左滑露出红色「删除」（行内金额节点 x 450 → 363）/ 点动作区弹既有确认框 / 取消回弹且数据不变 /
     单开（滑第二行时第一行自动收起）/ 点已展开行 = 收起且不跳编辑 / 竖向滚动正常 /
     月历翻月 9月↔10月 正常 / 报表页左滑零位移（只读保持）；`logcat -b crash` **0 崩溃**。
     记录：`docs/acceptance-F7.8-swipe-delete.md`。走查删的 2 笔（-74 / -33）已改库还原
     （备份 `yanxin.sqlite.bak-20260925`）→ 重启复核首页 286.88 一致。
   - ✅ **收尾四步已执行**：① CHANGELOG `## [v0.7.11] — 2026-09-25 · F7.8 流水左滑删除`
     （段首门禁数字 + 走查结论 + 回滚 `git checkout v0.7.10`）+ tag 表补行；
     ② 我的页 `_BrandTip` 角标 `v0.7.10` → `v0.7.11`（等宽替换，单独提交 `8c56e9f`）；
     ③ `git tag -a v0.7.11`（tag 对象 `6357de1` → 提交 `e984023`）→ `git push && git push --tags`
     （直推、不加管道）→ `git ls-remote --tags origin | grep v0.7.11` 核对通过（远端 master 亦 `e984023`）；
     ④ 文档收尾：本文件 + `docs/spec/SPEC-F7.8-swipe-delete.md` §8 + `tasks/todo-flutter.md` 已勾选。
   - ⚠️ **若后续改动撞 test 失败，先索要完整失败原文**（文件名 + 用例名 + `[E]` 块）再动手 ——
     易踩点已固化：widget 视口 800×600 太矮（bottom sheet 用例要切竖屏视口）、
     `find.text` 默认 `skipOffstage: true` 搜不到视口外元素（见「盲区防护」第 30/31/39 条）。
   - 历史两轮失败反馈（2026-09-23，用户终端）**均已修复 / 关闭**，教训已固化进「盲区防护」：
     ① `tap(find.widgetWithText(AppBar, '保存'))` 会点 AppBar 中心 → 静默不保存（第 31 条）；
     ② 目标在绘制区外 → `find.text` 搜不到，须 `scrollUntilVisible(..., skipOffstage: false)`（第 30 条）；
     ③ `bill_decode_test` GBK 用例未复现（判定环境 / 编译缓存，复跑前 `flutter clean && flutter pub get`）；
     ④ `real_bills_test.dart` 报 `loading <路径>` → `main()` 已改**零 IO**（懒读 + 降级 `markTestSkipped`）加固，
     复跑未再出现（第 38 条）。**若再复现，要那行 `loading` 的完整 `[E]` 块。**
3. 【**已闭合**】**所有「建设中」占位已点亮** —— 4 处「报表」入口（F7.7 A 批）+「我的 → 数据导出」（B 批）
   + 账户图标 / 颜色（C 批）→ **当前无占位页**。实现细节见 `docs/spec/SPEC-F7.7-backlog.md` §G。
4. 【低】日历页在**横屏/矮窗口**下需滚动才能看到当日账单（竖屏真机不用）—— 属预期行为，除非要专门为横屏排一版布局。
5. 【**本轮首次使用验收**（F7.7-a）】报告 `docs/acceptance-first-run.md`：数据层 **实跑 13/13 断言**（真实仓储 + 真实聚合，
   内存库）+ UI 层静态走查。六维度：D2 通过（**A 类前置 = 0**，冷启动 100ms 自带账本 / 现金账户 / 15 预置分类）、
   D5 不通过、D6 部分。遗留：
   - **已修（阻断级 F1）**：报表页不随写操作刷新 —— 新用户顺着报表空态「去记一笔」记完第一笔，回报表仍是空态。
     修法：`ReportsController.build()` 里 `ref.listen(dataEpochProvider) → refresh()`（`watch` 会把月份 / 档位重置回当月 + 明细）。
     加了 2 例测试；analyze 等效门禁 0 issue；**UI 未验证**（本机跑不了）。
   - 【**已裁定 · 保持现状**】F2：首页 header「报表」与「全部账单 ›」**不带年月** → 报表落到「它自己记得的月份」
     （日历页 / 月份选择页的入口都带）。SPEC §A.2.3 没写这两条 → 用户 2026-09-23 裁定**保持现状不改**。
   - 【待办】F3：8 处 `加载失败：$e` 直出异常字符串、无重试（核心路径 2 处：`home_page.dart:51`、`reports_page.dart:63`）
     → 抽 `LoadFailure`（人话 + 重试按钮）。
   - 【待办】F4：「我的 → 设置」副标题承诺「主题、默认账户、货币单位」但整行不可点（纯文案 1 行）。
     ⚠️ 2026-09-25 F7.14 用户**明确裁定不点亮该行**（避免改变已登记待办的语义）→ 新手引导的「重看」入口
     改放「我的 → 新手引导」（条目卡首位）。**别顺手把「设置」行改成真入口**。
   - 【**已裁定 · 保持现状**】F5：入口「全部账单 ›」vs 落地页 AppBar 标题「报表」（SPEC 要求入口文案保持）—— 用户 2026-09-23 裁定不改。
   - 【待办】F6：记一笔页返回即丢已输金额 / 备注（可加 `PopScope` 二次确认）。
   - 数据层实跑入口（`flutter test` 不可用时的替代）：`python tool/data_layer_probe.py`。

6. 【**F7.14 新手引导 · 已闭合 ✅**】`v0.7.14` 已交付并推远端（2026-09-25）：
   - ✅ 用户终端 `flutter test` **400 passed / 0 skipped**（= `test()` 312 + `testWidgets` 88）。
   - ✅ 真机走查（SPEC §2 的 D1–D10）**全部通过、0 崩溃**：① 全新安装首启弹 ② 已看过不弹
     ③ **老用户（有 `active_book_id`、无标记）不弹且不被误写标记** ④ **系统返回也写标记**
     ⑤ 矮视口（逻辑 450×500）不溢出 ⑥「我的 → 新手引导」可重看 ⑦ 引导前后业务数据零改动。
     → 报告 `docs/acceptance-F7.14-onboarding.md`。
   - ✅ 出包路径（本轮再次验证可用）：`source env.sh` → `python tool/build_kernel_fallback.py` →
     `( cd android && ./gradlew assembleDebug -x compileFlutterBuildDebug )` → `python tool/verify_apk_kernel.py 新手引导`。
7. 【**✅ F7.15 自动记账 · 已全闭合**】已实现 + 模拟器走查通过 + **真机走查通过（2026-10-08 · Redmi K50，代码基线 `e4e53b4`）** + **用户终端全量 `flutter test` 479 passed / 0 skipped** → 已打 tag **`v0.7.15`** 并推远端：
   - ✅ **真机监听路径已验完（不再是「等用户验」）**：断点① 系统绑定（`cmd notification allow_listener` +
     `dumpsys activity services`）/ ② 服务收通知（发非白名单探针 → `skippedNotWatched` **0→1**）/
     ③ Dart 取队列 / ④ 解析入账（8 条真实文案注入 → `imported:6 dropped:2` 逐条吻合）/ ⑤ **真实支付端到端**：
     **用户实付支付宝 ¥0.01 → 入库 `cents=1 / type=expense / src=notify_alipay`**（金额·方向·来源全对）。
   - ✅ **真实通知文案已回填**：`test/features/autobook/auto_book_real_samples_test.dart`（16 例，**逐字抄自真机**）
     —— 忽略表 / 金额优先级 / 商户提取**不再是「对着推测文案写的」**。
   - ✅ **用户终端全量 `flutter test` 已通过**（2026-10-08，**479 passed / 0 skipped**；本机跑不了 14 个 `testWidgets` 文件）。
     ⚠️ 上次记录的 `transaction_repository_test` 「编译阶段挂住」**本轮未复现**（跑完 `+12`，并发下耗时 610s）。
   - ⚠️ **现场教训（对真实使用有影响，已写进页面提示口径）**：**MIUI/HyperOS 在 `force-stop` 后会解绑监听服务**，而设置与
     `dumpsys` 都显示「已授权」（难查的「开关开着但没工作」）→ force-stop / 覆盖安装后**必须重绑一次**；
     **重绑会把仍在通知栏的活跃通知重投**（实测延迟 1 分 37 秒）→ `/autobook` 页那条提示**真能救回数据**，不必重付一笔。
   - 📌 **本地环境备注（非产品遗留）**：`android/local.properties` 被改成 `flutter.versionCode=2001` / `buildMode=debug`
     （**不入版本控制**，为「同签名覆盖安装保数据」）—— 正式出包前若要 release 号需确认还原；本机无 `flutter` CLI，
     改 `pubspec.yaml` **不会**自动刷新它（曾因此撞 `INSTALL_FAILED_VERSION_DOWNGRADE`）。

   **「诊断」五行 → 断点定位表（用户报「不生效」时照此问）**：

   | 诊断行显示 | 断在哪一层 | 处置 |
   |---|---|---|
   | 监听服务：**未绑定** | 系统绑定层 | 国产 ROM 后台限制 → 进系统设置关掉「通知使用权」再开一次（**重开会把仍在通知栏的活跃通知重投，不必重付一笔**） |
   | 最近捕获：**从未收到** | 服务抓通知层 | 确认微信/支付宝的「允许通知」是开着的 |
   | 待入账 **> 0** | Dart 触发层 | App 没回到前台（drain 只在首帧后与 `resumed` 跑） |
   | 上次检查：**N 条不符合记账条件** | 解析规则层 | 规则不匹配 → **要用户把那几条通知原文发回来** |
   | 上次检查：**写库失败 / 已回写队列** | Dart 入账层 | 看 `autobook_last_run` 的 error 字段；队列已回写等下次重试 |

**F7.6 P3 轮已清掉的旧待办**：

| 原编号 | 事项 | 处理 |
|---|---|---|
| 旧 3 | `gradle wrapper` 用 `-all.zip`（754 MB） | ✅ 2026-09-23 改 `-bin.zip`（277 MB，镜像已验证可下），构建复跑通过；旧 `-all` 目录已是死重，手工删可回收 754 MB |
| 旧 5① | 资产页「还没有账户」空态仍是 Material 图标 + `FilledButton` | ✅ 走查前改卡通空态（虚线圆 + 小猪 + `ToonButton`） |
| 旧 5② | 日历页月历与「月结余」卡之间留白比原型略大 | ✅ 网格 padding 10→8，留白改由卡 margin 承担 |
| 旧 6 | `docs/dev/windows-env-bootstrap.md` 是 B 机专用 | ✅ 该技能正文顶部加粗体警告，避免 A 机照抄 |
| 新增（走查发现） | **账户弹层根本没卡通化**（P2 只做了取色，SPEC 误记「已复核」） | ✅ 按原型 `ovlAccount` 补做（抓手 + 小标 + 描边输入框 + 类型 chips + 红底流水提示条 + `ToonButton`） |
| 新增（走查发现） | 资产页 AppBar `+` 还是 Material `IconButton` | ✅ 换 `ToonIconButton`；错误态 `OutlinedButton` → `ToonButton` |
8. 【**2026-10-27 · M1 真机走查发现**】两条「真实数据才暴露」的偏差，**都不阻断 M1**，但会挨用户问：
   - **导入跳过的「中性交易」让 App 数字对不上微信账单头部**：同一份 161 行账单，微信头部写
     「支出 153 笔 2183.88 / 收入 8 笔 320.41」，导入后是「149 笔 2105.37 / 4 笔 241.90」——
     两边都差 **78.51 元**（一笔转账的两侧被当「不计收支」跳过）。行为符合 PRD（中性交易不算收支），
     但用户会以为**丢了 78 块**。
     建议：导入报告把跳过项拆开并显示金额（「跳过 8 笔（含转账/提现 ¥78.51）」），
     或在报告页加一行说明「微信账单头部的收支含中性交易，本 App 按 PRD 不计入」。
   - **分类规则在真实微信账单上有偏差**：`手机充值-中国联通` → **居住**（应通讯）、
     `抖音生活服务…` → 其他、`发给~青年旅社…` → **交通**（应其他/旅行）。
     属 `lib/features/import/data/category_rules.dart`（M1 之外）；改之前先跑
     `test/features/import/category_rules_test.dart`，并把这三条真实样本加进去。
9. 【**2026-10-29 · 预置二级分类后的 4 条待拍板**】（背景与数据见
   [`docs/spec/SPEC-F7.18-category-tree.md`](../spec/SPEC-F7.18-category-tree.md) §13.5；HANDOFF「本轮遗留」同源）
   - **记账多一次点击**：一级有子分类后，点「餐饮」进子列表，记到一级上要再点「餐饮（不细分）」。
     缓解方案（未做）：长按一级直接选中。
   - **预置改名 ≠ 停止补装**：没有 `preset_key` 列，用户把「早餐」改成「早饭」后，下一次补装会再插一条「早餐」。
     根治要 schema v5（加 `preset_key`），或补装时按「父级下已有几条子分类」兜底。
   - **统计口径不一致**：饼图 / 报表按「父 · 子」分开列（F7.18 既定），编辑层文案却写「二级分类会计入父分类的统计」；
     只有「问账本」按父级汇总（2026-10-29 修）。要么统一汇总到父级，要么改文案。
   - **导入规则只到一级**：`category_rules.dart` 的「地铁 / 公交 / 单车」仍落到「交通」，
     没落到对应二级（改会动既有导入结果，需确认）。

10. 【**2026-11-03 · A+B+C 最终复审遗留**】只记录，不在本轮 A/B/C 提交里修（避免扩大范围）。
    - **✅ 已修复（2026-11-06）· P2 · 分类编辑 update 成功后 setParent 失败可能造成部分更新**：
      原问题：`CategoryRepository.update` 先写分类主字段，再单独写 `parent_id`；第二步抛错时第一步已提交，
      调用方看到「保存失败」但库里已部分生效。
      修复：`CategoryRepository.update` 新增 `parentId` / `changeParent` 参数，主字段与父级两次写入放进
      同一个 `_db.transaction`（先主字段、后父级），任一步失败整笔回滚；`setParent` 改为复用这条原子路径，
      原有业务校验（不能挂自己 / 父分类存在 / 同收支类型 / 最多两级 / 有子分类不能再降级 / 同父级重名）全部保留。
      `CategoryActions.update` 不再分两次调用仓储。
      回归测试：`test/data/repositories/category_repository_test.dart` 的「分类编辑原子性」组，
      用真实 SQLite trigger（`BEFORE UPDATE OF parent_id … RAISE(ABORT)`）在父级写入阶段注入数据库错误，
      断言名称 / 图标 / 颜色 / 父级 / 排序 / updatedAt 全部保持原值（去掉事务后该用例会失败）。
    - **✅ 已修复（2026-11-10）· P3 · 导入 fingerprint 并发竞争**：
      原问题：`BillImporter.importRows` 先批量 `SELECT fingerprint` 再逐行插入；两个导入并发时都可能通过预查，
      最终由 `(book_id, fingerprint)` 唯一索引兜底，而此时插入**抛错** → 整批回滚，用户看到「导入失败」，
      事实却是「这笔早就有了」。
      修复：`TransactionRepository.importTransaction` 的插入包 try/catch —— 撞唯一索引后**回查一次指纹**，
      查到就返回 `ImportDuplicate`（幂等口径），查不到才 `rethrow`（磁盘 / 锁 / 其他约束仍是真失败）。
      SQLite 的 UNIQUE 默认 `ABORT` 只回滚该条语句、不毁外层事务，所以可以在事务里吞掉再继续。
      回归测试：`test/data/repositories/transaction_import_race_test.dart` —— 用 `BEFORE INSERT` trigger
      精确复现「预查之后、插入之前冒出同指纹行」，断言结果 `ImportDuplicate` 且库里仍只有一行；
      另一例让 trigger 直接 `RAISE(ABORT)`（无同指纹行），断言异常照旧抛出、不被吞成 duplicate。
    - **✅ 已修复（2026-11-10）· P3 · Ledger / Search 删除未检查 affected rows**：
      原问题：`TransactionRepository.softDelete` 返回受影响行数，但首页 / 日历 / 搜索的删除链路只 `await`、
      不校验返回值；行已被其他入口删掉时仍弹「已删除」并展示 Undo —— 而 Undo 会把一条**用户没删过的**
      记录恢复出来，语义是反的。
      修复：`LedgerController.removeTx` / `CalendarController.removeTx` 改为返回 `bool`（受影响行数 > 0）；
      三个入口（首页 / 日历 / 搜索）在 0 行时只刷新 + 显示 `kTxAlreadyGoneMessage`（「这笔流水已经不在了，
      列表已刷新」），**不弹 Undo**。
      回归测试：`test/features/calendar/calendar_delete_confirm_test.dart` 新增「确认时这行已被别处删掉」。
    - **✅ 已修复（2026-11-10）· P3 · 自动记账后台撤销错误缺少 diagnostics / last-run error**：
      原问题：`AutoBookNoticeNotifier.undo` 失败时只回滚事务，没写 `autobook_last_run` 的 error；
      通知栏冷启动撤销失败后，`/autobook` 诊断块看不到原因。
      修复：`undo()` 的写库段包 try/catch，失败时 `_rememberUndoFailure(batchId, e)` 把
      「撤销批次 <id> 失败：<80 字摘要>」写进 last-run（并 bump `dataEpochProvider` 让诊断块立刻重读），
      然后把异常原样抛出。只写 error，不动 imported / duplicates —— 撤销失败不该清掉上次的入账统计。
      回归测试：`test/features/autobook/auto_book_undo_failure_test.dart`（trigger 让软删 ABORT）。
    - **✅ 已修复（2026-11-10）· P3 · 分类 `undelete()` 的校验与写入不在同一事务**：
      原问题：四步裸跑（读原记录 → `_assertNameFree` → 查父分类 → UPDATE），校验通过后、UPDATE 之前若并发
      插入同名活跃分类或删掉父分类，仍会写出一个不该恢复的节点。
      修复：整段包进 `_db.transaction<bool>(...)`，事务内重做全部校验；UPDATE 改用受影响行数兜底
      （并发下被别人先恢复 / 又删一次时返回 false，不再假报成功）。
      回归测试：`test/data/repositories/category_undelete_atomic_test.dart`（正常恢复 / 撞名 / 写入阶段
      trigger ABORT 后仍保持删除态）。
    - **✅ 已修复（2026-11-10）· P3 · 日历请求有效性判定不含 bookId**：
      原问题：`_isCurrentDayRequest` 只比对 `_disposed` / `_dayRequestId` / `selectedDate`，`_loadMonth` 只比
      年月；而 `CalendarController.build()` 不 watch `activeBookIdProvider` —— 换账本后在途请求不算过期，
      旧账本结果会写进新账本视图。
      修复：`build()` 里 `ref.listen(activeBookIdProvider)`，值真的换了（非 null → 另一个非 null）就
      `invalidateSelf()`：旧实例 dispose → 迟到结果全丢，新实例按新账本重拉。**没有**让控制器到处 watch 账本
      （那会把「翻月不动首页月份」的隔离性弄丢）。
      回归测试：`test/features/calendar/calendar_book_switch_test.dart`（两本账本各一笔，切完只剩新账本那笔）。

