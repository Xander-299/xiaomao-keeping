# 部署到阿里云 ECS（Ubuntu / Debian）

> 目标：`https://sync.你的域名` 上跑起 `xiaomao-sync`，能发验证码、能上传/下载备份。
> 全流程 **20–30 分钟**，除了域名与发信，其余都在免费/最小配置内（1C1G 足够）。
>
> 服务端**零运行时依赖**：Node 自带 `node:http` / `node:sqlite` / `fetch` / WebCrypto，
> 直接 `node src/node/main.ts` 就能跑，**不需要编译、不需要 npm install 生产依赖**。

## 0 · 前置

| 项 | 说明 |
|---|---|
| ECS 实例 | Ubuntu 22.04 / 24.04，1C1G 起（Debian 12 也可以） |
| 安全组 | 放行 **22 / 80 / 443**（80 只用于签证书，可保留做跳转） |
| 域名 | **大陆节点必须备案**，否则 80/443 会被拦。客户端强制 HTTPS，所以没有域名基本走不通 |
| 发信 | Resend 账号 + API Key（最快）；或用阿里云邮件推送（需自己接 SMTP） |

## 0.5 · 懒人版：一条命令（推荐）

```bash
cd /opt && sudo git clone --depth 1 https://github.com/Xander-299/xiaomao-keeping.git xm
sudo bash xm/server/bootstrap.sh \
  --domain sync.你的域名 \
  --mail-from '小耄记账 <no-reply@你的域名>' \
  --install-node
```

它会：装 Node 24（`--install-node`）→ 建 `xiaomao` 用户与 `/opt/xiaomao-sync` → 同步代码 →
**现场生成两个密钥写进 `.env`（chmod 600，不回显）** → 装 systemd 单元并启动 → 自检
`GET /v1/backups` 是否 401 → 有 Caddy 就写好反代配置。

幂等，可重复跑；**不会覆盖已有 `.env` 与 `data/`**（要重写加 `--force-env`）。

它**不做**（必须你来）：安全组放行、域名备案与 DNS、Resend 注册/域名验证。
下面是手工版，出问题时对着看。

## 1 · 装 Node（要 ≥ 22.5，建议 24 LTS）

```bash
# 用 NodeSource 官方源（比 apt 自带的版本新）
curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
sudo apt-get install -y nodejs
node -v          # 期望 v24.x
node -e "require('node:sqlite');console.log('sqlite ok')"
```

> `node:sqlite` 是 Node 22.5 引入的内置模块：
> - Node 22.x：要加 `--experimental-sqlite`；
> - Node 23.4+ / 24：默认可用（**推荐**）。
>
> 看到 `sqlite ok` 就说明这条链没问题。

## 2 · 放代码

```bash
sudo useradd -r -s /usr/sbin/nologin -d /opt/xiaomao-sync xiaomao || true
sudo mkdir -p /opt/xiaomao-sync && sudo chown -R $USER /opt/xiaomao-sync

# 方式一：git（推荐，更新只要 pull）
git clone --depth 1 https://github.com/Xander-299/xiaomao-keeping.git /tmp/xm
sudo rsync -a --delete /tmp/xm/server/ /opt/xiaomao-sync/

# 方式二：本机打包上传
#   tar -czf server.tgz -C server . && scp server.tgz root@<ECS_IP>:/tmp/
#   ssh root@<ECS_IP> 'tar -xzf /tmp/server.tgz -C /opt/xiaomao-sync'

sudo mkdir -p /opt/xiaomao-sync/data
sudo chown -R xiaomao:xiaomao /opt/xiaomao-sync
```

> 只要 `server/` 目录（里面 `src/`、`schema.sql` 就够）。`node_modules` 不需要 —— 生产零依赖。

## 3 · 配置密钥

```bash
sudo -u xiaomao tee /opt/xiaomao-sync/.env >/dev/null <<EOF
PORT=8787
HOST=127.0.0.1
DATA_DIR=/opt/xiaomao-sync/data
JWT_SECRET=$(openssl rand -base64 48)
CODE_PEPPER=$(openssl rand -base64 48)
MAIL_FROM=小耄记账 <no-reply@你的域名>
RESEND_API_KEY=re_xxxxxxxx
EOF
sudo chmod 600 /opt/xiaomao-sync/.env
```

- `HOST=127.0.0.1`：**只让本机的 Caddy/Nginx 转发进来**，别把 Node 裸奔在公网；
- 两个 secret 都是 `openssl rand` 现生成、直接写进文件，**不经终端回显、不进仓库**；
- 想先不发邮件、只看链路通不通：把 `DEV_ECHO_CODE=1` 加进去（验证码打到 `journalctl`）。

**发信二选一**（改完 `systemctl restart xiaomao-sync`）：

```bash
# A. Resend（需要自己注册的域名）
RESEND_API_KEY=re_xxx
MAIL_FROM=小耄记账 <no-reply@你的域名>

# B. SMTP 授权码（126 / 163 / QQ 邮箱；不需要域名）
MAIL_PROVIDER=smtp
SMTP_HOST=smtp.126.com
SMTP_PORT=465
SMTP_SECURE=1
SMTP_USER=you@126.com
SMTP_PASS=客户端授权码
MAIL_FROM=小耄记账 <you@126.com>
```

> 上线前**必须删掉 `DEV_ECHO_CODE=1`**，否则任何能读日志的人都能登录任意邮箱。

## 4 · 建库（不用手动，启动即建）

首次启动会自动执行 `schema.sql`（全是 `CREATE ... IF NOT EXISTS`，重复跑安全）。
想确认表建好了：

```bash
sudo apt-get install -y sqlite3
sudo -u xiaomao sqlite3 /opt/xiaomao-sync/data/sync.db '.tables'
# users  auth_codes  code_sends  refresh_tokens  backups
```

## 5 · systemd 托管

```bash
sudo tee /etc/systemd/system/xiaomao-sync.service >/dev/null <<'EOF'
[Unit]
Description=xiaomao-keeping sync API
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=xiaomao
WorkingDirectory=/opt/xiaomao-sync
EnvironmentFile=/opt/xiaomao-sync/.env
# Node 24 直接跑 .ts（类型剥离），无需构建
ExecStart=/usr/bin/node src/node/main.ts
Restart=always
RestartSec=3

# 最小权限
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/xiaomao-sync/data

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now xiaomao-sync
sudo systemctl status xiaomao-sync --no-pager
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8787/v1/backups   # 期望 401
```

看日志：`sudo journalctl -u xiaomao-sync -f`

## 6 · HTTPS（Caddy 自动签证书，最省事）

```bash
sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt-get update && sudo apt-get install -y caddy

sudo tee /etc/caddy/Caddyfile >/dev/null <<'EOF'
sync.你的域名 {
    reverse_proxy 127.0.0.1:8787
}
EOF

sudo systemctl reload caddy
curl -i https://sync.你的域名/v1/backups      # 期望 401
```

证书自动续期，无需 certbot。

<details>
<summary>用 Nginx + certbot 也行</summary>

```nginx
server {
  listen 443 ssl http2;
  server_name sync.你的域名;
  ssl_certificate     /etc/letsencrypt/live/sync.你的域名/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/sync.你的域名/privkey.pem;
  client_max_body_size 25m;          # 备份上限 20 MB，留点余量
  location / {
    proxy_pass http://127.0.0.1:8787;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  }
}
```
证书：`sudo certbot --nginx -d sync.你的域名`
</details>

> ⚠️ `client_max_body_size` 一定要 ≥ 20 MB，否则大备份会在 Nginx 层被 413 挡掉（Node 那边根本收不到）。

## 7 · 冒烟（5 条，全过就算通了）

```bash
BASE=https://sync.你的域名

curl -i $BASE/v1/backups/latest                      # ① 401
curl -i -X POST $BASE/v1/auth/request-code \
  -H 'content-type: application/json' -d '{"email":"你的@邮箱"}'   # ② 204（有发信就该收到邮件）

# ③ 用邮件里的 6 位码换 token
curl -s -X POST $BASE/v1/auth/verify -H 'content-type: application/json' \
  -d '{"email":"你的@邮箱","code":"123456"}'

# ④ 上传（token 用上一步的 accessToken）
curl -i -X PUT $BASE/v1/backups/latest \
  -H "authorization: Bearer <token>" -H 'content-type: application/json' \
  --data-binary @备份.json

# ⑤ 取回比对
curl -s $BASE/v1/backups/latest -H "authorization: Bearer <token>" | sha256sum
sha256sum 备份.json
```

两条 sha256 一致 = 上传下载无损。

## 8 · 日常运维

| 事情 | 命令 |
|---|---|
| 看日志 | `sudo journalctl -u xiaomao-sync -n 100 --no-pager` |
| 重启 | `sudo systemctl restart xiaomao-sync` |
| 更新代码 | `cd /tmp/xm && git pull` → `sudo rsync -a --delete /tmp/xm/server/ /opt/xiaomao-sync/` → `sudo systemctl restart xiaomao-sync` |
| 备份数据 | `sudo tar -czf /root/xiaomao-$(date +%F).tgz -C /opt/xiaomao-sync data` |
| 看库 | `sudo -u xiaomao sqlite3 /opt/xiaomao-sync/data/sync.db '.tables'`（需 `apt install sqlite3`） |

> 数据全在 `/opt/xiaomao-sync/data`：`sync.db`（用户/验证码/token/备份元数据）+ `backups/`（备份正文）。
> 定期把这个目录打包到别处（阿里云 OSS 也行，用 `ossutil` 或 `rclone`）。

## 9 · 常见问题

| 现象 | 原因 / 处理 |
|---|---|
| `node:sqlite` 报找不到 | Node < 22.5；或 22.x 忘了 `--experimental-sqlite`。换 Node 24 |
| 服务起不来，日志说 secret 太短 | `JWT_SECRET` / `CODE_PEPPER` 必须各 ≥ 32 字符（脚本已满足） |
| `curl 127.0.0.1:8787` 通，域名不通 | 安全组没放 443；或备案没过（大陆）；或 Caddy 没 reload |
| `request-code` 返回 503 | 没配 `RESEND_API_KEY` / `MAIL_FROM`，或 Resend 域名没验证 |
| 上传 413 | Nginx `client_max_body_size` 太小（见 §6） |
| 上传 502 | Node 挂了：`journalctl -u xiaomao-sync` 看堆栈 |
| 邮件进垃圾箱 | 用自有域名 + Resend 的 SPF/DKIM 记录；`onboarding@resend.dev` 尤其容易被判垃圾 |
| 想临时不发信只看链路 | `.env` 加 `DEV_ECHO_CODE=1`，验证码会出现在 `journalctl` |

## 10 · 之后接客户端

把 `https://sync.你的域名` 给我，我写进 `lib/core/network/sync_endpoints.dart` 的主机白名单，
然后客户端（P6.2 登录 / P6.3 云备份）就能联调了。
