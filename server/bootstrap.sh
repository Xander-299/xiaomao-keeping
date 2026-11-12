#!/usr/bin/env bash
# 小耄记账云同步 · 一键部署（Ubuntu / Debian，需 root）
#
#   sudo bash server/bootstrap.sh --domain sync.example.com \
#        --mail-from '小耄记账 <no-reply@example.com>' [--install-node] [--force-env]
#
# 幂等：重复执行只会更新代码与单元文件，不会覆盖已有的 .env（除非 --force-env）。
# 不做的事（必须你自己来）：安全组放行、域名备案与 DNS 解析、Resend 注册。
set -euo pipefail

APP_USER="xiaomao"
APP_DIR="/opt/xiaomao-sync"
DATA_DIR="$APP_DIR/data"
SERVICE="xiaomao-sync"
NODE_MIN_MAJOR=22

DOMAIN=""
MAIL_FROM=""
INSTALL_NODE=0
FORCE_ENV=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --mail-from) MAIL_FROM="${2:-}"; shift 2 ;;
    --install-node) INSTALL_NODE=1; shift ;;
    --force-env) FORCE_ENV=1; shift ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "未知参数：$1"; exit 2 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "请用 root 执行：sudo bash $0 ..." >&2
  exit 1
fi

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[注意] %s\033[0m\n' "$*"; }

# ── 1. Node ────────────────────────────────────────────────────────────
say "检查 Node"
need_install=0
if ! command -v node >/dev/null 2>&1; then
  need_install=1
else
  major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  if [[ "$major" -lt "$NODE_MIN_MAJOR" ]]; then need_install=1; fi
fi

if [[ "$need_install" == "1" ]]; then
  if [[ "$INSTALL_NODE" == "1" ]]; then
    say "安装 Node 24（NodeSource）"
    apt-get update -y
    apt-get install -y curl ca-certificates
    curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
    apt-get install -y nodejs
  else
    warn "Node 未安装或低于 v${NODE_MIN_MAJOR}。加 --install-node 自动装，或手动装 Node 24 后重跑。"
    exit 1
  fi
fi

if ! node -e "require('node:sqlite')" >/dev/null 2>&1; then
  warn "当前 Node 没有内置 node:sqlite。请用 Node 22.5+（22.x 需 --experimental-sqlite），推荐 24。"
  exit 1
fi
NODE_BIN="$(command -v node)"
case "$NODE_BIN" in
  /usr/bin/*|/usr/local/bin/*) ;;
  *) warn "node 在 $NODE_BIN —— 服务以 $APP_USER 身份运行可能读不到它（nvm 装的通常在 /root 下）。建议用 NodeSource 装到 /usr/bin。" ;;
esac
echo "Node $(node -v) ✓"

# ── 2. 用户与目录 ──────────────────────────────────────────────────────
say "准备用户与目录"
if ! id -u "$APP_USER" >/dev/null 2>&1; then
  useradd -r -s /usr/sbin/nologin -d "$APP_DIR" "$APP_USER"
fi
mkdir -p "$APP_DIR" "$DATA_DIR"

# 代码来源：当前脚本所在目录的上一级（即 server/）
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$SRC_DIR/src/node/main.ts" ]]; then
  warn "找不到 src/node/main.ts —— 请在仓库的 server/ 目录下执行本脚本。"
  exit 1
fi

say "同步代码到 $APP_DIR"
if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete \
    --exclude node_modules --exclude data --exclude .env --exclude .dev.vars \
    --exclude package-lock.json \
    "$SRC_DIR/" "$APP_DIR/"
else
  # 没有 rsync 就手工 cp（够用，不追求增量）
  # ⚠️ 只清代码，**绝不动 data/ 与 .env**：前者是账本库，后者是密钥
  find "$APP_DIR" -mindepth 1 -maxdepth 1 \
    ! -name data ! -name .env -exec rm -rf {} +
  cp -a "$SRC_DIR/." "$APP_DIR/"
  rm -rf "$APP_DIR/node_modules"          # 生产不需要依赖
fi

# ── 3. .env ────────────────────────────────────────────────────────────
say "生成配置"
if [[ -f "$APP_DIR/.env" && "$FORCE_ENV" != "1" ]]; then
  echo "$APP_DIR/.env 已存在，保留不动（要重写加 --force-env）"
else
  # 密钥现场生成，直接写文件 —— 不出现在终端、不进日志
  umask 077
  {
    echo "PORT=8787"
    echo "HOST=127.0.0.1"
    echo "DATA_DIR=$DATA_DIR"
    echo "JWT_SECRET=$(openssl rand -base64 48 | tr -d '\n')"
    echo "CODE_PEPPER=$(openssl rand -base64 48 | tr -d '\n')"
    [[ -n "$MAIL_FROM" ]] && echo "MAIL_FROM=$MAIL_FROM"
  } > "$APP_DIR/.env"
  umask 022
  chmod 600 "$APP_DIR/.env"
  echo "已写入 $APP_DIR/.env（含新生成的两个密钥）"
  [[ -z "$MAIL_FROM" ]] && warn "没给 --mail-from：发信会失败（可用 DEV_ECHO_CODE=1 先跑通链路）"
  grep -q 'RESEND_API_KEY' "$APP_DIR/.env" || warn "还没配 RESEND_API_KEY —— 记得追加：RESEND_API_KEY=re_xxx"
fi

chown -R "$APP_USER:$APP_USER" "$APP_DIR"
chmod 600 "$APP_DIR/.env"

# ── 4. systemd ─────────────────────────────────────────────────────────
say "安装 systemd 单元"
cat > "/etc/systemd/system/${SERVICE}.service" <<UNIT
[Unit]
Description=xiaomao-keeping sync API
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${APP_USER}
WorkingDirectory=${APP_DIR}
EnvironmentFile=${APP_DIR}/.env
ExecStart=$(command -v node) src/node/main.ts
Restart=always
RestartSec=3

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${DATA_DIR}

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now "$SERVICE" >/dev/null
sleep 1
if ! systemctl is-active --quiet "$SERVICE"; then
  warn "服务没起来，看日志：journalctl -u ${SERVICE} -n 50 --no-pager"
  journalctl -u "$SERVICE" -n 20 --no-pager || true
  exit 1
fi
echo "服务已运行 ✓"

# ── 5. 自检 ────────────────────────────────────────────────────────────
say "本地自检"
code="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8787/v1/backups || true)"
if [[ "$code" == "401" ]]; then
  echo "GET /v1/backups → 401 ✓（服务活着且鉴权生效）"
else
  warn "GET /v1/backups 期望 401，实际 $code"
fi

if sqlite3 --version >/dev/null 2>&1; then
  echo "表：$(sudo -u "$APP_USER" sqlite3 "$DATA_DIR/sync.db" '.tables' | tr -s ' ')"
fi

# ── 6. HTTPS ───────────────────────────────────────────────────────────
if [[ -n "$DOMAIN" ]]; then
  if command -v caddy >/dev/null 2>&1; then
    say "配置 Caddy：$DOMAIN → 127.0.0.1:8787"
    cat > /etc/caddy/Caddyfile <<CADDY
${DOMAIN} {
    reverse_proxy 127.0.0.1:8787
}
CADDY
    systemctl reload caddy || systemctl restart caddy
    echo "已写入 /etc/caddy/Caddyfile（证书会在首次访问时自动签发）"
    echo "验证：curl -i https://${DOMAIN}/v1/backups   # 期望 401"
  else
    warn "没装 Caddy。装好后再跑一次本脚本（或手写反代），命令见 server/DEPLOY-ECS.md §6"
  fi
else
  warn "没给 --domain：只监听了 127.0.0.1，外网访问不了。"
fi

say "完成"
cat <<NEXT
下一步（人工）：
  1) 安全组放行 80 / 443（22 已有）；
  2) 域名 A 记录指向本机公网 IP，且已完成备案；
  3) 发信：.env 里补 RESEND_API_KEY=re_xxx，然后 systemctl restart ${SERVICE}；
  4) 冒烟：curl -i -X POST https://<域名>/v1/auth/request-code \\
            -H 'content-type: application/json' -d '{"email":"你的@邮箱"}'   # 期望 204
NEXT
