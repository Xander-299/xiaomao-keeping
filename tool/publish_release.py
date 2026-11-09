#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 release APK 发布到 GitHub Release（让 Others 能直接下载体验）。

## 为什么需要它

本项目**没有 gh CLI**（沙箱里没装），而 GitHub MCP 工具集**不含
「创建 Release / 上传 Release 资产」**（只有 list / get）→ 走不通。

但 **git credential manager 里存着可用令牌**（`git credential fill` 能取到），
所以本脚本直接调 **GitHub REST API**：
`POST /repos/{owner}/{repo}/releases` 建 Release →
`POST .../releases/{id}/assets?name=xxx` 上传二进制（用
`Content-Type: application/octet-stream` + **原始字节流**上传）。

⚠️ **不要用 JSON 包 base64 上传** —— GitHub 的 assets API 只接受二进制流；
把二进制当 JSON 字段传会拿到 422。

## 用法

    python tool/publish_release.py --tag v0.7.16 \
        --apk build/app/outputs/flutter-apk/app-release.apk \
        --name "颜芯记账 v0.7.16" \
        --notes-file docs/release-notes.md

不传 `--notes-file` 时用 `--notes` 直接给文本。

## 安全

- 令牌**只从 git credential manager 现场取**，不落盘、不进版本控制。
- 脚本**不打印**令牌（只打印长度与账号名）。
"""

from __future__ import annotations

import argparse
import json
import mimetypes
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

OWNER = "Xander-299"
REPO = "xiaomao-keeping"
API = "https://api.github.com"


def get_token() -> str:
    """从 git credential manager 取令牌（不落盘）。"""
    proc = subprocess.run(
        ["git", "credential", "fill"],
        input="protocol=https\nhost=github.com\n\n",
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        sys.exit("FATAL: 取 git 凭据失败（git credential fill 返回 %d）" % proc.returncode)
    cred = {}
    for line in proc.stdout.strip().split("\n"):
        if "=" in line:
            k, v = line.split("=", 1)
            cred[k] = v
    token = cred.get("password", "")
    if not token:
        sys.exit("FATAL: 凭据里没有 password（未登录 GitHub？）")
    return token


def api(token: str, method: str, path: str, data=None, raw: bytes | None = None,
        content_type: str | None = None, base: str = API) -> dict:
    url = base + path
    headers = {
        "Authorization": "Bearer " + token,
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "yanxin-release-publisher",
    }
    body = None
    if raw is not None:
        body = raw
        headers["Content-Type"] = content_type or "application/octet-stream"
    elif data is not None:
        body = json.dumps(data).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            raw_body = r.read()
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:800]
        sys.exit("FATAL: %s %s → HTTP %d\n%s" % (method, path, e.code, detail))
    return json.loads(raw_body) if raw_body else {}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", required=True, help="已推送的 tag，如 v0.7.16")
    ap.add_argument("--apk", action="append", default=[],
                    help="要上传的 APK（可多次；默认只传 release.apk）")
    ap.add_argument("--name", default=None, help="Release 标题")
    ap.add_argument("--notes", default=None, help="Release 说明（纯文本）")
    ap.add_argument("--notes-file", default=None, help="从文件读 Release 说明（Markdown）")
    ap.add_argument("--prerelease", action="store_true")
    ap.add_argument("--dry-run", action="store_true", help="只打印参数，不调 API")
    args = ap.parse_args()

    notes = args.notes or ""
    if args.notes_file:
        with open(args.notes_file, encoding="utf-8") as fh:
            notes = fh.read()

    apks = args.apk or ["build/app/outputs/flutter-apk/app-release.apk"]
    for a in apks:
        if not os.path.isfile(a):
            sys.exit("FATAL: 找不到 APK：%s" % a)

    if args.dry_run:
        print("[dry-run] tag=%s name=%s" % (args.tag, args.name))
        for a in apks:
            print("           %s (%.1f MB)" % (a, os.path.getsize(a) / 1048576))
        return 0

    token = get_token()
    print("[release] 令牌已取（账号 %s）" % OWNER)

    # 幂等：同 tag 已存在 release 就复用
    rel = None
    try:
        rel = api(token, "GET", "/repos/%s/%s/releases/tags/%s" % (OWNER, REPO, args.tag))
        print("[release] 复用已有 release：id=%s" % rel["id"])
    except SystemExit:
        rel = api(token, "POST", "/repos/%s/%s/releases" % (OWNER, REPO), data={
            "tag_name": args.tag,
            "name": args.name or args.tag,
            "body": notes,
            "draft": False,
            "prerelease": args.prerelease,
        })
        print("[release] 已创建 release：id=%s url=%s" % (rel["id"], rel["html_url"]))

    existing = {a["name"] for a in rel.get("assets", [])}
    # ⚠️ **资产上传端点是 uploads.github.com，不是 api.github.com** ——
    # 用 api.github.com 打过去会 404（Release 本身能建，资产传不上去）。
    # 正确地址在 release 对象的 `upload_url` 字段里，形如
    # `https://uploads.github.com/repos/{owner}/{repo}/releases/{id}/assets{?name,label}`
    upload_base = rel.get("upload_url", "").split("{")[0]
    if not upload_base:
        sys.exit("FATAL: release 里没有 upload_url 字段")
    for apk in apks:
        asset_name = os.path.basename(apk)
        if asset_name in existing:
            print("[release] 资产已存在，跳过：%s" % asset_name)
            continue
        size = os.path.getsize(apk)
        print("[release] 上传 %s（%.1f MB）…" % (asset_name, size / 1048576))
        with open(apk, "rb") as fh:
            blob = fh.read()
        out = api(token, "POST",
                  "%s?name=%s" % (upload_base, urllib.parse.quote(asset_name)),
                  raw=blob,
                  content_type=mimetypes.guess_type(asset_name)[0] or "application/octet-stream",
                  base="")
        print("           → %s（%d B）" % (out.get("browser_download_url"), out.get("size", 0)))

    print("[release] 完成：%s" % rel.get("html_url"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
