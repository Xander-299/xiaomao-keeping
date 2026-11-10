# AGENTS.md — Agent 规则入口（指针文件）

> 本文件**不承载规则**，只做指针。所有实质约定都在下面三个入口里，以它们为准。

## 接手必读（按顺序）

1. **[`HANDOFF.md`](HANDOFF.md)** —— 唯一接手入口：现状、硬约束、**10 条不变量**、坑清单、目录导航。
   干活前先通读一遍；改完代码把变化回写进去。
2. **[`docs/spec/`](docs/spec/)** —— 需求流程：功能改动先有 SPEC（命名 `SPEC-F7.<n>-<slug>.md`，
   编号看 [`docs/PRD-yanxin-flutter.md`](docs/PRD-yanxin-flutter.md) 的 FR 表）；用户下发的任务书原文
   **必须先存档进 [`docs/spec/prompts/`](docs/spec/prompts/)** 再被 SPEC 引用。
3. **[`docs/handoff/`](docs/handoff/)** —— 过程知识：踩坑（pitfalls）、决策参考（reference）、
   未决问题（open-issues）、历史（history / status-log / session-log）。

## 三条最容易踩的本地约定（详情都在 HANDOFF）

- 本机跑测试**必须** `flutter test --concurrency=1`（否则 OOM）；
- 出 QA 包要临时改 `android/gradle.properties`（降内存 + `qaAppId`），构建后**按字节还原**（`git diff android/` 为空）；
- 根目录 `Prompt.md` 是**临时提示词暂存位**，会被下一次任务覆盖 —— 不是规则，也不要引用它。

## 门禁

`flutter analyze` 0 issue + `flutter test` 全绿（CI 自动跑，见 `.github/workflows/ci.yml`）。

## 🔁 卡住不许死磕：重复调用上限（硬规则）

**同一种工具调用（同命令 / 同参数）连续失败或空转 5 次以上，必须停手换思路。**

1. **停**：不要再发第 6 次同样的调用。重试超过 5 次不叫坚持，叫掩盖问题。
2. **查**：先查明阻塞的**真实原因**（网络？沙箱权限？Flutter SDK 缓存只读？GitHub 侧 job 没建起来？
   依赖路径被改写？），拿到证据（错误码、日志、`git status`、`gh api` 返回的原始 JSON）。
3. **写**：把「现象 → 根因 → 绕法/结论」记进 [`docs/handoff/open-issues.md`](docs/handoff/open-issues.md)；
   若是环境性坑（本机跑不了 / 只能走 CI / 需要某条命令），同步补进 `HANDOFF.md` 的坑清单。
4. **改道**：换一条路验证（改看 CI 结果、换 `dart analyze` 代 `flutter analyze`、换 windows 侧执行、
   换等价命令），或明确把这一项标为**环境阻塞**上报用户，不要伪装成"还在跑"。
5. **上报**：给用户的结论里写清「哪一步没做成、为什么、已确认到什么程度」，
   不许用"网络问题"之类没证据的说法搪塞。

> 适用对象包括但不限于：`flutter test` / `flutter analyze` / `gh` / `curl` / 构建命令 / 文件读写。
> 只要一轮对话里发现自己要发第 6 次几乎相同的调用，立刻执行上面的 1→5。
