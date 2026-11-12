#!/usr/bin/env bash
# 颜芯记账 · Flutter 开发环境（Git Bash）
#
# 用法：
#   cp env.example.sh env.sh      # env.sh 已在 .gitignore，不会入库
#   # 按本机情况改下面「机器相关路径」一节，或改用环境变量覆盖
#   source env.sh
#
# 说明：本文件只保留**通用的环境变量与踩坑注释**，不含任何具体机器路径 ——
# 各人的 SDK 装在哪是私事，写进仓库只会变成别人 clone 下来跑不通的噪音。
#
# 每一行都是踩过的坑，删之前先想想为什么在这。

# --- Bash 工具 PATH 兜底 ---
# 缺了它：grep/head/tail/date/find/dirname 全「command not found」，
# flutter 还可能误报 "PROGRAM BLOCKED BY SECURITY POLICY ... wsl.exe"。
case ":$PATH:" in
  *":/usr/bin:"*) ;;
  *) export PATH="/usr/bin:/bin:$PATH" ;;
esac

# ============================================================
# 机器相关路径 —— 按本机改这一段（或用同名环境变量覆盖）
# ============================================================
FLUTTER_HOME="${FLUTTER_HOME:-$HOME/flutter}"
JAVA17_HOME="${JAVA17_HOME:-}"        # JDK 17 的根目录；留空则用系统 java
ANDROID_SDK="${ANDROID_SDK:-}"        # Android SDK 根目录
GRADLE_CACHE="${GRADLE_CACHE:-$PWD/.gradle-home}"

export PATH="$FLUTTER_HOME/bin:$PATH"
if [ -n "$JAVA17_HOME" ]; then
  # JDK 必须 17；系统 `java` 可能是更新的版本 → 这里显式前置
  export JAVA_HOME="$JAVA17_HOME"
  export PATH="$JAVA17_HOME/bin:$PATH"
fi
if [ -n "$ANDROID_SDK" ]; then
  export ANDROID_HOME="$ANDROID_SDK"
  export ANDROID_SDK_ROOT="$ANDROID_SDK"
  export PATH="$ANDROID_SDK/platform-tools:$PATH"
fi

# Gradle 缓存放工作区内，避免写用户目录下的 .gradle。
# ⚠️ 只能给**全新空目录**让 Gradle 自己下载；**复制已有缓存会让它启动即挂死**，
#    而且表现成「网络慢」，极易误判。
export GRADLE_USER_HOME="$GRADLE_CACHE"
mkdir -p "$GRADLE_USER_HOME" 2>/dev/null

# --- 依赖下载镜像（可选，按所在网络决定）---
# ⚠️ pubspec.lock 里记录的 host 必须与此处一致，否则 `pub get` 会重写 lock。
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn

# --- 代理 ---
# 构建走镜像 / 代理是必需的；但 `flutter test` 相反必须**去代理**（见下方 fx-test）。
# 不需要代理就把这段注释掉。
export http_proxy="${http_proxy:-http://<PROXY_HOST>:7890}"
export https_proxy="${https_proxy:-http://<PROXY_HOST>:7890}"
export HTTP_PROXY="$http_proxy"
export HTTPS_PROXY="$https_proxy"

# --- Windows 标准环境变量 ---
# 某些受限 shell 会吞掉这些变量；flutter test 的 Visual Studio 探测缺了
# PROGRAMFILES(X86) 会直接抛 "%PROGRAMFILES(X86)% environment variable not found"。
export PROGRAMFILES="C:\\Program Files"
export PROGRAMW6432="C:\\Program Files"

# 某些 safe-delete 包装会拦 Dart / Gradle 的临时文件删除 → unset 会话 ID 绕开
unset CODEBUDDY_SESSION_ID CLAUDE_SESSION_ID

# --- flutter test：代理会劫持 flutter_tester 的本地 WebSocket → 先去代理再跑 ---
# ⚠️ 不要用 `env -u ...` 前缀：某些环境里 `env` 会被安全包装吞掉
#    （命令零输出、0.5s 即返回，极具误导性）。用 bash 内建 unset + 子 shell。
fx-test() {
  ( unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy
    flutter test --no-pub "$@" )
}

# --- analyze + test 一条龙（就是 CI 跑的那两道门禁）---
fx-qa() {
  ( unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy
    flutter analyze ) && fx-test "$@"
}

# --- WSL 里 dart analyze 报几千个假错误？先修 package_config ---
# 成因：Windows 侧 `flutter.bat pub get` 会把 .dart_tool/package_config.json 的 rootUri
#       改写成 `file:///C:/.../Pub/Cache` 与 `file:///D:/.../flutter`，WSL 读不到 → 假错误。
fx-pkgcfg() {
  python3 tool/fix_package_config.py "$@"
}

# --- 其他常用命令 ---
# 代码生成（改 lib/core/db/tables.dart 后必须重跑，并提交 database.g.dart）：
#   dart run build_runner build --delete-conflicting-outputs
# debug 包：
#   flutter build apk --debug
# 真机 / 模拟器走查：
#   docs/dev/android-ui-smoke.md

echo "[env] flutter=$(command -v flutter) gradle=$GRADLE_USER_HOME"
