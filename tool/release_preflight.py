#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""发布前物检：APK 里「必须有」的东西是不是都在。

## 为什么需要它

2026-11-09 的 v0.8.3 首包：构建用了 `--no-pub` 且 worktree 里没有
`.flutter-plugins-dependencies`，插件注册表为空 → `sqlite3_flutter_libs`
没注册 → 数据库打不开 → **装上去能启动，但所有页面白屏**。
`adb install` 是 Success，签名/版本也全对 —— 所以这些检查必须前置到发布流程。

## 检查项

1. APK 是个正常的 zip，且**每个 ABI 目录**里都有 `libflutter.so` / `libapp.so` /
   `libsqlite3.so`（缺 sqlite 就是白屏）；
2. 项目根目录存在 `.flutter-plugins-dependencies`，且 android 插件列表非空
   （`--no-pub` 构建时最容易漏掉它）；
3. 包内 `versionName` / `versionCode` 与 `pubspec.yaml` 一致（需要 aapt/aapt2）；
4. release 包的签名证书 SHA-256 等于 upload key（需要 apksigner；CI 无 keystore 时用
   `--skip-signature`）。

找不到 aapt / apksigner 时**降级为 WARN**而不是 FAIL —— 本地 Linux 机器常常没有
Android build-tools，硬失败会让人直接绕过这道闸门。

用法：
    python tool/release_preflight.py --apk build/app/outputs/flutter-apk/app-release.apk
    python tool/release_preflight.py --apk app-release.apk --skip-signature   # CI
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent

# upload key 的证书指纹（CN=yanxin）；换签名时同步改这里
DEFAULT_CERT_SHA256 = (
    "d46b65a43bcfc6633f5460fb893b6b6e55db66ae16ac650054fb085698e86567"
)

# 每个 ABI 目录都必须有这三个库；libsqlite3.so 缺了 = 运行期白屏
REQUIRED_LIBS = ("libflutter.so", "libapp.so", "libsqlite3.so")


class Report:
    def __init__(self) -> None:
        self.failed = 0
        self.warned = 0

    def ok(self, msg: str) -> None:
        print(f"[ OK ] {msg}")

    def warn(self, msg: str) -> None:
        self.warned += 1
        print(f"[WARN] {msg}")

    def fail(self, msg: str) -> None:
        self.failed += 1
        print(f"[FAIL] {msg}")


def run(cmd: list[str]) -> str:
    """跑外部工具，统一吞掉编码差异（Windows 上是 GBK 控制台）。"""
    try:
        out = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=180,
        )
    except (OSError, subprocess.SubprocessError) as exc:  # pragma: no cover
        return f"<error: {exc}>"
    return (out.stdout or "") + (out.stderr or "")


def find_tool(name: str, explicit: str | None) -> str | None:
    """在 --xxx / ANDROID_HOME/build-tools/* / PATH 里找可执行文件。"""
    if explicit:
        p = Path(explicit)
        return str(p) if p.exists() else None

    for env in ("ANDROID_HOME", "ANDROID_SDK_ROOT"):
        root = os.environ.get(env)
        if not root:
            continue
        build_tools = Path(root) / "build-tools"
        if not build_tools.is_dir():
            continue
        for ver in sorted(build_tools.iterdir(), reverse=True):
            for suffix in ("", ".exe", ".bat"):
                cand = ver / f"{name}{suffix}"
                if cand.exists():
                    return str(cand)

    for suffix in ("", ".exe", ".bat"):
        found = shutil.which(f"{name}{suffix}")
        if found:
            return found
    return None


def tool_cmd(tool: str, *args: str) -> list[str]:
    # Windows 的 .bat 必须经 cmd /c 才能拿到输出
    if tool.lower().endswith(".bat"):
        return ["cmd", "/c", tool, *args]
    return [tool, *args]


def check_zip(apk: Path, report: Report) -> None:
    try:
        with zipfile.ZipFile(apk) as zf:
            names = zf.namelist()
    except (OSError, zipfile.BadZipFile) as exc:
        report.fail(f"APK 打不开（不是 zip）：{exc}")
        return

    report.ok(f"APK 是合法 zip（{len(names)} 个条目）")

    abi_dirs = sorted(
        {Path(n).parts[1] for n in names if n.startswith("lib/") and n.count("/") >= 2}
    )
    if not abi_dirs:
        report.fail("APK 里没有任何 lib/<abi>/ 目录 —— 这不是一个可用的 Flutter 包")
        return

    # 用 --target-platform 只打一个 ABI 时，插件仍可能往别的 ABI 目录塞少量 .so
    # （例如 jni / sqlite 的预编译库）。真正的「出包 ABI」= 带 libflutter.so 的那几个。
    def libs_of(abi: str) -> set[str]:
        return {Path(n).name for n in names if n.startswith(f"lib/{abi}/")}

    flutter_abis = [abi for abi in abi_dirs if "libflutter.so" in libs_of(abi)]
    if not flutter_abis:
        report.fail(
            "没有任何 ABI 带 libflutter.so —— 这不是一个可运行的 Flutter 包"
            f"（现有目录：{', '.join(abi_dirs)}）"
        )
        return
    report.ok(f"出包 ABI：{', '.join(flutter_abis)}")

    ignored = [abi for abi in abi_dirs if abi not in flutter_abis]
    if ignored:
        report.warn(
            f"{', '.join(ignored)} 只有插件库、没有 Flutter 引擎（大概率是 --target-platform 裁剪），不计入检查"
        )

    for abi in flutter_abis:
        present = libs_of(abi)
        missing = [lib for lib in REQUIRED_LIBS if lib not in present]
        if missing:
            hint = "（libsqlite3.so 缺失 = 装得上但所有页面白屏）" if "libsqlite3.so" in missing else ""
            report.fail(f"{abi} 缺少 {', '.join(missing)}{hint}")
        else:
            report.ok(f"{abi} 三个核心库齐全（含 libsqlite3.so）")


def check_plugins(project: Path, report: Report) -> None:
    manifest = project / ".flutter-plugins-dependencies"
    if not manifest.exists():
        report.fail(
            "项目根缺 .flutter-plugins-dependencies —— "
            "多半是用了 --no-pub 且没先跑 flutter pub get；"
            "这样构建出来的包不会注册任何插件（白屏高发）"
        )
        return
    try:
        data = json.loads(manifest.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        report.fail(f".flutter-plugins-dependencies 读不了：{exc}")
        return

    android = (data.get("plugins") or {}).get("android") or []
    if not android:
        report.fail(".flutter-plugins-dependencies 里 android 插件为空 —— 插件注册表会是空的")
        return
    names = sorted({p.get("name", "?") for p in android if isinstance(p, dict)})
    report.ok(f"android 插件 {len(names)} 个：{', '.join(names[:6])}{' …' if len(names) > 6 else ''}")


def parse_pubspec(project: Path) -> tuple[str, str] | None:
    pubspec = project / "pubspec.yaml"
    if not pubspec.exists():
        return None
    text = pubspec.read_text(encoding="utf-8", errors="replace")
    m = re.search(r"(?m)^version:\s*([0-9][^\s+]*(?:\+[0-9]+)?)\s*$", text)
    if not m:
        return None
    raw = m.group(1)
    if "+" in raw:
        name, code = raw.split("+", 1)
        return name, code
    return raw, ""


def check_version(apk: Path, project: Path, aapt: str | None, report: Report) -> None:
    expected = parse_pubspec(project)
    if expected is None:
        report.warn("pubspec.yaml 里没解析到 version，跳过版本核对")
        return
    if not aapt:
        report.warn(
            f"没找到 aapt/aapt2，跳过包内版本核对（期望 {expected[0]}+{expected[1]}）"
        )
        return

    out = run(tool_cmd(aapt, "dump", "badging", str(apk)))
    m = re.search(
        r"package: name='([^']+)' versionCode='(\d+)' versionName='([^']*)'", out
    )
    if not m:
        report.warn("aapt 输出里没读到 package 行，跳过版本核对")
        return

    pkg, code, name = m.group(1), m.group(2), m.group(3)
    exp_name, exp_code = expected
    if name != exp_name or (exp_code and code != exp_code):
        report.fail(
            f"包内版本 {name}+{code} 与 pubspec 的 {exp_name}+{exp_code} 不一致"
        )
        return
    report.ok(f"包内版本一致：{pkg} {name}+{code}")


def check_signature(
    apk: Path, signer: str | None, expected: str, report: Report
) -> None:
    if not signer:
        report.warn("没找到 apksigner，跳过签名核对（release 前请人工确认）")
        return
    out = run(tool_cmd(signer, "verify", "--print-certs", str(apk)))
    m = re.search(r"SHA-256 digest:\s*([0-9a-fA-F]+)", out)
    if not m:
        report.warn("apksigner 没读到证书指纹，跳过签名核对")
        return
    actual = m.group(1).lower()
    if actual != expected.lower():
        report.fail(
            f"签名指纹不一致：实际 {actual}，期望 {expected} —— "
            "覆盖安装会失败/丢账本，别发"
        )
        return
    report.ok("签名指纹 = upload key")


def main() -> int:
    ap = argparse.ArgumentParser(description="发布前 APK 物检")
    ap.add_argument("--apk", required=True, help="app-release.apk 路径")
    ap.add_argument("--project", default=str(PROJECT), help="项目根（默认脚本上级）")
    ap.add_argument("--aapt", default=None, help="aapt/aapt2 路径（默认自动找）")
    ap.add_argument("--apksigner", default=None, help="apksigner 路径（默认自动找）")
    ap.add_argument(
        "--expected-cert",
        default=DEFAULT_CERT_SHA256,
        help="期望的签名证书 SHA-256",
    )
    ap.add_argument("--skip-version", action="store_true")
    ap.add_argument("--skip-signature", action="store_true")
    ap.add_argument("--skip-plugins", action="store_true")
    args = ap.parse_args()

    apk = Path(args.apk).resolve()
    project = Path(args.project).resolve()
    report = Report()

    print(f"APK     : {apk}")
    print(f"Project : {project}")
    print("-" * 60)

    if not apk.exists():
        report.fail(f"找不到 APK：{apk}")
        return 1

    check_zip(apk, report)
    if not args.skip_plugins:
        check_plugins(project, report)
    if not args.skip_version:
        check_version(apk, project, find_tool("aapt", args.aapt), report)
    if not args.skip_signature:
        check_signature(
            apk,
            find_tool("apksigner", args.apksigner),
            args.expected_cert,
            report,
        )

    print("-" * 60)
    if report.failed:
        print(f"结果：FAIL（{report.failed} 项失败 / {report.warned} 项跳过）")
        return 1
    print(f"结果：PASS（{report.warned} 项因缺少工具跳过）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
