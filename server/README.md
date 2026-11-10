# 小耄记账 · 云同步服务端（Cloudflare Workers）

实现 `docs/spec/SPEC-P6-cloud-sync.md` §9 的契约。**只做**：邮箱验证码登录、备份上传/下载/列表、注销硬删、限流。

- 运行时依赖：**0 个**（只用 Workers 自带的 `fetch` / WebCrypto / D1 / R2）
- 开发依赖：`typescript` / `@cloudflare/workers-types` / `wrangler`
- 数据：D1 存「用户 / 验证码哈希 / refresh token 哈希 / 备份元数据」，R2 存备份正文

## 本地跑起来（不需要任何密钥）

```bash
cd server
npm install                     # ⚠️ 若 shell 里有 NODE_ENV=production，要 npm install --include=dev
npm run typecheck               # tsc --noEmit
npm test                        # node --test src/*.test.ts（13 条纯函数用例，无需网络）
cp .dev.vars.example .dev.vars  # 本地开发密钥；DEV_ECHO_CODE=1 会把验证码打到控制台
npx wrangler d1 create xiaomao-sync            # 拿到 database_id 填进 wrangler.jsonc
npx wrangler d1 execute xiaomao-sync --local --file schema.sql
npm run dev                     # http://127.0.0.1:8787
```

本地冒烟（`DEV_ECHO_CODE=1` 时验证码在 wrangler 控制台）：

```bash
curl -i -X POST localhost:8787/v1/auth/request-code \
  -H 'content-type: application/json' -d '{"email":"me@example.com"}'
# → 204，控制台打印验证码

TOKEN=$(curl -s -X POST localhost:8787/v1/auth/verify \
  -H 'content-type: application/json' \
  -d '{"email":"me@example.com","code":"<控制台那 6 位>"}' | jq -r .accessToken)

curl -i -X PUT localhost:8787/v1/backups/latest \
  -H "authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' --data-binary @backup.json
# → 200 {"size":...,"sha256":"...","createdAt":"..."}

curl -s localhost:8787/v1/backups/latest -H "authorization: Bearer $TOKEN" | head -c 200
```

## 部署（你需要执行的，我不碰你的账号）

```bash
npx wrangler login                       # 走浏览器授权，凭据留在你本机
npx wrangler d1 create xiaomao-sync      # 把返回的 database_id 填进 wrangler.jsonc
npx wrangler r2 bucket create xiaomao-backups
npx wrangler d1 execute xiaomao-sync --remote --file schema.sql

# 三个密钥（值只在你机器上，别贴到聊天/仓库/issue）
openssl rand -base64 48 | npx wrangler secret put JWT_SECRET
openssl rand -base64 48 | npx wrangler secret put CODE_PEPPER
npx wrangler secret put RESEND_API_KEY   # 用 Resend 发信时才需要

npx wrangler deploy                      # 得到 https://xiaomao-sync.<子域>.workers.dev
```

发信二选一：

| 方式 | 前提 | 说明 |
|---|---|---|
| **Resend**（最快跑通） | 注册 + 验证发件域名 → 拿 API Key | `MAIL_FROM` 改成验证过的发件人 |
| **Cloudflare Email Routing** | 域名已托管在 Cloudflare | 在 `wrangler.jsonc` 加 `send_email` 绑定，代码已支持（`env.SEND_EMAIL`） |

发信没配好时 `request-code` 会返回 **503 `mail_not_configured`**（而不是假装成功再让用户等一封永远不来的信）。

## 安全设计（改代码前必读）

- **不泄露邮箱是否存在**：`request-code` 永远 204，验证码错误只说 `code_mismatch`；
- **跨用户一律 404**：不是 403 —— 不告诉攻击者「这条存在，但不是你的」；
- **验证码**：6 位 CSPRNG、绑定邮箱 + pepper 哈希、5 分钟过期、60 秒重发冷却、单日上限、最多试 5 次；
- **refresh token**：随机 32 字节，只存 SHA-256；每次刷新**轮换**（旧的立刻 revoke）；
- **注销 = 硬删**：先删 R2 对象再删 D1 行（反过来就找不到 key 了）；
- **日志只记**路由 + 错误类型，**不记邮箱、不记验证码、不记备份正文**；
- 备份正文 20 MB 上限，每用户只留最近 5 份。

## 已知限制

1. **国内访问**：`*.workers.dev` 在国内经常很慢甚至连不通；正式上线建议绑**自有域名**并实测。
   备份接口是「偶发、可重试」的场景，慢一点可接受；如果要频繁同步（P6.4），可能要换回 VPS ——
   接口契约保持不变，换实现只动这一个目录。
2. **没有集成测试**：Worker 的端到端行为（D1/R2 真实交互）要用 `wrangler dev` 手测，
   这里的 `npm test` 只覆盖纯函数层（JWT / 哈希 / 邮箱规整 / 限流常量）。
3. **单区域 D1**：免费版没有只读副本，跨洲访问有延迟。
