# 部署跑一遍（Cloudflare Workers）

> 目标：拿到一个 `https://xiaomao-sync.<你的子域>.workers.dev`（或自定义域名），
> 能发验证码、能上传/下载备份。全程 **10–15 分钟**，除发信外都在免费额度内。
>
> 两条路，选一条即可：
> - **方案 A（命令行）**：§0–§11，本机装 wrangler，`wrangler deploy`。
> - **方案 B（全在 Dashboard 点）**：跳到 [§12](#12--方案-b全程在-cloudflare-面板点不装命令行)，连 GitHub 自动构建。
>
> **不要用 Pages**：这个服务端没有静态资源，Pages Functions 只是多一层（绑定要在 Pages 项目里另配），
> 官方现在也建议新项目直接用 Workers。

## 0 · 前置检查

```bash
node -v            # 需要 ≥ 18（这台机器是 v26.12.1，够）
cd "/mnt/d/new file/yanxin-flutter/server"
```

需要两样账号资产：

| 资产 | 必需? | 说明 |
|---|---|---|
| Cloudflare 账号 | 必需 | 免费注册；R2 首次启用要绑一张卡（免费额度 10 GB 不扣费） |
| 一个域名（托管到 Cloudflare） | **强烈建议** | 不绑域名只能用 `*.workers.dev`，国内经常连不通（见 §8） |

## 1 · 装 wrangler

```bash
npm install -g wrangler        # 或者不装，后面全部用 npx wrangler
wrangler --version             # 期望 3.x 或 4.x
```

> ⚠️ **如果卡在 `npm install` 十几分钟不动**：多半是代理没通。这台机器的环境里设了
> `https_proxy=http://127.0.0.1:7890`，WSL 里的 `127.0.0.1` 指 WSL 自己 —— 必须在 Windows 上
> 把 Clash/代理开起来。确认不了就先绕开：
>
> ```bash
> env -u https_proxy -u http_proxy -u HTTPS_PROXY -u HTTP_PROXY npm install -g wrangler
> ```

## 2 · 登录

```bash
wrangler login
```

会在终端打印一个 `https://dash.cloudflare.com/oauth2/...` 链接。WSL 里可能打不开浏览器 ——
**把链接复制到 Windows 浏览器**里点「允许」即可，授权完终端会自动继续。

验证：`wrangler whoami` 能看到你的邮箱与账号 id。

## 3 · 建 D1（数据库）

```bash
wrangler d1 create xiaomao-sync
```

输出里有：

```
database_id = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

**把这一行 id 填进 `server/wrangler.jsonc`** 的 `"database_id": "REPLACE_WITH_D1_DATABASE_ID"`。
（这一步只填 id，不是密钥，直接发我也可以，我帮你改。）

## 4 · 建 R2（存备份文件）

```bash
wrangler r2 bucket create xiaomao-backups
```

> 第一次用 R2 会要求先在 Dashboard 启用 R2 并绑卡（有免费额度，10 GB 存储 + 无限下行）。

## 5 · 建表

```bash
wrangler d1 execute xiaomao-sync --remote --file schema.sql
```

脚本里全是 `CREATE ... IF NOT EXISTS`，重复跑不会破坏数据。

## 6 · 两个密钥

```bash
openssl rand -base64 48 | wrangler secret put JWT_SECRET
openssl rand -base64 48 | wrangler secret put CODE_PEPPER
```

> 值由 `openssl` 直接管进 wrangler，**不经过终端回显、不进仓库**。
> 这两条任何一条泄露都等于能伪造登录态，所以**不要在聊天里贴出来**。

## 7 · 发信通道（二选一）

### 7.1 Resend（最快，5 分钟）

1. 注册 <https://resend.com> → API Keys → 创建 `xiaomao-sync`；
2. 想用**自己的发件域名**：Domains → Add Domain → 按提示加 3 条 DNS 记录（在 Cloudflare DNS 里加，几分钟生效）；
   只想先跑通：直接用 `onboarding@resend.dev`，但它**只能发到你注册 Resend 用的那个邮箱**；
3. 落库与配置：

```bash
wrangler secret put RESEND_API_KEY          # 粘贴 API Key
# MAIL_FROM 在 wrangler.jsonc 的 vars 里改，例如：
#   "MAIL_FROM": "小耄记账 <no-reply@你的域名>"
```

### 7.2 Cloudflare Email Routing（零第三方，需要域名托管在 CF）

1. Dashboard → 你的域名 → **Email** → Email Routing → 启用（它会给域名加 MX 记录）；
2. 在 `wranger.jsonc` 的顶层加：

```jsonc
"send_email": [{ "name": "SEND_EMAIL" }]
```

3. `MAIL_FROM` 改成一个该域名下的地址（如 `no-reply@你的域名`）。

> 两条都没配时，`request-code` 会返回 **503 `mail_not_configured`** —— 这是故意的，
> 免得用户以为「发出去了」而干等。

## 8 · 部署

```bash
wrangler deploy
```

成功后会打印：

```
https://xiaomao-sync.<你的子域>.workers.dev
```

**把这个地址发我**（或者你自己填进 `lib/core/network/sync_endpoints.dart` 的白名单）。

### 8.1 绑自定义域名（强烈建议）

`*.workers.dev` 在国内经常很慢甚至连不通。绑自有域名：

1. 域名托管到 Cloudflare（NS 指过去）；
2. Workers → `xiaomao-sync` → Settings → **Domains & Routes** → Add → Custom domain →
   填 `sync.你的域名`；
3. 等证书签发（1–2 分钟），然后 `curl -i https://sync.你的域名/v1/backups` 应返回 **401**（说明服务活着）。

## 9 · 冒烟测试

```bash
BASE=https://xiaomao-sync.<你的子域>.workers.dev

# ① 未带 token 访问 → 401（服务活着且鉴权生效）
curl -i $BASE/v1/backups/latest

# ② 发验证码 → 204（不带 body），有发信就该收到邮件
curl -i -X POST $BASE/v1/auth/request-code \
  -H 'content-type: application/json' -d '{"email":"你的邮箱@example.com"}'

# ③ 用邮件里的 6 位码换 token
curl -s -X POST $BASE/v1/auth/verify \
  -H 'content-type: application/json' \
  -d '{"email":"你的邮箱@example.com","code":"123456"}'
# → {"accessToken":"...","refreshToken":"...","expiresIn":900}

# ④ 上传一份备份（先用 App 里「导出备份 JSON」拿一个真文件）
curl -i -X PUT $BASE/v1/backups/latest \
  -H "authorization: Bearer <accessToken>" \
  -H 'content-type: application/json' --data-binary @备份.json
# → 200 {"size":...,"sha256":"...","createdAt":"..."}

# ⑤ 原样取回，比对 sha256 是否一致
curl -s $BASE/v1/backups/latest -H "authorization: Bearer <accessToken>" | sha256sum
```

五条都过 = 服务端可用了。

## 10 · 常见问题

| 现象 | 原因 / 处理 |
|---|---|
| `npm install` 卡十几分钟 | 代理：见 §1 的 `env -u https_proxy ...` |
| `wrangler login` 打不开浏览器 | 复制终端链接到 Windows 浏览器；或直接在 PowerShell 里跑 wrangler |
| `d1 execute` 报 `database not found` | `wrangler.jsonc` 里的 `database_id` 还是占位符 |
| `request-code` 返回 503 | 发信通道没配（§7），或 `MAIL_FROM` 没填 |
| 邮件进垃圾箱 | 用自有域名 + SPF/DKIM（Resend 会给你记录）；`onboarding@resend.dev` 尤其容易被判垃圾 |
| 国内请求超时 | 绑自定义域名（§8.1）；`workers.dev` 在国内不稳 |
| `deploy` 报 R2 未启用 | Dashboard 里启用 R2 并绑卡 |

## 11 · 回滚 / 卸载

```bash
wrangler deployments list                 # 看历史版本
wrangler rollback                         # 回上一个版本
wrangler delete                           # 删掉 Worker（D1/R2 里的数据要另外删）
```

---

## 12 · 方案 B：全程在 Cloudflare 面板点（不装命令行）

适合不想在本机装 node/wrangler 的人。代价：**改代码要 push 才生效**，且免费版构建有额度限制。

### 12.1 先建资源（面板能建，无需命令行）

| 步骤 | 位置 | 做什么 |
|---|---|---|
| 1 | Dashboard → **Storage & Databases → D1** → Create database | 名字 `xiaomao-sync`；建好后页面顶部有 **Database ID**，复制 |
| 2 | Dashboard → **R2** → Create bucket | 名字 `xiaomao-backups`（首次用 R2 要绑卡，免费额度内不扣费） |
| 3 | D1 → 选中 `xiaomao-sync` → **Console** 标签 | 把 `server/schema.sql` 全文粘进输入框 → **Execute**（全是 `IF NOT EXISTS`，可重复跑） |
| 4 | 本地仓库 `server/wrangler.jsonc` | 把 `"database_id": "REPLACE_WITH_D1_DATABASE_ID"` 换成第 1 步的 id，**push 到 master** |

> 第 4 步是必须的：仓库里那份 wrangler 配置就是构建时用的配置，id 不对 deploy 一定失败。

### 12.2 建 Worker（连 GitHub，自动构建）

1. Dashboard → **Workers & Pages** → **Create** → **Workers** 标签 → **Import a repository**
   （按钮措辞会随版本变，大意是「从 Git 导入」；第一次会要求授权 GitHub，选你的账号并允许访问本仓库）。
2. 选仓库 `Xander-299/xiaomao-keeping`，生产分支 **`master`**。
3. 构建配置三项（**这里填错是最常见的失败原因**）：

| 字段 | 填什么 | 为什么 |
|---|---|---|
| **Root directory** | `server` | 不填会去仓库根找 `wrangler.jsonc`，找不到直接失败 |
| **Build command** | `npm install` | 把 `wrangler` 装进构建环境（它在 devDependencies 里） |
| **Deploy command** | `npx wrangler deploy` | 默认值就是它，确认一下即可 |

4. 点 **Deploy / Save and Deploy**。构建日志里会打印：

```
Uploaded xiaomao-sync
  https://xiaomao-sync.<你的子域>.workers.dev
```

### 12.3 配密钥与变量

Worker → **Settings** → **Variables and Secrets** → Add：

| 名称 | 类型 | 值 |
|---|---|---|
| `JWT_SECRET` | **Secret** | 随机长串（`openssl rand -base64 48`，或密码管理器生成 48 位） |
| `CODE_PEPPER` | **Secret** | 另一个随机长串（**不要和上面相同**） |
| `MAIL_FROM` | 明文 | `小耄记账 <no-reply@你的域名>` |
| `RESEND_API_KEY` | **Secret** | 用 Resend 发信时填（见 §7） |

> ⚠️ 变量改完必须**再 Deploy 一次**才生效（面板会提示 Redeploy）。密钥一旦 Save 就只能覆盖、不能回看。

### 12.4 绑自定义域名（国内强烈建议）

Worker → **Settings** → **Domains & Routes** → Add → **Custom domain** → 填 `sync.你的域名`
（域名需已托管在 Cloudflare）。证书 1–2 分钟签发，然后 `curl -i https://sync.你的域名/v1/backups` 应返回 **401**。

### 12.5 以后怎么更新

推到 `master` 且改动落在 `server/**` 时，Workers Builds 会自动重新构建部署。
不想每次 push 都触发 → Builds 的 **Build watch paths** 设成 `server/*`。

### 12.6 方案 B 常见失败

| 报错 | 原因 |
|---|---|
| `Could not find wrangler.jsonc` | Root directory 没填 `server` |
| `Couldn't find a D1 DB with that name/id` | §12.1 第 4 步没做，或 id 拼错 |
| `wrangler: not found` | Build command 没装依赖；改成 `npm install` |
| 部署成功但 `request-code` 返回 503 | `MAIL_FROM` / `RESEND_API_KEY` 没配或没 redeploy |
| 改了变量不生效 | 忘了 Redeploy |

### 12.7 为什么不用 Pages

- Pages 的定位是「静态站点 + 可选 Functions」，我们没有静态资源，等于白背一套构建流程；
- Pages Functions 的 D1/R2 绑定要在 **Pages 项目设置**里另配一遍，而 Workers 直接读 `wrangler.jsonc`，只有一份真相；
- Cloudflare 官方现在建议新项目用 Workers（Pages 仍在维护，但不再是推荐路径）。

### 12.8 方案对比

| | 方案 A（CLI） | 方案 B（Dashboard + Git） |
|---|---|---|
| 前置 | 本机 node + wrangler | 只要浏览器 |
| 首次部署 | 5 条命令 | 点 6 下 + 填 3 个字段 |
| 改配置 | 改完 `wrangler deploy` | push 后自动构建 |
| 密钥 | `wrangler secret put` | 面板 Variables and Secrets |
| 适合 | 频繁改服务端 | 一次性上线、不想碰命令行 |
