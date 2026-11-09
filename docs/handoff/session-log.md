# 逐轮会话记录（历史档案）

> 从原 `HANDOFF.md` 顶部拆出：按会话轮次记录的交付过程、根因与取证。
> **这是历史，不是当前状态** —— 当前状态见仓库根的 [`HANDOFF.md`](../../HANDOFF.md)。
> 首次接手请先读根 HANDOFF 的「现状」与「必须守住的不变量」，再按需回查这里。

---

## 2026-11-09 · v0.8.3 发布：A+B+C + 三 ABI 包 + 发布闸门

**交付**：PR #11（A1–A3 / B1+C1 / B2+C2 / P2-1，含 6 个 hunk 级拆分提交）→ tag **`v0.8.3`**（`2f2c6d6`）→
Release 提供 arm64 / armv7 / x86_64 三个包（`--split-per-abi`，versionCode 4003/3003/6003）。

**事故（值得记住）**：首包用 `--no-pub` + 手工 `.dart_tool` 在干净 worktree 里构建，
缺 `.flutter-plugins-dependencies` → 插件注册表为空 → `sqlite3_flutter_libs` 未注册 →
**装得上、签名对、能启动，但全站白屏**（`MissingPluginException`）。
修复 = 先 `flutter pub get` 再 `flutter build apk`，并把「APK 内必须有 `libsqlite3.so`」等检查固化成
`tool/release_preflight.py`（PR #14）。以后出包顺序：`pub get` → build → preflight → `install_device.ps1 -Smoke`。

**其它**：
- 设备上原有 0.7.16（versionCode **4001**），MIUI 连 `-d` 都拒绝降级 → 用户同意后卸载重装（数据未保留）。
- 真机验收用 `screencap` + Windows OCR（`Windows.Media.Ocr`，zh-Hans-CN）逐词取坐标点击：
  完成「记一笔 ¥12.34 → 保存 → 首页回显」。uiautomator 读不到 Flutter 语义（未开 TalkBack 时为空）。
- 仓库改名 `Xander-299/xiaomao-keeping`，旧 GitHub URL 301、旧 Pages URL 404；README/网页下载入口改指三包。
- 分支清理到只剩 `master`，仓库开启 **Automatically delete head branches**。
- **本地工作区仍有 351 条未提交的 Design System v2 改动**（分支 `docs/product-quality-audit @ 42f43c1`，远端已删），未进 master。

---

## 2026-10-25 · 阶段二任务 1：设备 × 模型基准表（只加工具与文档，零产品代码）

> 用户拍板：**「先等我连手机，按 HANDOFF 出基准表」**；模型分发（D4）**等基准表出来再定**。
> 真机随即上线（`MRN7ONWCUSHYG65D` / Redmi K50 `rubens`），本轮把表做完。

**做法**（不走 APK，走 adb + llama.cpp 原生二进制，避免被「中文路径构建 / R8 / 内存」这些已知坑拖住）：

1. 库外 `D:\yanxin-llm-bench` 浅克隆 llama.cpp `b7050`（`dd091e5`）→ NDK 28.2 交叉编出
   arm64 的 `libllama.so` / `libggml*.so` + `llama-cli` / `llama-bench`；
2. 自己写探针 `tool/llm_bench/bench_android.cpp`（llama-bench 拿不到「冷加载 / 逐轮 RSS」这两列）；
3. 模型从 **ModelScope** 下（HF 与本机 12 s 超时），三个候选 Q4_K_M，**逐个校验 sha256**；
4. `run_bench.ps1` 推模型 → 跑 10 轮 → 主机侧每 15 s 采电池温度 / 大小核频率 → 直接吐 markdown 行。

**实测**（4 线程绑大核 / ctx 2048 / dotprod 变体）：

| 模型 | 冷加载 | 首 token | pp tok/s | tg tok/s | 峰值 RSS |
|---|---|---|---|---|---|
| Qwen2.5-1.5B-Instruct | 1.70 s | 5.07 s | 36.4 | 7.4 | 1185 MB |
| Qwen3-1.7B | 1.63 s | 5.66 s | 32.2 | 6.6 | 1350 MB |
| Gemma-3-1B-it | 1.19 s | 3.51 s | 50.4 | 8.8 | 885 MB |

20 分钟（68 轮）长跑：tg 7.4 → 7.0、大核 2.85 → 2.15 GHz、电池 +1.4 ℃、RSS 不涨。

**三个「反直觉但实测如此」的结论**：

- **dotprod 只提速预填**（pp +47%，tg 不变）→ 说明生成受**内存带宽**限制，这也解释了为什么 20 分钟降频不掉速；
- **线程数必须等于大核数**：不绑核 tg −27%，开 8 线程（含小核）**腰斩到 3.7**；
- **模型会自然地把数算错**（Gemma 把「已花 4520.36」说成「超支 4520.36」；Qwen2.5 超支额对、每日额度编）
  → 坐实 SPEC 的分层：**数字只从 Dart 来，模型只做措辞**。

**踩坑六个**（都已写进 `HANDOFF.md` 的坑清单）：HyperOS 屏蔽 thermal_zone（温度只能用 `dumpsys battery`）·
toybox `taskset` 只吃十六进制掩码 · PowerShell 5.1 需要 UTF-8 **with BOM** 且 `2>/dev/null` 会被自己吃掉 ·
NDK `clang++.cmd` 会丢 `-L… -lxxx`（改全路径）· 源码必须编在库外（中文路径 + 体积）·
`adb push` 走符号链接目录会 Permission denied。

**交付**：`tool/llm_bench/`（探针 + 两个脚本 + 语料）、`docs/dev/llm-benchmark.md`（报告）、
`docs/dev/llm-benchmark-raw.md`（逐轮原始数据）、SPEC §10、HANDOFF、CHANGELOG `[Unreleased]`。
**未做**：`LlmProvider` / JNI / 查询编排 / 问答页；第二台设备；JSON 约束与工具调用。

---

# HANDOFF.md — 颜芯记账 uni-app → Flutter 迁移（F1–F7.6 **全部交付** ✅ · F7.7 五批 A/B/C/D/E 全部落地 ✅（`v0.7.7`–`v0.7.10`）· **F7.8 流水左滑删除** ✅（`v0.7.11`）· **F7.9 记一笔吸底保存 + 启动图标 adaptive** ✅（`v0.7.12`）· **统计页图表两处绘制修复** ✅（`v0.7.13`）· **F7.14 新手引导** ✅（`v0.7.14`）· **F7.15 自动记账** ✅（**`v0.7.15`** · 通知使用权为主 + 零权限兜底 · 2026-10-07 活性诊断补丁 + **2026-10-08 真机走查修复**）· **F7.16 自动记账三段修复** ✅（**`v0.7.16`** · **A 补抓** `d44f8c6` / **B `[N条]` 折叠前缀误杀** `85e416d` / **C 撤回通道 + 补抓守护层** `84a35ed` —— 2026-10-09 用户提「**用悬浮窗在支付成功页采集**」，经查证**否决**：该权限读不到别屏文字且 Play 政策封杀；实测真因是**支付通知只活 26 秒、点进即撤回** + **`posted` 推送在该机型完全不投递且重绑救不了** · **2026-10-20「扩展监听清单」经用户拍板不做 → F7.16 收口转正**）· **2026-10-17 README 新增「项目简介（简历可用）」章节**（用户要拿它做简历项目：实测规模 + 8 条带证据的技术难点 + 16 行版本迭代记录，另补「版本号三来源」说明；提交 `5e8ab51` / `82767d9`，已推 GitHub））

> **新会话接手时，只读这一个文件就能继续干活。**
> 最后更新：2026-10-20 17:10 · 更新人：AI 助手（**本机 = A 机**）
>
> **🟢 交接时刻状态（2026-10-20 · **F7.16 已收口并打 tag `v0.7.16`**）**：
> **代码基线仍 = `84a35ed`**（F7.16 C：撤回通道 + 补抓守护层，11 files / +974 −1）；
> A 段 = `d44f8c6`、B 段 = `85e416d`。
> 10-09 → 10-20 期间**零功能代码改动**（10-17 三连更只改 `README.md`；10-20 只改文档 + 角标）。
> **最新 tag = `v0.7.16`**（2026-10-20 收口）—— **F7 阶段 16 个版本全部交付并已打 tag**。
> ⭐ **F7.16 最后一个遗留项已由用户拍板关闭**：「**扩展内置监听应用清单**」**不做**
> （核心理由：**其它平台的支付最终都是银行卡支出** → 微信/支付宝通知已覆盖，
> 扩白名单会**重复记账**；且现指纹含 `pkg` → 跨来源必然不重 → 必须先做跨应用去重，
> 收益为负）。**银行短信**（`com.android.mms`）本批**不纳入**（需 `READ_SMS` 敏感权限）。
> → **F7.16 零代码改动转正**，本项目**无未收口批次**。
>
> **⏭️ 下一步**：**等用户排新需求**（F7 阶段已全部交付并打 tag）。
>
> **📦 2026-10-20 追加交付：release 版本可下载体验** —— `flutter build apk --release` 已跑通
> （**本机 Dart 的 231 命名管道故障已消失**，`Process.runSync` 恢复 → 走标准路径即可，
> 不再需要 `tool/build_kernel_fallback.py`）。GitHub Release `v0.7.16` 已发布
> （通用包 64 MB + arm64 单独包 22 MB，正式签名 `CN=yanxin`），
> 新增 `tool/publish_release.py`（走 REST API，令牌从 git credential manager 现场取、不落盘）。
> README 已重写为「功能地图 + 项目结构 + 部署教程」，简历向内容拆到 `docs/RESUME.md`。
> 若将来要做「绕过微信/支付宝的支付渠道」（白条 / 月付 / 云闪付 NFC）单独记账，
> **必须先做跨应用去重**（见 CHANGELOG `v0.7.16` 的 D 段与 `MEMORY.md`）。
>
> **🔵 本轮（三）（2026-10-09 20:05 · **F7.16 C · 「通知被丢弃」** · 代码基线 `84a35ed`）**：
> - **用户主诉**：数据采集靠读通知，但「**返回微信/支付宝后通知会被丢弃，没来得及采集**」
>   → 提方案：**用悬浮窗权限在支付成功页就采集**（附微信「支付成功 ¥0.01」页截图）。
> - **裁定：悬浮窗方案 ❌ 不可行（前提即错）**。三条独立事实：
>   ① **`SYSTEM_ALERT_WINDOW` 只授权「在别应用上层画窗口」，读不到别屏任何文字**
>   （Play 把它与 screen capture / accessibility 明确分列，且是 Restricted Permission）；
>   ② 要读别屏文字只能换 `AccessibilityService` → **Play 政策仅允许「服务身心障碍者」**，
>   **Android 17.2 起 APM 模式下非无障碍工具被系统直接切断**；
>   ③ 用户截图那个页面**只有金额**，通知里本来就有（`已支付¥0.01`）→ **信息增量为零**。
> - **取证（新增 `tool/probe_notify_lifecycle.py`，Redmi K50）**：支付通知**只活 26 秒**
>   （19:16:03 出现 → 19:16:29 最后可见 → 19:16:31 被撤回，轮询 160 次）；
>   **对照组**支付宝「交易提醒」存活 **419 秒仍在** → **撤回不是通知自己消失，
>   触发点是「用户点进支付成功页」**。撤回后 `getActiveNotifications()` 捞不到。
> - **⚠️ 更硬的根因（推翻了原设计）**：同一笔 ¥0.01，`onNotificationPosted` **一条都没收到** ——
>   进程健康（`foreground` cgroup、49 线程、未冻结、`oom_score_adj=250`）、绑定在
>   （`Live notification listeners` 有）、补抓通道通。**且重绑也救不了**
>   （`disallow`→`allow` 能恢复 `onListenerConnected` 与补抓，posted 仍 **0 条**）
>   → 失效在「**NotificationManager → listener 的事件投递**」，**不可通过重绑自愈**。
> - **修 3 项**：① **`onNotificationRemoved` 第三层兜底**（撤回那一刻 extras 仍完整，
>   AOSP 保证只丢 `contentView`/`largeIcon`）；② **`AutoBookGuard` 补抓守护层**（新文件，
>   `AlarmManager` 60s 周期 + **醒来续期**，不用 `setRepeating` —— doze 会静默丢弃致永久停摆）；
>   ③ **通道可用性自暴露**（8 个诊断字段 + `/autobook` 新增「采集通道」一行）。
> - ✅ **真机端到端（Redmi K50 · 两笔真实 ¥0.01 均自动入账）**：
>   `20:01:02` 由补抓捞到；**`20:05:31` 由 `removed → CAPTURED` 独立救回**
>   （发生在通知已被撤回、补抓已捞不到之后）→ `removedCaptureTotal` **0 → 1**，
>   DB **163 → 164**、合计 **¥2363.42 → ¥2363.43**。
>   守护层实测**每 ~53 秒准点触发**（19:57:09 → 19:58:02 → … → 20:06:01，共 12 轮）。
> - **门禁**：analyze 等效 **全项目 `No issues found!`** ✅；autobook 四文件 **99 passed / 0 failed**
>   （`diagnostics` **17** / `flow` 17 / `real_samples` **18** / `rules` 47；
>   ⚠️ **未跑全量**，但本批 Dart 改动仅 `lib/features/autobook/` 内 4 文件，已被这四个文件覆盖）。
>   APK **BUILD SUCCESSFUL** + dex **13/13 探针命中** + **正式签名重签后覆盖安装（数据零丢失**，
>   DB 196608 B / `integrity_check ok`）。
> - **两条踩坑（都差点误判成「环境坏了」）**：
>   ⚠️ **`adb install -r` 会 force-stop 应用并清掉已排期的闹钟** —— 装完立刻测会得到
>   「守护层从不被触发」的**假结论**（本次先误判了一轮）。必须**装完 → 重绑 → 给足重排期时间**。
>   ⚠️ **「logcat 里 `posted pkg=` 为 0」不能证明回调没来** —— 代码只在
>   `decision != NOT_WATCHED` 时打日志，而 `cmd notification post` 的探针是
>   `com.android.shell` 包名 → 走 NOT_WATCHED 分支 → **一行日志都不打**。
>   **唯一可信判据是内存计数差分**（本次靠 `skippedNotWatched` 4730→4847 与 catchUp
>   扫描量比对才拿到真结论）。
> - **⏭️ 唯一遗留**：**扩展内置监听应用清单**（待做）—— 现 `externalId = sha1(pkg|title|text|postTime)`
>   **含 pkg**，跨来源必然不重 → **跨应用去重是必做前置**；京东/拼多多/抖音的普通支付
>   资金流经微信或支付宝，加白名单会**重复记账**。另发现银行短信（`com.android.mms`）是独立通道。
>
> **🔵 本轮（二）（2026-10-09 凌晨 · **F7.16 B · 微信支付「识别不到」** · 代码基线 `85e416d`）**：
> - **用户主诉**：通知栏里有支付宝、微信各一条支付消息，**均未被捕获** → 要求查因并修 bug。
> - **排查第一步就推翻了「没送到」的直觉**：诊断快照 `lastCapturePkg=com.tencent.mm`、
>   `capturedTotal` 在涨，且 `autobook_seen.json` 里**赫然有**
>   `com.tencent.mm|微信支付|[3条]微信支付: 已支付¥0.03|1791473495452`
>   → 微信那条**已经被捕获入队了**，问题在**捕获之后**（队列已清空，但 DB 的 `notify_wechat` 仍是 7）。
>   Kotlin 日志 `catchUp(channel) 活动通知=87 补入队=1` @23:31:40 与 `lastCaptureAtMs` 完全吻合
>   → 这条是**补抓**进来的（A 段修复已生效）；实时回调当时**没到**。
> - **真根因**：`auto_book_rules.dart` 的组摘要兜底 `^\[\d+条\]` 把正文 `[3条]微信支付: 已支付¥0.03`
>   判成「组摘要」→ `parseNotification` 返回 null → **静默丢弃**。
> - **推翻旧判据的取证**（`dumpsys notification --noredact`，Redmi K50）：`Group summaries:` 段**无
>   `com.tencent.mm`**；`flags=0x11` 不含 `FLAG_GROUP_SUMMARY=0x200`；`groupKey == 自己的 key`
>   （未进任何分组）；`tickerText = 微信支付: 已支付¥0.03`（**无前缀** → 前缀是显示层加的）。
>   当年被当成反例的两条（`[2条]…已支付¥0.01` + `[2条]…个人收款码到账¥0.01`）其实是**两笔不同交易**。
> - **修 3 项**：① Dart 把「丢弃」改成「**归一化**」（剥 `^\s*\[\d+条\]\s*` 再解析，`combined` /
>   `externalId` 均用归一化文本 —— 折条数 `[2条]`→`[3条]` 不改变指纹，不会变成两笔）；
>   ② Kotlin 删掉「Dart 侧另有 `[N条]` 兜底」的错误注释，并给 `onNotificationPosted` / `catchUp`
>   的判定链**整体兜异常 + 打日志**（此前抛出去被系统吞掉，外部只看到「什么都没发生」）；
>   ③ 测试把原「`[N条]` 必须丢弃」的 3 条**反转为回归守卫**。
> - ✅ **真机验证（Redmi K50 · 端到端）**：把真机原文注入落盘队列 → 回前台 drain → DB **167 → 168**、
>   `notify_wechat` **7 → 8**，新增 `amount_cents=3 / expense / note=微信支付 /
>   occurred_at=`**`2026-10-08 23:31:35`**（= 通知真实发布时刻，不是补记时刻）。
> - **门禁**：analyze 等效 **全项目 `No issues found!`** ✅；autobook 三文件 **82 passed / 0 failed**
>   （`flow` 17 / `real_samples` **18** / `rules` 47）。⚠️ **未跑全量** —— 但 `real_samples` 本次被
>   **反转**（原「必须丢弃」3 条 → 「必须入账」），它正是这次判断错误的载体。
> - **教训**：① **同一件事只留一处权威判据** —— 上游 Kotlin 用系统标志判对、下游 Dart 用文本正则
>   判错，且宽的那套在**下游** → 必然「上游放行、下游静默丢弃」；② **`skippedGroupSummary` 涨了
>   ≠ 丢得对**，计数只说明「丢了」不说明「该丢」，本次靠逐条比对真实通知与系统登记表才推翻它；
>   ③ 兜底规则的注释要写清「它想防的具体场景」，否则后人无从判断它是否仍成立。
>
> **🔵 上一轮（A）（2026-10-08 深夜 · **F7.16 事故修复**「通知栏里有支付消息但一条都没记上」· 代码基线 `d44f8c6`）**：
> - **用户主诉**：通知栏里有支付宝、微信各一条支付消息，**均未被捕获** → 要求查因并修 bug。
> - **真根因（真机钉死，不是关键词识别问题）**：`onNotificationPosted` 是**推送式回调** ——
>   通知在服务**未连接期间**发布时，系统**不会在连上后补发** → **永久丢失**。证据链：支付宝付款通知
>   `交易提醒 / 你有一笔3.00元的支出…` 发布于 **22:29:37**，而服务 **22:49:40** 才连上；
>   `lastCaptureAtMs` 停在 17:52:33、`capturedTotal` 恒为 2，而 `skippedNotWatched=226`
>   说明服务此前确实工作过（**「活着但没接上」**）。
> - **修 4 项**：① **补抓（catch-up）** —— `catchUp()` 扫 `getActiveNotifications()`
>   （24h 内 / 白名单 / 非组摘要 / 去重），在 `onListenerConnected` 时立即跑，并由 Dart 每次
>   `drainQueue()` **之前**经新通道方法 `catchUp` 触发；② **`AutoBookSeen`（新文件）** 持久化
>   「已入队指纹集」`pkg|title|text|postTimeMs`（cap 200）—— 补抓会反复看到同一条通知，队列又是
>   「取走即清空」，不持久去重就会**每次回前台重复入队**并盖掉「上次检查」；**指纹必须带 postTimeMs**
>   （否则「已支付¥1.00」同文案多笔被误判重复）；③ **可观测性** —— 抽出 `handle(sbn, fromCatchUp)`
>   让**实时与补抓共用同一条判定链**（两处各写一遍必然漂移）+ `Decision` 枚举逐层 `Log`；
>   诊断补 5 个补抓字段且**必然落盘**（此前 `noteSkippedDedup` 不落盘 → 「回调没来」与
>   「来了被去重丢掉」在文件上**完全不可区分**）；④ Dart 桥接 + 控制器插步骤 + `caughtUp`。
> - ✅ **真机验证（Redmi K50）通过**：重绑监听 → `onListenerConnected` → 补抓扫 **87** 条活动通知、
>   补入队 **2** 条 → drain 后数据库 **165 → 166**，新增那笔 `amount_cents=300 / expense /
>   notify_alipay / occurred_at=`**`22:29:37`**（**真实支付时刻被完整保住**，而非补记时刻）。
>   **去重有效**：`catchUpTotal=6` 而 `catchUpAddedTotal` 恒为 **2** → 反复补抓**零重复入队**。
>   顺带验证解析：那条同时命中软忽略词 `红包`/`提醒`，但含强支付词 `支出` → 正确放行；
>   金额取 `3.00元的支出` = 300 分（**没被营销尾巴「领3元电费红包」的 3 元抢走**）；
>   同批捞进的营销广告被 Dart 侧按 `direction == null` 丢弃 → **只 +1 不 +2** ✅。
> - ⚠️ **补抓的固有边界**：只能捞「**此刻仍在通知栏里**」的通知 —— 微信那条 `已支付¥1.00` 验证时
>   已被系统清掉（`grep -c 已支付` = 0），**补不回来**（用户需手动补记）。**补抓是兜底，
>   主防线仍是服务保持连接时的实时捕获。**
> - ⭐ **重绑监听姿势被修正**：单独 `allow_listener` **不生效**（setting 里有、App 进程也在，
>   但 `Live notification listeners` 没有本服务、`dumpsys activity services` 是 `(nothing)`）——
>   **必须 `disallow_listener` → 2s → `allow_listener` 走一遍「变化」**才触发重绑。
>   判定「到底绑上没」**只看 `Live notification listeners`**（`Allowed` 段只反映 setting）。
> - ⚠️ **`android/local.properties` 会被 flutter 工具改写**：用户跑过 `flutter build apk --release` 后
>   它变成 `buildMode=release / versionCode=1` → 直接 `assembleDebug` 出的包 **versionCode=1**，
>   而设备上是 **2001** → `install -r` 必撞降级。**构建前先看一眼这个文件**（不入版本控制）。
> - **门禁**：analyze 等效 **全项目 `No issues found!`** ✅；`auto_book_flow_test` **17 passed / 0 failed**
>   （15 → 17，+2）。⚠️ **本轮未跑全量 479** —— 本批 Dart 改动仅 autobook 内 3 个文件
>   （`bridge` / `controller` / 其测试），已由 `auto_book_flow_test` 覆盖。
> - **下一轮输入（F7.16 扩展清单）**：现有白名单已是最窄（仅微信 + 支付宝）；Android **无系统级按包筛选 API**。
>   候选渠道扫描结论 —— 京东 / 拼多多 / 抖音的普通支付**资金流经微信或支付宝** → 已有支付宝通知覆盖，
>   加白名单会**重复记账** → **跨应用去重是必做前置**（现 `externalId = sha1(pkg|title|text|postTime)` **含 pkg**，
>   跨来源必然不重）。另发现**银行短信**（`com.android.mms`，发件人「中国银行」）是独立通道，
>   覆盖所有走卡交易，但需 `READ_SMS` 且与支付通知重叠区更大。
>   `showPending`（「识别到 N 笔支付通知」）按**队列条数**弹，补抓可能一次捞进多条营销通知 → 建议届时一并设计预筛。
>
> **🔵 上一轮（2026-10-08 凌晨 · F7.15 真机走查修复 · 代码基线 `e4e53b4`）**：
> - **用户主诉**：支付宝 / 微信**能抓到通知但入不了账**（怀疑关键词识别）→ 要求排查 + 真机查验（Redmi K50）。
> - **真根因（真机文案钉死）**：支付宝付款通知**标题就是「交易提醒」**、正文「你有一笔0.01元的支出，
>   领1元生活缴费红包。」→ 旧硬忽略表里 `提醒` + `红包` **两处一票否决** → **静默丢弃** → 一笔都记不上。
> - **修 4 项**：① 硬忽略**收窄**为「必然非消费」词（**新增 `还款`**）+ `提醒/红包/优惠/立减/满减/活动/
>   领取/积分/即将` **降级为软忽略**（无强收支词才丢）+ 强收支词补 `支出/收入/已收款/成功收款`；
>   ② **组摘要去重**（MIUI `[2条]微信支付: 已支付¥0.01` 与子通知文案不同 → 指纹不同 → 记两遍）→
>   Kotlin 按 `FLAG_GROUP_SUMMARY` 过滤 + Dart `^\[\d+条\]` 兜底；③ **金额优先级** ——
>   新增「金额在动作词之前」规则，压过营销语里的金额（**记错数比不记更糟**）；
>   ④ **`last_run` 空 drain 覆盖** —— 空队列且无撤销时不再写（实测入账 **7 秒后**被抹成「没有新的支付通知」）。
> - **诊断层「瞒报」族（P1，本轮排查的最大障碍，先修它才能定位）**：`capturedTotal` 11→0（persist 抹盘）/
>   空 drain 把 `drainedTotal` 8→0（共用 `== 0L` 守卫被毒化）/ `skipped*` 从不落盘 /
>   `listenerConnected` 从盘上回填 → force-stop 后**谎报「已绑定」**（正好掐掉页面那条国产 ROM 提示）。
>   → `AutoBookDiagnostics.kt` 重写为 **「盘上基线 + 本进程增量」** 合成；`listenerConnected` **故意不回填**。
> - **真机验证（Redmi K50）**：① 系统绑定 ✅ / ② 服务收通知（`skippedNotWatched` 0→1）✅ /
>   ③ Dart 取队列 ✅ / ④ 解析入账（`imported:6 dropped:2` 逐条吻合）✅ /
>   **⑤ 用户实付支付宝 ¥0.01 → 端到端入账 `cents=1 / expense / notify_alipay`** ✅ /
>   诊断修复在「空 drain → persist」（旧版必挂）下 `drainedTotal` 稳在 1 ✅。
> - **⚠️ 现场教训（对真实使用有影响）**：**MIUI/HyperOS 在 `force-stop` 后会解绑监听服务**，
>   而 `settings` 与 `dumpsys` 都显示「已授权」—— 正是既有教训「**用户开关是开的 ≠ 功能在工作**」。
>   **好消息**：重新绑定（设置里「通知使用权」关→开）会让系统把**仍在通知栏的活跃通知重投**
>   （实测延迟 1 分 37 秒）→ 页面那条提示**真能救回数据**，不必重付。**代价**：force-stop / 覆盖安装后**必须重绑一次**。
> - **门禁已闭合**：analyze 等效 **全项目 `No issues found!`** ✅；本机纯 `test()` **386 例全绿 / 0 失败**（分 4 批）
>   → ✅ **2026-10-08 用户终端全量 `flutter test` `479 passed / 0 skipped`**（= `test()` 391 + `testWidgets` 88；
>   本批 +79 全落在 `test()`）。autobook 三文件 `rules` 47 + `flow` 15 + **新增 `real_samples` 16**（文案逐字抄自真机）。
> - **工具**：新增 `tool/parse_notif_dump.py` / `tool/watch_notifications.py`；
>   `dart_test_fallback.py` 加 `FX_TEST_WORK_SUFFIX`（原固定产物路径，多实例并行会互相覆盖）。

>
> **🔵 F7.15 自动记账（**✅ 已交付 · tag `v0.7.15`**）**：
> - **需求**（用户）：「做一个自动记账功能，可能涉及权限问题，给几个方案选择」→ 选完授权后追加
>   「能不能在通知栏里确认入账（右侧两个按钮）」→ 技术核对后**裁定设计乙**：保留静默入账，
>   通知是「**已记账**」回执 + `撤销` / `查看` 两个按钮（设计甲的「通知栏 `导入`/`取消` 待确认收件箱」否）。
> - **SPEC**：`docs/spec/SPEC-F7.15-auto-bookkeeping.md`（已签字；§3.7 三处硬约束 + §3.5 忽略规则默认值）。
> - **架构（唯一重决策）**：Kotlin **只做「包名过滤 + 落盘 JSONL 队列」**，**不解析、不碰库**
>   （drift 是唯一 DB writer）；Dart 在 `AppShell` **首帧后 + 每次 `resumed`** drain
>   → 解析 → 按 source 分组 → **复用 `importRows()`** → 记批次 → 刷新 → 回执通知。
>   **不启 headless FlutterEngine**（接受「入账延迟到下次打开 App」）。
> - **平台侧**（本项目**首次**引入 manifest 权限 / 服务 / intent-filter）：新增
>   `android/.../autobook/`（Listener / Queue / Notifier / Channel）+ `MainActivity` 接线 +
>   manifest（`POST_NOTIFICATIONS`、`<service>` 带 `android:exported="false"` 与
>   `BIND_NOTIFICATION_LISTENER_SERVICE`、`ACTION_SEND` filter）+ 矢量通知小图标。
>   **零 Gradle 新依赖**（权限自检走 `Settings.Secure`，不用 androidx）。
> - **Dart 侧**：新增 `lib/features/autobook/`（rules / bridge / batches / accounts / controller / notice / page / banner）
>   + `/autobook` 路由 + 「我的」条目 + 首页 `MonthHero` 上方提示条；
>   `ImportReport` **追加** `importedIds` / `importedAmountCents`（有默认值，既有调用方零改动）。
>   `source` 取值域 `notification` → `notify_wechat` / `notify_alipay` / `share`（TEXT 无 CHECK → **零迁移，DB 仍 v3**）。
> - **门禁**：analyze 等效 **全项目 `No issues found!`** ✅；终端 `flutter test` **479 passed / 0 skipped**
>   （2026-10-08 用户全量）；本机纯 `test()` **386 例全绿 / 0 失败**（14 个 `testWidgets` 文件本机跑不了）。
> - **走查要点（AI 经 adb）**：MuMu 上**没有真实微信/支付宝支付** → 用
>   `adb shell cmd notification post` 造合成通知（包名被伪造不了 → 见 SPEC §6 说明，只能验链路），
>   验「解析 → 去重 → 入账 → 撤销 → 回执通知」；**真实通知文案必须用户在自己手机上抓取后回填规则表**。
> - ✅ **~~已知风险~~ → 已在 2026-10-07 走查补丁中修复**：忽略规则里的 `优惠` / `立减` / `满减`
>   会误杀真实回执（「付款成功，优惠 0.5 元」），**用户反馈的「只成功过一次」高度命中此条**。
>
> **🟠 本轮补丁（2026-10-07 · 用户反馈「自动记账不生效，只成功过一次」· 已实现 + 模拟器走查通过）**：
> - **第一交付 = 可诊断性**：功能有四个断点（系统绑定服务 / 服务抓通知 / Dart 触发 / Dart 入账），
>   **每层原本都静默**，用户只能看到「没记上」→ 新增 `AutoBookDiagnostics.kt`（关键事件跨进程落盘）
>   + channel `diagnostics` + `/autobook` 页「**诊断**」区块（监听服务 / 最近捕获 / 待入账 /
>   上次检查 / 抓取统计 + **按证据给一句可执行提示**）+ 「上次检查」落 `schema_meta` KV
>   （`autobook_last_run`，**零迁移**）。
> - **修 3 个缺陷**：
>   ① **丢账路径**（P0）：`drain` 是「读出即清空」，而 Dart 侧有三条 early return（账本未就绪 /
>   写库异常 / 处理中断）→ 这批通知**永久消失** → 新增 `AutoBookQueue.restore()` + channel
>   `restoreQueue`：**临时性失败回写重试，解析不出的（永久性失败）仍丢弃**（否则无限重试）。
>   ② **忽略规则误杀真实回执**（P0）：拆成 硬忽略 / 软忽略 / 强支付词 三张表，
>   「软忽略命中且无强支付词」才丢。
>   ③ **多金额取错**（P1，修 ② 后立刻暴露）：多金额时原实现取第一个数字 = **优惠金额**
>   → 金额优先级重排：**实付类 > 支付动作紧邻 > 货币符号 > 裸金额**。
> - **模拟器走查（MuMu · 用 `ACTION_SEND` 分享路径，不受包名白名单限制）**：
>   落盘 → drain → 解析（「你已付款成功，优惠 0.50元，实付 12.00元」正确取**实付 ¥12.00**）→
>   入账 → 自动建「分享记账」账户 → 首页提示条「已自动记账 1 笔 · 合计 ¥12.00」→
>   撤销（软删 `deleted_at` 非空 + 摘除批次）→ **回执通知**（`channel=autobook` / 标题
>   「已自动记账 1 笔」/ 正文「合计 8.00 · 点『撤销』可一键撤回」/ 动作 `撤销`·`查看` / InboxStyle）
>   → **诊断区块五行全部与真实状态一致** ✅
> - **本机门禁**：analyze 等效 **全项目 `No issues found!`**；`auto_book_rules_test` **42 passed**、
>   `auto_book_flow_test` **13 passed**；APK **BUILD SUCCESSFUL**（Kotlin 新增文件编译通过）；
>   `verify_apk_kernel` 新鲜度一致 + 4 个新文案命中。
> - ⚠️ **仍未验证**：`NotificationListenerService` 监听路径（模拟器无微信/支付宝，
>   `cmd notification post` 又伪造不了包名 → 被白名单挡）+ **真实通知文案**
>   → **忽略表 / 金额优先级 / 商户提取三处仍是对着推测文案写的**。
>   （→ ✅ **以上两项已于 2026-10-08 真机走查验完**，见上方「本轮（2026-10-08）」块。）
>
> **🔴 上一轮（F7.14 新手引导 · **已交付 ✅ `v0.7.14`** · 收尾四步已执行完毕 · 无遗留项）**：
> - **需求**（用户）：让第一次使用的用户知道「没有明显标识的按钮 / 隐藏手势」是做什么的。
> - **用户裁定四项**（SPEC `docs/spec/SPEC-F7.14-onboarding.md` §7）：① 形式 = **全屏分页导览**；
>   ② 内容 = 四项全覆盖 → **7 页**；③ 重看入口 = 「我的」页新增可点条目「新手引导」；
>   ④ **老用户不弹**（只在新装时自动弹）。
> - **实现**：新增 `lib/features/onboarding/`（keys / prompt provider / page / slides / art）+
>   `/onboarding` 路由 + `AppShell` 首帧后触发 + 「我的」条目卡首位入口。**零新依赖、不动 schema（仍 v3）**。
> - **判定「该不该弹」** = 无 `onboarding_done` **且** `ActiveBookIdController.isFreshInstall`
>   （新字段 = 本次 build 读到的 `active_book_id` 为 null）。
>   ⚠️ **别**用「本次是否走了 `ensureDefaultBook` 分支」当判据 —— 「当前账本被软删」也会命中该分支。
> - **「看过」标记收口在引导页 `dispose()`**：跳过 / 完成 / 系统返回三条路径都是 `pop()`，
>   摘树后由 `dispose` 一处写入（写失败静默），因此**不需要 `PopScope`**。
> - **测试基建已改**：`pumpApp` 默认**预写** `onboarding_done` —— 内存库对 App 而言都是「全新安装」，
>   不预写会让首启引导盖住首页、**一次打断既有 9 个测试文件**；首启专项用例显式传 `onboardingDone: false`。
> - **门禁**：`flutter test` **400 passed / 0 skipped**（用户终端全量；= `test()` **312** + `testWidgets` **88**，
>   本批 **+17**）；analyze 等效 —— 本批新增文件 **`No issues found!`** ✅（全项目残留 5 条为既有环境假阳性，
>   见「盲区防护」第 48 条）；**真机走查 D1–D10 全部通过、0 崩溃** → `docs/acceptance-F7.14-onboarding.md`。
> - **收尾**：提交线 `02f9041`（代码 + SPEC）→ `c5ea1b5`（CHANGELOG 转正 + 走查报告）；
>   tag **`v0.7.14`**（tag 对象 `b3c08c2`）已推远端（`refs/tags/v0.7.14^{}` = `c5ea1b5`）。
> - ⚠️ **本轮走查踩坑**：`uiautomator dump` 写固定 `/sdcard/_ui.xml`，App 切换瞬间 `cat` 会读到**陈旧内容**
>   → 首启那次误判成「引导没弹」（库里 `transactions=0`、屏幕上却有旧流水，两边矛盾）。处置 = 独立文件名
>   + 截图交叉验证（已回写 skill）。**判据：语义树与数据库状态矛盾时，先怀疑落盘缓存。**
>
> **上一轮（`v0.7.13` 已收尾 ✅ · 统计页图表两处绘制修复 已交付并推远端 ✅）**：
> - **`v0.7.13` 已打 tag 并推远端**：用户终端 `flutter test` **383 passed / 0 skipped**（本轮 **+11**）→
>   CHANGELOG 新增 `## [v0.7.13]`（A / B 小节）→ 我的页角标 → `git tag -a v0.7.13`（tag 对象 **`19fb246`** →
>   提交 **`0773333`**）→ 直推 → `git ls-remote` 核对通过（远端 `master` 亦 `0773333`）。
>   **纯修复版**：零新依赖、不动 schema（仍 v3）。
> - **A · 分类占比圆环画成「风车楔形」**（用户报「统计图样式有问题」）：根因是 `drawArc` 的 `useCenter`
>   误传 `true` —— 该参数**与描边样式无关**，为 true 时路径 `moveTo(圆心)` 再连回圆心，
>   `strokeWidth = outer*0.34`（约 25px）的粗描边把两条半径线画成实心带（五瓣叠成风车 + 盖住圆心文字）。
>   两处 `useCenter` → `false`（含空态底槽）；接缝改**两端各让一半**（原先首尾收口宽成 `gap·n`，5 瓣时 5.7° vs 1.1°）。
> - **B · 趋势图零值月也画柱**：4–7 月无流水却各画一对 2px 内高的基座胶囊（像「每月都有小额收支」）→
>   用户裁定**不画**；抽纯函数 `trendBarHeight(cents, max) → double?`（null = 不画，`max <= 0` 一并挡住除零），
>   `_Bar` 早退留**同宽占位**（有数据的柱不漂移、标签不错位）。
> - **新增测试 +11**：`category_pie_test.dart`（5 例，**记录型 Canvas** —— `implements Canvas` +
>   `noSuchMethod` 只实现 `drawArc`/`drawCircle`，直喂 painter 断言入参）/ `trend_bars_test.dart`（5 例纯函数）/
>   `stats_page_test.dart` +1 例 `testWidgets`（独立 pump `TrendBars`，断言 `Tooltip` 恰好 1 个）。
> - ✅ analyze 等效 **0 issue**；✅ 真机走查（`.workbuddy/qa-stats/` 前后对比图 + 柱位置零漂移核验）0 崩溃；
>   ✅ **收尾四步已执行完毕** → 报告 `docs/acceptance-F7.13-stats-charts-fix.md`。**无剩项**。
>   ⚠️ 本轮踩坑：`gradlew` **必须在 `source env.sh` 之后跑**，否则 `GRADLE_USER_HOME` 缺失 →
>   `journal-1.lock (拒绝访问。)` 2 秒即 BUILD FAILED（像「构建坏了」，实为环境变量没注入）。
>
> **上一轮（`v0.7.12` · F7.9 记一笔吸底保存 + 启动图标 adaptive + 1 处构建阻塞修复）**：删 AppBar 顶部
>   「保存」、底部主按钮改**吸底常驻**（⚠️ 必须放 body 的 `Column`，**不能用 `Scaffold.bottomNavigationBar`**
>   —— 它按屏幕高贴底、**不随键盘上移**）；启动图标补三层 adaptive 资源（API 26+ 不再被套白底白圈）；
>   顺带修掉 `signingConfigs { }` 写在 `buildTypes { }` 之后的顺序错误（连 `./gradlew assembleDebug` 都挂）。
>   `372 passed`；tag 对象 `dcab296` → 提交 `1f3ec96`。
>
> **更早轮次（`v0.7.11` F7.8 左滑删除 / F7.7 A–E 五批 / F7.6 P1–P3 视觉改版 / F1–F7.5）** —— 细节看
>   `CHANGELOG.md` 各版本段 + `docs/acceptance-*.md`（`acceptance-F7.9-record-sticky-save.md`、
>   `acceptance-F7.8-swipe-delete.md`、`acceptance-F7.7-DE.md`、`acceptance-first-run.md` 等）。
>   其中**仍有效**的三条：
>   ① **构建路径** = `source env.sh` → `python tool/build_kernel_fallback.py`（产 kernel_blob）
>   + `./gradlew assembleDebug -x compileFlutterBuildDebug` —— `gradlew assembleDebug` **直连会撞 231**
>   （`:app:compileFlutterBuildDebug` 内部是 `flutter.bat → dart → frontend_server`）；
>   ② **常驻 provider 要 `ref.watch(dataEpochProvider)`** 才不「过期快照」
>   （回归测试 `test/features/search/search_freshness_test.dart`，注释掉那行 watch 必失败）；
>   ③ **验证 `CustomPainter` 用「记录型 Canvas」**：`implements Canvas` + `noSuchMethod`，
>   只实现要断言的 `drawArc` / `drawCircle` → 纯 `test()` 即可锁死画笔入参，不必上 golden（见 `category_pie_test.dart`）。

---

