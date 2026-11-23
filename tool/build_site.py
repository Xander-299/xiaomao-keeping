#!/usr/bin/env python3
"""把 `docs/` 的落地页打成一个**可直接托管**的站点包（F7.23 前置）。

为什么需要它：GitHub Pages 在国内又慢又不稳，而下载 40MB 的 APK 更慢。
这个脚本产出一个自包含目录，可以原样丢到：
  - 阿里云 OSS / 腾讯云 COS（+CDN，需备案域名）；
  - 自有 ECS + Nginx（配合已有 Cloudflare 隧道时无需备案）；
  - Cloudflare Pages；
  - 任何静态托管。

用法：
  python3 tool/build_site.py                        # 默认：下载链接仍指 GitHub Releases
  python3 tool/build_site.py --download-base https://dl.example.com/download
                                                    # 下载链接改指你自己的域名（APK 一起打进包里）

产物：build/site/（index.html + 图标 + 截图 + download/*.apk + SHA256SUMS.txt）
"""
from __future__ import annotations

import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
OUT = ROOT / "build" / "site"

# 与 release.yml 的命名一致（CD 产物前缀）
APK_PATTERN = "yanxin-v{version}-{abi}-release.apk"
ABIS = ("arm64-v8a", "armeabi-v7a", "x86_64")


def read_version() -> str:
    text = (ROOT / "pubspec.yaml").read_text(encoding="utf-8")
    m = re.search(r"^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+", text, re.M)
    if not m:
        sys.exit("pubspec.yaml 里找不到 version: X.Y.Z+N")
    return m.group(1)


def find_aapt() -> str | None:
    """找 aapt2/aapt：PATH → ANDROID_HOME/ANDROID_SDK_ROOT → 本机常见路径。

    只用来**校验 APK 版本**：站点包里的文件名是 vX，如果 APK 其实是旧版本，
    用户下到的就是「名字对、内容错」的包 —— 比部署失败更糟。
    """
    for name in ("aapt2", "aapt"):
        found = shutil.which(name)
        if found:
            return found
    roots = [
        os.environ.get("ANDROID_HOME"),
        os.environ.get("ANDROID_SDK_ROOT"),
        r"D:\Download\Java\Android",
        "/mnt/d/Download/Java/Android",  # WSL 下同一个目录
    ]
    for root in roots:
        if not root:
            continue
        bt = Path(root) / "build-tools"
        if not bt.is_dir():
            continue
        for d in sorted(bt.iterdir(), reverse=True):
            for name in ("aapt2.exe", "aapt.exe", "aapt2", "aapt"):
                if (d / name).exists():
                    return str(d / name)
    return None


def _win_path(path: Path) -> str:
    """WSL 下把 /mnt/d/... 换成 D:\\...（调用 Windows 的 aapt2.exe 要用）。"""
    try:
        return subprocess.run(
            ["wslpath", "-w", str(path)], capture_output=True, text=True, timeout=10
        ).stdout.strip() or str(path)
    except Exception:
        return str(path)


def apk_version(aapt: str | None, apk: Path) -> str | None:
    """读 APK 的 versionName（读不到返回 None，调用方据此决定是否跳过校验）。

    WSL 下 aapt2 是 Windows 的 exe：直接传 `/mnt/...` 路径它不认识，传相对路径
    （从仓库根跑脚本时）就能解析 —— 所以这里优先用相对路径，再兜绝对路径。
    """
    if not aapt:
        return None
    try:
        rel = os.path.relpath(apk, Path.cwd())
    except Exception:
        rel = str(apk)
    candidates = [rel, str(apk)]
    for target in candidates:
        try:
            # errors="replace"：Windows 工具的中文报错是 GBK，按 UTF-8 解码会炸
            out = subprocess.run(
                [aapt, "dump", "badging", target],
                capture_output=True,
                text=True,
                errors="replace",
                timeout=60,
            ).stdout
        except Exception:
            continue
        m = re.search(r"versionName='([^']+)'", out)
        if m:
            return m.group(1)
    return None


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", default=None, help="默认读 pubspec.yaml")
    ap.add_argument(
        "--download-base",
        default=None,
        help="下载目录的公开前缀，如 https://dl.example.com/download；不填则保持 GitHub Releases 链接",
    )
    ap.add_argument(
        "--apk-dir",
        default=str(ROOT / "build" / "app" / "outputs" / "flutter-apk"),
        help="本地 release APK 所在目录（用于一起打包）",
    )
    ap.add_argument("--out", default=str(OUT))
    ap.add_argument(
        "--no-apk",
        action="store_true",
        help="只出页面（APK 由 ECS/OSS 另发时用：包从 59MB 降到 ~330KB，方便传服务器）",
    )
    args = ap.parse_args()

    version = args.version or read_version()
    out = Path(args.out)
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)

    # 1) 页面 + 图标 + 截图（保持相对路径，换域名不用改）
    shutil.copy2(DOCS / "index.html", out / "index.html")
    for name in ("favicon-32.png", "apple-touch-icon.png", "icon-192.png"):
        src = DOCS / name
        if src.exists():
            shutil.copy2(src, out / name)
    if (DOCS / "shots").is_dir():
        shutil.copytree(DOCS / "shots", out / "shots")

    # 2) 下载链接：默认 GitHub Releases；给了 --download-base 就改成自托管
    html = (out / "index.html").read_text(encoding="utf-8")
    if args.download_base:
        base = args.download_base.rstrip("/")
        arm64 = f"{base}/" + APK_PATTERN.format(version=version, abi="arm64-v8a")
        if 'id="dl-arm64"' in html:
            # 页面已经给按钮加了 id：按 id 换 href，不关心原来指向哪（GitHub / 旧 OSS 都行）
            html = re.sub(r'(id="dl-arm64" href=")[^"]*(")', rf"\g<1>{arm64}\g<2>", html)
            html = re.sub(r'(id="dl-all" href=")[^"]*(")', rf"\g<1>{base}/{version}/\g<2>", html)
        else:
            # 兜底：老页面没有 id，按 URL 形态替换
            html = re.sub(
                r"https?://[^\"']*?/yanxin-v[0-9.]+-arm64-v8a-release\.apk", arm64, html
            )
            html = re.sub(
                r"https?://[^\"']*?/releases/tag/v[0-9.]+", f"{base}/{version}/", html
            )
    (out / "index.html").write_text(html, encoding="utf-8")

    # 3) APK + 校验和（只有本地有构建产物时才带；没有就跳过并提示）
    apk_dir = Path(args.apk_dir)
    dl = out / "download"
    dl.mkdir()
    aapt = find_aapt()
    copied = []
    for abi in ABIS:
        src = apk_dir / f"app-{abi}-release.apk"
        if not src.exists():
            continue
        # 版本校验：名字里写 vX，内容也必须是 vX（否则宁可不发）
        got = apk_version(aapt, src)
        if got is not None and got != version:
            sys.exit(
                f"[error] {src.name} 的版本是 {got}，但站点包按 {version} 命名。\n"
                f"        先按该版本出包（flutter build apk --release --split-per-abi --no-pub）再重跑。"
            )
        dst = dl / APK_PATTERN.format(version=version, abi=abi)
        shutil.copy2(src, dst)
        copied.append((dst.name, sha256(dst)))

    if args.no_apk:
        # 下载由 ECS 的 /download/（或 OSS）提供，站点包不必再驮 115MB 的 APK
        shutil.rmtree(dl, ignore_errors=True)
        print("[ok] --no-apk：只出页面（下载走 --download-base 指向的地址，或同域 /download/）")
    elif copied:
        (out / "SHA256SUMS.txt").write_text(
            "".join(f"{h}  {n}\n" for n, h in copied), encoding="utf-8"
        )
        # 下载目录的列表页（「其他架构」落到这里）
        items = "\n".join(
            f'<li><a href="{n}">{n}</a> <span>{size} MB</span></li>'
            for n, _ in copied
            for size in [f"{(dl / n).stat().st_size / 1024 / 1024:.1f}"]
        )
        (dl / "index.html").write_text(
            "<!doctype html><meta charset=utf-8><title>小耄记账 · 下载</title>"
            "<style>body{font:15px/1.7 -apple-system,system-ui,sans-serif;max-width:640px;"
            "margin:40px auto;padding:0 16px;color:#1f1b12}</style>"
            f"<h1>小耄记账 v{version}</h1><p>按手机架构选择；不确定就选 arm64-v8a。</p>"
            f"<ul>{items}</ul><p><a href='../'>← 返回首页</a></p>",
            encoding="utf-8",
        )
    else:
        print(f"[warn] {apk_dir} 里没有 app-*-release.apk，站点包不含 APK（只出页面）")

    if not aapt:
        print("[warn] 没找到 aapt2/aapt，跳过 APK 版本校验（请自行确认包与版本号一致）")
    print(f"[ok] 站点包：{out}")
    print(f"     version={version}  download_base={args.download_base or 'GitHub Releases'}")
    for name, _ in copied:
        print(f"     + download/{name}")


if __name__ == "__main__":
    main()
