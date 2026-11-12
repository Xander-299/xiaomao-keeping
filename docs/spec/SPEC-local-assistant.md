# SPEC（**已签字**）：阶段二 · 本地财务问答 —— M1「问账本」

> **签字**：2026-10-27，用户原话「签字，先做M1看看效果」。
> **签的是什么**：
> 1. **分层架构**（见 §2）：T0 无模型（默认）/ T1 本地模型（可选组件）/ T2 云端（不做，只留接口）；
> 2. **模型不进 APK**：引擎进包（+4.1 MB/ABI），模型 0.77–1.1 GB 由用户自行导入；
> 3. **D4 分发 = a（手动导入 `.gguf`）**，保住「正式包无 `INTERNET`」这条卖点；App 内下载留到 M3 单独立项；
> 4. **先做 M1**（T0），验收标准见 §5。
>
> 依据：`Prompt.md` 阶段二、[`SPEC-local-ai.md`](SPEC-local-ai.md) §4/§10、
> [`docs/dev/llm-benchmark.md`](../dev/llm-benchmark.md)（体积与性能均为实测）。

---

## 1. 为什么先做 M1（不装模型的那一层）

用户提的核心顾虑是「本地部署 LLM，App 体积大、成本高」。实测把账拆开：

| 项 | 实测 | 结论 |
|---|---|---|
| llama.cpp 引擎（arm64，strip 后） | **+4.1 MB**（`libllama` 2.4 + `ggml` 1.8），双 ABI 约 +7–9 MB | 可接受（现包 64.6 MB） |
| 模型权重（Q4_K_M） | Qwen2.5-1.5B **1066 MB** / Qwen3-1.7B 1056 MB / Gemma-3-1B 769 MB | **绝不进 APK**，是用户可选资产 |
| 端上速度 | 生成 7.4 tok/s、**首 token 3.5–5.1 s**（177 token 上下文） | 只够「一段话解释」，不够聊天 |

而 `Prompt.md` 阶段二的 7 个示例问题里，**6 个本质是算术/统计**（本月多少、某分类多少、预算剩多少、
哪类涨最多、多久攒够钱）。这些**不该让模型算**——基准实测里模型会编数（Gemma 把「已花 4520.36」
说成「超支 4520.36」；Qwen2.5 超支额对、每日额度编）。

⇒ 所以 M1 = **用规则 + 账本计算回答**，零体积、零等待、算得准；M2 再让可选模型只做「措辞」。
这也让「不装模型」的用户拿到 100% 的功能，而不是一个「残废版」。

## 2. 架构（三层，模型是可选组件）

```
用户一句话
   │
   ├─ T0（默认，M1 已交付）
   │    parseFinanceIntent（纯函数：选区间 + 选口径）
   │      → TransactionRepository.listByRange / BudgetRepository.getForMonth
   │      → 既有口径纯函数：summarize / categoryBreakdown / buildBudgetView
   │      → 中文回答（模板）
   │
   ├─ T1（M2，可选安装 .gguf）
   │    FinanceData → 事实清单（≤80 token）→ LlmProvider（llama.cpp JNI，流式）
   │      → 模型只把事实改写成话；**回答里的数字必须能对上事实清单**，否则丢弃重来
   │
   └─ T2（暂不做）
        云端，用户显式开启；关闭后本地功能不受影响
```

**红线**（沿用 HANDOFF 不变量）：

1. **数字只有一个来源**：Dart 纯函数。模型不参与任何计算，OCR / 模型都不写库；
2. **不装模型也能用**：T0 是默认路径，不是降级路径；
3. **不认识就说不认识**：绝不生成没查过的金额。

## 3. M1 交付（文件级）

| 文件 | 作用 |
|---|---|
| `lib/features/assistant/application/finance_intent.dart` | 一句话 → 意图（7 类）+ 时间区间 `Period`；中文数字归一；分类别名 |
| `lib/features/assistant/application/finance_answer.dart` | 意图 + 数据 → 中文回答（标题 / 主数字 / 事实行 / 叙述 / 追问建议）；`kExampleQuestions` |
| `lib/features/assistant/application/assistant_controller.dart` | Riverpod 会话编排：解析 → 查库（`listByRange` / `getForMonth`）→ 出答案 |
| `lib/features/assistant/presentation/assistant_page.dart` | 问答页：空态示例 chips、问题气泡、答案卡、事实行、追问 chips、输入栏 |
| `lib/app.dart` | `+ GoRoute('/assistant')` |
| `lib/features/profile/presentation/profile_page.dart` | 「我的 → 问账本」入口 |
| `test/features/assistant/finance_intent_test.dart`（22 例） | 区间口径 / 优先级 / 别名 / 储蓄 / 不认识 |
| `test/features/assistant/finance_answer_test.dart`（16 例） | 金额、占比、笔数、预算超支、环比、大额、储蓄、空数据 |
| `test/features/assistant/assistant_controller_test.dart`（6 例） | 内存库端到端、空问题、未知问题、连续追问、清空 |
| `test/features/assistant/assistant_page_test.dart`（4 例，含深色主题） | 点示例 → 出答案卡；打字问未知 → 明说不会；清空 |

**没动的**：`lib/core/db/**`（schema 仍 v3）、`pubspec.yaml`（零新增依赖）、`android/**`（零权限变更）、
任何写库路径（M1 只读）。

## 4. 口径（写死，改之前先看测试）

| 项 | 口径 |
|---|---|
| 时间 | 区间一律**本地时区、半开 `[start, end)`**；回答里必须写出实际区间（「近 30 天（9月26日–10月25日）」） |
| 「这个月 / 本月」 | 当前自然月；「上个月」跨年安全；只说「10 月」→ 不晚于当前月算今年，否则去年 |
| 「最近一个月」 | **滚动 30 天**（不是上月）；「最近三个月」→ 含本月共 3 个自然月 |
| 汇总 | `summarize`（transfer 不计收支）；主数字按问的方向（问收入给收入） |
| 分类 | `categoryBreakdown` + `(kind, name)` 双元组；别名只在**该分类真实存在**时生效 |
| 预算 | `buildBudgetView`（超支时每日可花为 0 的逻辑沿用既有口径） |
| 对比 | `current` vs `previous`；上期无数据 → 明说「没法比较」，不拿 0 当基数 |
| 大额 | 用户没说时间 → 近 90 天；按金额降序取前 5 |
| 储蓄 | 纯算术，向上取整；明说「不含利息」 |
| 没有数据 | 一律「这段时间没有记账记录 / 没有某分类记录」，**不返回 ¥0.00 结论** |
| 不认识 | 返回示例问题，不猜 |

## 5. 验收（对齐 `Prompt.md` 阶段二 §6）

| # | 要求 | 本批状态 | 判定方式 |
|---|---|---|---|
| 1 | 可以用自然语言提问 | ✅ | 示例 chips + 自由输入；`assistant_page_test` |
| 2 | 回答来自真实财务数据 | ✅ | 控制器查 `listByRange`；`assistant_controller_test` 断言金额 |
| 3 | 金额和统计由业务代码计算 | ✅ | 只调 `summarize` / `categoryBreakdown` / `buildBudgetView`，模板层不做新算术 |
| 4 | 支持月度汇总、分类支出、预算查询、趋势比较 | ✅ | 4 类意图各有测试；另有「大额」「储蓄」两类 |
| 5 | 模型未安装 / 推理失败时有清晰提示 | ⏳ M2 | M1 页脚已写明「现在是规则+账本计算，模型是后续可选」 |
| 6 | 离线时功能正常 | ✅ | 全链路无网络调用；release 包无 `INTERNET`（未改动清单） |
| 7 | 不会偷偷切云端 | ✅ | 代码里没有任何网络依赖 |
| 8 | 关键查询有单测与集成测试 | ✅ | 48 例（22 + 16 + 6 + 4） |

**门禁实测（2026-10-27，本机）**：`flutter analyze` → **No issues found!**；
`flutter test --concurrency=1` → **636 passed / 6 skipped / 0 failed**（基线 588，本批 **+48**）。

## 6. 已知限制（M1 的边界，别对外承诺）

| # | 限制 | 说明 |
|---|---|---|
| 1 | **只认账本里的数**，不做开放式对话 | 问「我该不该买」一律回「还没学会」+ 示例 |
| 2 | 意图是**规则**，句式超出词表就答不上 | 现在覆盖 7 类；词表在 `finance_intent.dart`，加一句测试就能扩 |
| 3 | 不认识「跨账本 / 多账户余额」类问题 | 账户余额查询（`buildAssetSummary`）留到下一批 |
| 4 | 不记住上下文 | 「那上个月呢」这种指代不支持，每句都要说全（模型进来后由 M2 的会话层解决） |
| 5 | 金额解析只到「元」，不认「两千」这类中文金额 | 宁可让用户重问，也不猜错数 |
| 6 | 深色已切过一次、页面能渲染，但**颜色对比度没有人工目视确认**（本轮无视觉通道，只抽样了像素） | 颜色全走 `context.toon`；对比度由 `palette_contrast_test` 兜底 |

## 7. 真机走查（2026-10-27 · MuMu 12 / Android 12 / 900×1600 @320dpi）

**用真实账单跑通了整条链路**：把用户提供的 Download/weixin-bill.xlsx（微信支付账单，161 行、
2026-08-29–09-29）从「我的 → 导入账单」导入（**153 笔入库 / 跳过 8 笔**），再从「我的 → 问账本」逐一提问。

| # | 用例 | 结果（界面原文） | 核对 |
|---|---|---|---|
| 1 | 这个月花了多少 | 「2026年9月支出 **¥2,040.80**，收入 ¥241.90，结余 ¥-1,798.90。花得最多的是「居住」¥719.34，占 35.2%；其次是「餐饮」¥716.37。」 | ✅ 与首页 hero（2040.80 / 241.90 / -1798.90）一致；与 DB 聚合一致 |
| 2 | 这个月餐饮花了多少 | 「2026年9月「餐饮」支出 **¥716.37**，共 **54 笔**，占该期全部支出的 35.1%。」 | ✅ 分类占比与 #1 的「其次餐饮」互相印证 |
| 3 | 本月预算还剩多少 | 「2026年9月还没设预算（首页「本月预算」卡片可以设）。目前已经花了 ¥2,040.80。」 | ✅ 未设预算时不编数字 |
| 4 | 这个月为什么比上个月多 | 「…多 ¥1,976.23（+3060.6%）…**注意：2026年8月 只有 3 天有记录、2026年9月 有 28 天，直接比总额会放大差距；按每天算分别是 ¥21.52 和 ¥72.89。**」 | ✅ 见下方「走查发现 ①」 |
| 5 | 最近有哪些大额支出 | 「近 90 天（7月2日–9月29日）支出 ¥2,105.37，金额最大的 5 笔合计 ¥925.40，占 44.0%…」 | ✅ 2105.37 = DB 全部支出（含 8 月 6 笔 64.57） |
| 6 | 打一句无关的（hello） | 「这个我还没学会」+ 5 个示例问题 | ✅ 不瞎答 |
| 7 | 深色主题下再问一遍 | 页面正常渲染、答案一致 | ✅ 截图像素：页面底色 #26242F、底栏 #1E1C25（深色生效）；对比度靠调色板守护测试 |

### 走查发现（都已处理或记录）

1. **【已修】「不完整月份 vs 完整月份」会误导**：账单只导出了 8/29–9/29，8 月只有 3 天有记录，
   「为什么比上个月多」直接给「+3060.6%」，数字没错但结论荒唐（正是 Prompt.md §3 明确要求避免的）。
   修法（inance_answer.dart）：用**数据本身的天数跨度**判断两期是否可比（差 1.6 倍以上即视为不平衡），
   不平衡时补「日均（N 天）」两行事实 + 一句「直接比总额会放大差距」；回归测试见
   inance_answer_test.dart「一期数据不完整」。
2. **【记录】导入跳过的 8 笔是微信「中性交易」**：账单头部写「支出 153 笔 2183.88 元 / 收入 8 笔 320.41 元」，
   而 App 里是「149 笔 2105.37 / 4 笔 241.90」——两边都差 **78.51 元**（一笔转账的两侧）。
   这是导入按 PRD 跳过中性交易的**预期行为**，但用户对着账单头部会疑惑 →
   已记入内部交接文档的 open-issues（不入库）；对应修复见 `CHANGELOG` v0.8.4。
3. **【记录】分类规则在真实数据上有偏差**：「手机充值-中国联通」被判成**居住**、「抖音生活服务」落**其他**、
   「发给…青年旅社」被判成**交通**。属 category_rules.dart 的问题（不是 M1），已记入 open-issues。
4. **【工程】uiautomator 的坑**：dump 偶发返回 `null root node`，此时若直接读上一次的文件，
   会拿**旧界面**当当前状态判断（本轮真踩到，误以为改代码没生效）。
   `tool/ui_mumu.ps1` 已改为：先删旧文件 → dump 后校验非空 → 最多重试 3 次，失败直接抛错。

## 8. 首页改版：记一笔 / 问一句（2026-10-28）

> 用户要求：「截图记账和问账本不要放在『我的』，把首页的『本月预算』部件替换掉；
> 两个功能集成成一个聊天框，能发文字也能发账单图片。」两个取舍当场拍板：
> **① 首页放入口卡、点开发送后进全屏聊天**；**② 预算降级成 hero 下方一行**。

### 8.1 形态

```
首页：hero（本月支出）→ 预算一行条 → [记一笔 / 问一句] 入口卡 → 本月账单
「我的」：删掉「截图记账」「问账本」两行
入口卡：假输入框（整条可点）+ 📷（直接弹相册）+ 3 个示例 chip
聊天页 /chat：消息流（文字问答卡 / 待确认账单卡 / 结果与提示）+ 底部「📷 + 输入框 + 发送」
```

### 8.2 文件级改动

| 类型 | 文件 |
|---|---|
| 新增 | `features/chat/application/{answer_question,chat_controller}.dart`、`presentation/chat_page.dart`、`presentation/widgets/{chat_bubbles,receipt_card,chat_entry_card}.dart`、`ledger/presentation/widgets/budget_strip.dart` |
| 删除 | `assistant/presentation/assistant_page.dart`、`assistant/application/assistant_controller.dart`、`receipt/presentation/receipt_page.dart`、`receipt/presentation/widgets/receipt_bits.dart`、`ledger/presentation/widgets/budget_card.dart` |
| 修改 | `app.dart`（`/chat` 取代 `/assistant`、`/receipt`）、`home_page.dart`（预算条 + 入口卡）、`profile_page.dart`（删两行） |

**没动的**：`feature/receipt/{data,application}`（OCR / 解析 / `writeReceipt` / 指纹去重）、
`finance_intent` / `finance_answer` 纯函数、`TransactionRepository`、schema v3、零新依赖。

### 8.3 口径与不变量（沿用）

- 图片记账仍是 **OCR → `parseReceipt` → 用户确认 → `importTransaction(source:'screenshot')`**，
  代码里没有第二条写库路径；识别结果只是「待确认卡」，**不确认不写库**；
- 写后刷新只调 `refreshAfterWrite(ref)`（HANDOFF 不变量 #9）；
- 文字问答口径与 §4 完全一致（区间半开、写清区间、没数据就说没数据、不认识给示例）。

### 8.4 踩到并修掉的坑

`sendImage` 里最初写的是 `ref.read(categoriesProvider).value ?? []` —— **首次读时 `AsyncValue.value` 还是 null**，
分类/账户永远为空 → 卡片显示「请选择分类」，点确认永远失败。改 `await ref.read(...future)` 后正常。
（测试 `chat_controller_test`「识别成功 → 确认后写库」就是这条的回归。）

### 8.5 验收（本批）

| # | 项 | 状态 |
|---|---|---|
| 1 | 首页顺序 hero → 预算一行 → 入口卡 → 账单列表 | ✅ 测试 + 走查 |
| 2 | 「我的」无两个入口 | ✅ |
| 3 | 聊天里文字问答与 M1 一致 | ✅ `chat_controller_test` / `chat_page_test` |
| 4 | 发图 → 待确认卡 → 确认写库；重复/失败不写库 | ✅ 9 例图片用例 |
| 5 | 预算可看可改（口径未变） | ✅ `budget_strip_test` 4 例 |
| 6 | `analyze` 0 issue / 全量测试绿 | ✅ 638 passed / 6 skipped |

## 9. 下一步

1. **M2**：`LlmProvider` 抽象 + llama.cpp JNI（arm64 / `dotprod` / 线程绑大核 / 流式 / 取消）+
   `.gguf` 手动导入（`getExternalFilesDir('models')` + sha256 校验）+ 设备内存门槛与降级；
2. **M3**：可选下载器（独立 flavor）、多模型管理、性能与隐私说明。
