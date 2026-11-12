#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 `.dart_tool/package_config.json` 里的包路径在 **Windows ↔ Linux(WSL)** 之间改写。

## 为什么需要它

这台机器的日常分工是：**出包用 Windows 的 flutter.bat，分析/测试判读用 WSL 的 dart**。
两边共用同一份 `package_config.json`，但它的 `rootUri` 是**绝对路径**，谁最后跑 `pub get`
就写成谁的那一套：

- `flutter.bat pub get`（Windows）→ `file:///C:/Users/<你>/AppData/Local/Pub/Cache/...`
  与 `file:///D:/Download/Flutter/flutter/...`
- WSL 的 `dart analyze` 读不到 `C:/` 与 `D:/` → **一次报七千多个假错误**
  （`Target of URI doesn't exist` / `undefined_identifier` 满地都是），看起来像代码炸了。

2026-11-13 就是这样被骗了一次：出完 v0.8.4 的包后 `dart analyze lib test` 报 7543 issues，
真实原因是路径而不是代码。

## 用法

    python3 tool/fix_package_config.py              # 改成 Linux 路径（默认，改完就能 dart analyze）
    python3 tool/fix_package_config.py --check      # 只报告当前是哪一边，不改
    python3 tool/fix_package_config.py --to windows \\
        --win-pub-cache 'C:/Users/panda/AppData/Local/Pub/Cache' \\
        --win-flutter 'D:/Download/Flutter/flutter'

改完会**逐个校验目录是否存在**；有不存在的就报错退出（说明两个 pub cache 的版本对不上，
该在目标侧重跑一次 `pub get`）。
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

CFG = Path(".dart_tool/package_config.json")

# `file:///C:/Users/x/AppData/Local/Pub/Cache/hosted/pub.dev/foo-1.2.3`
_WIN_DRIVE = re.compile(r"^file:///([A-Za-z]):/")


def _detect() -> str:
    if not CFG.exists():
        sys.exit(f"FATAL: 找不到 {CFG}（先在目标环境跑一次 flutter pub get）")
    data = json.loads(CFG.read_text(encoding="utf-8"))
    roots = [p.get("rootUri", "") for p in data.get("packages", [])]
    win = sum(1 for r in roots if _WIN_DRIVE.match(r))
    if win:
        return "windows"
    return "linux"


def _linux_flutter_root() -> str:
    env = os.environ.get("FLUTTER_ROOT")
    if env and Path(env, "packages", "flutter").is_dir():
        return env
    # 仓库里的常规位置（同机 WSL）
    for cand in ("/home/panda/development/flutter", os.path.expanduser("~/development/flutter")):
        if Path(cand, "packages", "flutter").is_dir():
            return cand
    sys.exit(
        "FATAL: 找不到 Linux 侧 Flutter SDK。设置 FLUTTER_ROOT，"
        "或先确认 WSL 里 `which flutter` 指向哪里。"
    )


def _rewrite(s: str, *, target: str, win_pub_cache: str, win_flutter: str) -> tuple[str, int]:
    """返回 (新文本, 改写条数)。"""
    linux_pub = str(Path.home() / ".pub-cache").replace(os.sep, "/")
    linux_flutter = _linux_flutter_root().replace(os.sep, "/")
    win_flutter = win_flutter.rstrip("/")

    if target == "linux":
        pairs = (
            (f"file:///{win_flutter}", f"file://{linux_flutter}"),
            (f"file:///{win_flutter.replace(':', '')}", f"file://{linux_flutter}"),
        )
        # Pub cache：`.../Pub/Cache` 这一段的盘符与用户目录都不固定，靠正则吃掉
        text, n_cache = re.subn(
            r"file:///[A-Za-z]:/[^\"]*?/Pub/Cache",
            f"file://{linux_pub}",
            s,
        )
        n_flutter = 0
        for old, new in pairs:
            if old in text:
                n_flutter += text.count(old)
                text = text.replace(old, new)
        return text, n_cache + n_flutter

    # target == windows
    win_pub = win_pub_cache.rstrip("/")
    text, n_pub = re.subn(r"file:///[^\"]*?/\.pub-cache", f"file:///{win_pub}", s)
    n_flutter = 0
    for old in (f"file://{linux_flutter}",):
        if old in text:
            n_flutter += text.count(old)
            text = text.replace(old, f"file:///{win_flutter}")
    return text, n_pub + n_flutter


def _verify() -> list[str]:
    data = json.loads(CFG.read_text(encoding="utf-8"))
    missing: list[str] = []
    for p in data.get("packages", []):
        uri = p.get("rootUri", "")
        if not uri.startswith("file://"):
            continue
        path = uri[len("file://") :]
        if not Path(path).is_dir():
            missing.append(f"{p.get('name')} → {path}")
    return missing


def main() -> int:
    ap = argparse.ArgumentParser(description="改写 package_config.json 的包路径（Windows ↔ Linux）")
    ap.add_argument("--to", choices=["linux", "windows"], default="linux")
    ap.add_argument("--check", action="store_true", help="只报告当前是哪一边")
    ap.add_argument("--win-pub-cache", default="C:/Users/%USERNAME%/AppData/Local/Pub/Cache")
    ap.add_argument("--win-flutter", default="D:/Download/Flutter/flutter")
    args = ap.parse_args()

    current = _detect()
    if args.check:
        print(f"package_config 当前指向：{current}")
        missing = _verify()
        print(f"缺失目录：{len(missing)}")
        for m in missing[:5]:
            print("  " + m)
        return 0 if not missing else 1

    if current == args.to:
        print(f"已经是 {args.to} 路径，无需改写")
        return 0

    text = CFG.read_text(encoding="utf-8")
    new_text, n = _rewrite(
        text,
        target=args.to,
        win_pub_cache=args.win_pub_cache.replace("%USERNAME%", os.environ.get("USERNAME", "panda")),
        win_flutter=args.win_flutter,
    )
    if n == 0:
        print("没有可改写的路径（检查一下 rootUri 形态）", file=sys.stderr)
        return 2
    CFG.write_text(new_text, encoding="utf-8")
    print(f"已把 {n} 个 rootUri 改写成 {args.to} 路径")

    # 只有在「目标侧就是当前这台机器」时校验目录才有意义（WSL 当然看不见 C:/）
    host_is_linux = os.name != "nt"
    if (args.to == "linux") != host_is_linux:
        print(f"已改写为 {args.to} 路径（当前主机不是 {args.to} 侧，跳过目录校验）")
        return 0

    missing = _verify()
    if missing:
        print(f"\n⚠️ 有 {len(missing)} 个包目录在 {args.to} 侧不存在：", file=sys.stderr)
        for m in missing[:10]:
            print("  " + m, file=sys.stderr)
        print(
            f"\n这通常说明两边的 pub cache 版本不一致 —— 在 {args.to} 侧跑一次 pub get：",
            file=sys.stderr,
        )
        print(
            "  WSL : flutter pub get    /    Windows: flutter.bat pub get",
            file=sys.stderr,
        )
        return 1
    print("全部包目录校验通过 ✅")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
