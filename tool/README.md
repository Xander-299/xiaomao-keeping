# `tool/` 开发工具链

这里的脚本是**正式工具**，不是临时补丁。按用途分四类：

## 1. 门禁（等价于 `flutter analyze` / `flutter test`）

某些环境里 Dart 起不了「需要管道 stdio」的子进程（Windows 上表现为
`CreateFile failed 231` + `process_win.cc:744`），`flutter analyze / test / pub / build_runner`
会全体失效。这三个脚本用 Python 直接驱动底层产物，把门禁保住：

| 脚本 | 等价于 | 备注 |
|---|---|---|
| `dart_analyze_fallback.py` | `flutter analyze` | 起 `analysis_server_aot.dart.snapshot` + Dart 原生协议；含全部 lint |
| `dart_test_fallback.py` | `flutter test` | **只跑纯 `test()`**，`testWidgets` 跑不了（需要真正的 test 运行器驱动帧） |
| `build_kernel_fallback.py` | `flutter assemble` 的 kernel 步骤 | 产物配合 `./gradlew assembleDebug -x compileFlutterBuildDebug` 出 APK |

> ⚠️ 本机脚本的结果**不能当最终判据**：`testWidgets` 与真机行为必须由 `flutter test` /
> CI / 真机走查覆盖。CI 上跑的是标准命令。

## 2. 装机与发布

| 脚本 | 用途 |
|---|---|
| `install_device.ps1` | **一条命令出包 + 核验 + 装机 + 启动**（PowerShell）：临时改 gradle.properties（内存 / `qaAppId`）并**按字节还原**、核验包名/版本/签名/文案、`adb install`（debug 自动 `-t`、降级自动 `-d`）。`-Serial` 真机 / `-Qa` 并列包名 / `-Mode release` |
| `verify_apk_kernel.py` | **装机前必跑**：比对 APK 内 `kernel_blob.bin` 与盘上的 sha256，并 grep 本次新增文案 —— 防止「装到上一版」而误判「改了没用」 |
| `publish_release.py` | 走 GitHub REST API 发 Release；令牌从 git credential manager 现场取，不落盘 |

## 3. 设备调试 / 走查

| 脚本 | 用途 |
|---|---|
| `ui_dump.py` | 抓 Android 无障碍语义树，输出可点节点与坐标；adb 路径自动探测（`ADB` 环境变量可覆盖） |
| `parse_notif_dump.py` | 解析 `dumpsys notification` 输出，定位支付通知的包名 / 文案 |
| `watch_notifications.py` | 轮询观察通知存活时长（实测支付通知只活 ~26 秒） |
| `probe_notify_lifecycle.py` | 通知生命周期取证（发布 → 撤回 → `getActiveNotifications()` 是否还捞得到） |

走查方法见 [`docs/dev/android-ui-smoke.md`](../docs/dev/android-ui-smoke.md)。

## 4. 资源与配置校验

| 脚本 | 用途 |
|---|---|
| `gen_launcher_icons.py` | 由源图生成 adaptive icon 的前景图（透明底 + 66% 安全区） |
| `inspect_icons.py` | 检查生成后的图标尺寸 / 安全区 / 底色 |
| `png_util.py` | 纯标准库 PNG 读写（本环境 pip 不通外网，无法用 Pillow） |
| `check_pubspec.py` | `pubspec.yaml` / `pubspec.lock` 一致性体检（YAML 卫生、构建期工具是否误入 dependencies 等） |

## 5. 数据层探针

| 脚本 | 用途 |
|---|---|
| `data_layer_probe.dart` / `data_layer_probe.py` | 让数据层脱离 Flutter 真跑（复制 `lib/` 到临时包 + 内存库），用于快速验证仓储 SQL |
| `export_probe.dart` | 导出逻辑（CSV / JSON 备份）的真跑探针 |

## `keystore_to_base64.ps1`

把正式签名 keystore 转成 base64，用于配置 CD 的 `ANDROID_KEYSTORE_BASE64` secret
（`.github/workflows/release.yml`）。输出等于签名凭据，只粘进 GitHub secret，别落盘、别贴聊天。
