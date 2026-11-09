# v0.8.3 真机验收记录（A+B+C + P2-1）

> 验收对象：`v0.8.3`（tag 指向 `2f2c6d6`）· 安装包 `yanxin-v0.8.3-universal-release.apk`
> 验收日期：2026-11-09 · 设备：Redmi 22041211AC（K50）· Android 14（SDK 34）

## 1. 安装包

| 项 | 值 |
|---|---|
| 文件 | `yanxin-v0.8.3-universal-release.apk`（68,983,270 字节 / 65.8 MB） |
| SHA-256 | `dddf6bad3db49556e501ba6be126eabfae3e06822f50264cb5241b32be4c1c74` |
| 包名 | `com.teacodeman.yanxin` |
| 版本 | versionName **0.8.3** · versionCode **2003**（minSdk 24 / targetSdk 36） |
| ABI | `arm64-v8a` + `armeabi-v7a` |
| 签名 | `CN=yanxin`，证书 SHA-256 `d46b65a4…e86567` —— 与 v0.8.2 **同一把 upload key** |
| 构建 | master `2f2c6d6` · Flutter 3.47.2 · JDK 17 · `flutter build apk --release` |

### 1.1 ⚠️ 首次上传的包不可用（已修复并替换）

首版资产的 SHA-256 为 `5b857ab8…de5d`（65,321,460 字节）。真机安装后**所有页面白屏**，`adb logcat -s flutter` 给出：

```
MissingPluginException(No implementation found for method doesnt_matter
  on channel sqlite3_flutter_libs)
  at applyWorkaroundToOpenSqlite3OnOldAndroidVersions
  at driftDatabase (drift_flutter/src/native.dart:60)
```

**根因**：构建时使用了 `--no-pub` + 手工拷贝的 `.dart_tool`，worktree 里没有 `.flutter-plugins-dependencies`，
生成的插件注册表为空 → `sqlite3_flutter_libs` 未注册 → 数据库打不开 → 全站白屏。

**修复**：在构建 worktree 内先 `flutter pub get`（生成插件依赖清单）再 `flutter build apk --release`；
新包包含 `lib/arm64-v8a/libsqlite3.so`（1.5 MB，旧包缺失）。发布资产已替换为上表 SHA-256。

## 2. 安装过程

设备原有 `0.7.16`（**versionCode 4001**），v0.8.3 的 `2003` 属降级：

- `adb install -r` → `INSTALL_FAILED_VERSION_DOWNGRADE`
- `adb install -r -d` → **同样被 MIUI 拒绝**（系统级限制，`-d` 不生效）

经用户确认后「卸载旧版 → 全新安装」：

| 步骤 | 结果 |
|---|---|
| `adb uninstall com.teacodeman.yanxin` | Success（**旧版本地账本随之清除，用户已知悉**） |
| 安装首版（坏包） | Success，但启动后全站白屏（见 1.1） |
| 安装重建版（`adb install -r`） | **Success** |
| `dumpsys package` | `versionName=0.8.3` · `versionCode=2003` ✅ |

## 3. 冒烟结果（重建版，OCR 取证）

| # | 项目 | 方法 | 结果 |
|---|---|---|---|
| 1 | 冷启动 | `monkey -p com.teacodeman.yanxin -c LAUNCHER 1` + `mCurrentFocus` | ✅ `MainActivity` 前台 |
| 2 | 插件/数据库 | `logcat -s flutter` | ✅ **无 `MissingPluginException`**，仅 Impeller 初始化日志 |
| 3 | 引导页 | 截图 + Windows OCR | ✅ 「认识一下小耄记账 / 下一步 / 跳过」正常渲染 |
| 4 | 首页 | 跳过引导后 OCR | ✅ 「默认账本 · 11月 · 支出 ¥0.00 · 收入 0.00」 |
| 5 | 记一笔页 | 点底栏中央 FAB，OCR | ✅ 金额键盘（2/5/8/0）、分类 / 日期 / 备注 / 账户 全部出现 |
| 6 | 选分类 | 点「请选择分类」→ 选「工资」 | ✅ 弹层出现收入分类（工资 / 退款 / 奖金 / 红包 / 礼金） |
| 7 | 保存并回显 | 输入 `1234`（¥12.34）→ 保存 | ✅ 首页显示「收入 ¥12.34 · 结余 ¥12.34」 |
| 8 | 崩溃 | `logcat -b crash -d` | ✅ **0 条** |

> 取证方式：`screencap` + Windows `Windows.Media.Ocr`（zh-Hans-CN）逐词识别并给出坐标，按坐标点击。
> 早期一版报告里的「四个 tab 切换」结论作废——那几次点击落在手势区/引导页，并不是真实页面切换，本版已删除该结论。

## 4. 未覆盖 / 待人工确认

- **四个底部 tab 的逐页断言**：未做（点击坐标受手势区影响，OCR 未逐页取证）；仅确认首页与记一笔页。
- **UI 视觉细节**：OCR 只能取文本，配色/间距/图标需人工复看（截图见 `shots/v083/`）。
- **自动记账**：通知使用权、回执通知、批量撤销未验证（需真实支付通知）。
- **导入 / 导出 / 多账本**：未构造数据；A1 跨账本指纹、A2 恢复校验仅由单元测试覆盖。
- **Golden**：本版不含 Golden 基线，未生成、未比对（不适用于真机验收）。

## 5. 结论

重建后的 v0.8.3 在真机上可正常启动、建库、进入首页、完成一次记一笔并回显，0 崩溃；
发布资产已替换为可用包。**首版资产白屏是构建流程缺陷（漏 `flutter pub get`）导致，不是业务代码回归**，
后续出包必须确认 APK 内含 `libsqlite3.so` 且构建前生成过 `.flutter-plugins-dependencies`。

## 6. 截图（本机 `shots/v083/`，已被 `.gitignore` 排除）

`f1_home.png`（含白屏期）、`g2.png`（首页）、`r3.png`（记一笔）、`r5.png`（分类弹层）、`s2.png`（保存后首页）
