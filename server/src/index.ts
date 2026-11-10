/**
 * 小耄记账 · 云同步服务端（Cloudflare Workers + D1 + R2）
 *
 * 契约见 `docs/spec/SPEC-P6-cloud-sync.md` §9。这个文件只做四件事：
 *   1. 邮箱验证码登录（无密码）；
 *   2. 备份上传 / 下载 / 列表（**只读同步**，P6.3 范围）；
 *   3. 注销即硬删（用户、token、备份元数据、R2 对象）；
 *   4. 限流与防爆破。
 *
 * 明确不做：账本双向同步（P6.4）、多用户共享账本、埋点、日志写正文。
 *
 * 安全约定（改代码前先读）：
 *   - 任何响应都**不泄露邮箱是否存在**（request-code 永远 204）；
 *   - 跨用户访问一律 404（不是 403 —— 不泄露「存在但不是你的」）；
 *   - 日志只记 userId / 状态码 / 字节数，**绝不记备份正文或验证码**；
 *   - 所有密钥来自 `env`（wrangler secret），仓库里只有 `.dev.vars.example`。
 */

import {
  ACCESS_TTL_SEC,
  CODE_TTL_SEC,
  DAILY_CODE_CAP,
  KEEP_SNAPSHOTS,
  MAX_BACKUP_BYTES,
  MAX_CODE_ATTEMPTS,
  REFRESH_TTL_SEC,
  RESEND_COOLDOWN_SEC,
  codeHashOf,
  constantTimeEqual,
  generateCode,
  normalizeEmail,
  parseBearer,
  randomToken,
  sha256Hex,
  signJwt,
  verifyJwt,
} from './core';

export interface Env {
  DB: D1Database;
  BUCKET: R2Bucket;
  /** HS256 签名密钥（wrangler secret put JWT_SECRET）。 */
  JWT_SECRET: string;
  /** 验证码哈希的 pepper（与 JWT_SECRET 分开，泄一个不至于连坐）。 */
  CODE_PEPPER: string;
  /** Resend 发信（可选；与 SEND_EMAIL 二选一）。 */
  RESEND_API_KEY?: string;
  /** Cloudflare Email Workers 的 send_email 绑定（可选）。 */
  SEND_EMAIL?: { send: (msg: unknown) => Promise<void> };
  /** 发件人，形如 `小耄记账 <no-reply@example.com>`。 */
  MAIL_FROM?: string;
  /** 仅本地开发：把验证码打到控制台（生产必须不设）。 */
  DEV_ECHO_CODE?: string;
}

const now = (): number => Math.floor(Date.now() / 1000);

const json = (status: number, body: unknown): Response =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8' },
  });

const noContent = (): Response => new Response(null, { status: 204 });

const fail = (status: number, code: string): Response => json(status, { error: code });

// ── 鉴权 ──────────────────────────────────────────────────────────────

async function userIdOf(req: Request, env: Env): Promise<string | null> {
  const token = parseBearer(req.headers.get('authorization'));
  if (!token) return null;
  const claims = await verifyJwt(token, env.JWT_SECRET, now());
  return claims?.sub ?? null;
}

async function issueTokens(
  env: Env,
  userId: string,
): Promise<{ accessToken: string; refreshToken: string; expiresIn: number }> {
  const t = now();
  const accessToken = await signJwt(
    { sub: userId, iat: t, exp: t + ACCESS_TTL_SEC },
    env.JWT_SECRET,
  );
  const refreshToken = randomToken(32);
  await env.DB.prepare(
    'INSERT INTO refresh_tokens (id, user_id, token_hash, expires_at, created_at) VALUES (?, ?, ?, ?, ?)',
  )
    .bind(crypto.randomUUID(), userId, await sha256Hex(refreshToken), t + REFRESH_TTL_SEC, t)
    .run();
  return { accessToken, refreshToken, expiresIn: ACCESS_TTL_SEC };
}

// ── 发信 ──────────────────────────────────────────────────────────────

async function sendLoginCode(env: Env, email: string, code: string): Promise<boolean> {
  if (env.DEV_ECHO_CODE === '1') {
    console.log(`[dev] login code for ${email}: ${code}`);
    return true;
  }
  const from = env.MAIL_FROM;
  if (!from) return false;

  const subject = '小耄记账 · 登录验证码';
  const text = `你的验证码是 ${code}，5 分钟内有效。\n\n不是你本人操作？忽略这封邮件即可，你的账本不会被动。`;

  if (env.RESEND_API_KEY) {
    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        authorization: `Bearer ${env.RESEND_API_KEY}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify({ from, to: [email], subject, text }),
    });
    return res.ok;
  }

  if (env.SEND_EMAIL) {
    await env.SEND_EMAIL.send({ from, to: email, subject, text });
    return true;
  }

  return false;
}

// ── 路由 ──────────────────────────────────────────────────────────────

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    const route = `${req.method} ${url.pathname}`;
    try {
      switch (route) {
        case 'POST /v1/auth/request-code':
          return await requestCode(req, env);
        case 'POST /v1/auth/verify':
          return await verifyCode(req, env);
        case 'POST /v1/auth/refresh':
          return await refresh(req, env);
        case 'POST /v1/auth/logout':
          return await logout(req, env);
        case 'DELETE /v1/account':
          return await deleteAccount(req, env);
        case 'PUT /v1/backups/latest':
          return await putBackup(req, env);
        case 'GET /v1/backups/latest':
          return await getLatestBackup(req, env);
        case 'GET /v1/backups':
          return await listBackups(req, env);
        default:
          return fail(404, 'not_found');
      }
    } catch (e) {
      // 只记类型与路由，不记正文、不记邮箱
      console.error(`[error] ${route} ${(e as Error)?.name ?? 'unknown'}`);
      return fail(500, 'internal');
    }
  },
};

// ── 登录 ──────────────────────────────────────────────────────────────

async function requestCode(req: Request, env: Env): Promise<Response> {
  const body = (await req.json().catch(() => null)) as { email?: unknown } | null;
  const email = normalizeEmail(body?.email);
  if (!email) return fail(400, 'invalid_email');

  const t = now();
  const ip = req.headers.get('cf-connecting-ip') ?? '';

  // 冷却：同邮箱 60 秒内只发一次
  const last = await env.DB.prepare(
    'SELECT created_at FROM auth_codes WHERE email = ? ORDER BY created_at DESC LIMIT 1',
  )
    .bind(email)
    .first<{ created_at: number }>();
  if (last && t - last.created_at < RESEND_COOLDOWN_SEC) {
    return new Response(null, {
      status: 429,
      headers: { 'retry-after': String(RESEND_COOLDOWN_SEC - (t - last.created_at)) },
    });
  }

  // 日上限：按邮箱与 IP 各算一次（防换邮箱刷、防单 IP 刷）
  const dayStart = t - (t % 86400);
  const byEmail = await env.DB.prepare(
    'SELECT COUNT(*) AS n FROM auth_codes WHERE email = ? AND created_at >= ?',
  )
    .bind(email, dayStart)
    .first<{ n: number }>();
  const byIp = await env.DB.prepare(
    'SELECT COUNT(*) AS n FROM auth_codes WHERE ip = ? AND created_at >= ?',
  )
    .bind(ip, dayStart)
    .first<{ n: number }>();
  if ((byEmail?.n ?? 0) >= DAILY_CODE_CAP || (byIp?.n ?? 0) >= DAILY_CODE_CAP * 3) {
    return fail(429, 'daily_limit');
  }

  const code = generateCode(6);
  // 先落库再发信：发信失败用户还能重试，反过来会「收到码但库里没有」
  await env.DB.prepare(
    'DELETE FROM auth_codes WHERE email = ? OR expires_at < ?',
  )
    .bind(email, t)
    .run();
  await env.DB.prepare(
    'INSERT INTO auth_codes (email, code_hash, expires_at, attempts, created_at, ip) VALUES (?, ?, ?, 0, ?, ?)',
  )
    .bind(email, await codeHashOf(email, code, env.CODE_PEPPER), t + CODE_TTL_SEC, t, ip)
    .run();

  const sent = await sendLoginCode(env, email, code);
  if (!sent) {
    // 没配发信通道 = 部署问题，不是用户问题；把这个码作废以免「幽灵验证码」
    await env.DB.prepare('DELETE FROM auth_codes WHERE email = ?').bind(email).run();
    return fail(503, 'mail_not_configured');
  }

  // 无论邮箱是否存在都 204（防枚举）
  return noContent();
}

async function verifyCode(req: Request, env: Env): Promise<Response> {
  const body = (await req.json().catch(() => null)) as
    | { email?: unknown; code?: unknown }
    | null;
  const email = normalizeEmail(body?.email);
  const code = typeof body?.code === 'string' ? body.code.trim() : '';
  if (!email || !/^\d{6}$/.test(code)) return fail(400, 'invalid_input');

  const t = now();
  const row = await env.DB.prepare(
    'SELECT code_hash, expires_at, attempts FROM auth_codes WHERE email = ? ORDER BY created_at DESC LIMIT 1',
  )
    .bind(email)
    .first<{ code_hash: string; expires_at: number; attempts: number }>();

  if (!row || row.expires_at < t) return fail(400, 'code_expired');
  if (row.attempts >= MAX_CODE_ATTEMPTS) return fail(429, 'too_many_attempts');

  const expected = await codeHashOf(email, code, env.CODE_PEPPER);
  if (!constantTimeEqual(expected, row.code_hash)) {
    await env.DB.prepare('UPDATE auth_codes SET attempts = attempts + 1 WHERE email = ?')
      .bind(email)
      .run()
      .catch(() => undefined);
    return fail(400, 'code_mismatch');
  }

  // 用过即焚
  await env.DB.prepare('DELETE FROM auth_codes WHERE email = ?').bind(email).run();

  const existing = await env.DB.prepare('SELECT id FROM users WHERE email = ?')
    .bind(email)
    .first<{ id: string }>();
  const userId = existing?.id ?? crypto.randomUUID();
  if (!existing) {
    await env.DB.prepare('INSERT INTO users (id, email, created_at) VALUES (?, ?, ?)')
      .bind(userId, email, t)
      .run();
  }

  return json(200, await issueTokens(env, userId));
}

async function refresh(req: Request, env: Env): Promise<Response> {
  const body = (await req.json().catch(() => null)) as
    | { refreshToken?: unknown }
    | null;
  const token = typeof body?.refreshToken === 'string' ? body.refreshToken : '';
  if (!token) return fail(400, 'invalid_input');

  const t = now();
  const hash = await sha256Hex(token);
  const row = await env.DB.prepare(
    'SELECT id, user_id, expires_at, revoked_at FROM refresh_tokens WHERE token_hash = ?',
  )
    .bind(hash)
    .first<{ id: string; user_id: string; expires_at: number; revoked_at: number | null }>();

  if (!row || row.revoked_at !== null || row.expires_at < t) {
    return fail(401, 'invalid_refresh_token');
  }

  // 轮换：旧 token 立刻作废
  await env.DB.prepare('UPDATE refresh_tokens SET revoked_at = ? WHERE id = ?')
    .bind(t, row.id)
    .run();

  return json(200, await issueTokens(env, row.user_id));
}

async function logout(req: Request, env: Env): Promise<Response> {
  const body = (await req.json().catch(() => null)) as
    | { refreshToken?: unknown }
    | null;
  const token = typeof body?.refreshToken === 'string' ? body.refreshToken : '';
  if (token) {
    await env.DB.prepare(
      'UPDATE refresh_tokens SET revoked_at = ? WHERE token_hash = ? AND revoked_at IS NULL',
    )
      .bind(now(), await sha256Hex(token))
      .run();
  }
  return noContent();
}

async function deleteAccount(req: Request, env: Env): Promise<Response> {
  const userId = await userIdOf(req, env);
  if (!userId) return fail(401, 'unauthorized');

  // 1) R2：先删对象（删元数据之后就找不到 key 了）
  const listed = await env.BUCKET.list({ prefix: `u/${userId}/` });
  for (const obj of listed.objects) {
    await env.BUCKET.delete(obj.key);
  }
  // 2) D1：硬删（不是打标记 —— 注销必须真的删掉）
  await env.DB.batch([
    env.DB.prepare('DELETE FROM backups WHERE user_id = ?').bind(userId),
    env.DB.prepare('DELETE FROM refresh_tokens WHERE user_id = ?').bind(userId),
    env.DB.prepare(
      'DELETE FROM auth_codes WHERE email IN (SELECT email FROM users WHERE id = ?)',
    ).bind(userId),
    env.DB.prepare('DELETE FROM users WHERE id = ?').bind(userId),
  ]);

  return noContent();
}

// ── 备份（只读同步：PUT / GET latest / LIST）────────────────────────────

async function putBackup(req: Request, env: Env): Promise<Response> {
  const userId = await userIdOf(req, env);
  if (!userId) return fail(401, 'unauthorized');

  const buf = await req.arrayBuffer();
  if (buf.byteLength === 0) return fail(400, 'empty_body');
  if (buf.byteLength > MAX_BACKUP_BYTES) return fail(413, 'too_large');

  const t = now();
  const key = `u/${userId}/${t}-${crypto.randomUUID()}.json`;
  const digest = await sha256Hex(new TextDecoder().decode(buf));

  await env.BUCKET.put(key, buf, { httpMetadata: { contentType: 'application/json' } });
  await env.DB.prepare(
    'INSERT INTO backups (id, user_id, object_key, size, sha256, created_at) VALUES (?, ?, ?, ?, ?, ?)',
  )
    .bind(crypto.randomUUID(), userId, key, buf.byteLength, digest, t)
    .run();

  // 只留最近 KEEP_SNAPSHOTS 份（含刚上传的）
  const old = await env.DB.prepare(
    'SELECT id, object_key FROM backups WHERE user_id = ? ORDER BY created_at DESC LIMIT -1 OFFSET ?',
  )
    .bind(userId, KEEP_SNAPSHOTS)
    .all<{ id: string; object_key: string }>();
  for (const row of old.results ?? []) {
    await env.BUCKET.delete(row.object_key);
    await env.DB.prepare('DELETE FROM backups WHERE id = ?').bind(row.id).run();
  }

  return json(200, {
    size: buf.byteLength,
    sha256: digest,
    createdAt: new Date(t * 1000).toISOString(),
  });
}

async function getLatestBackup(req: Request, env: Env): Promise<Response> {
  const userId = await userIdOf(req, env);
  if (!userId) return fail(401, 'unauthorized');

  const row = await env.DB.prepare(
    'SELECT object_key FROM backups WHERE user_id = ? ORDER BY created_at DESC LIMIT 1',
  )
    .bind(userId)
    .first<{ object_key: string }>();
  if (!row) return fail(404, 'not_found'); // 跨用户同样 404，不泄露存在性

  const obj = await env.BUCKET.get(row.object_key);
  if (!obj) return fail(404, 'not_found');

  return new Response(obj.body, {
    status: 200,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
    },
  });
}

async function listBackups(req: Request, env: Env): Promise<Response> {
  const userId = await userIdOf(req, env);
  if (!userId) return fail(401, 'unauthorized');

  const rows = await env.DB.prepare(
    'SELECT id, size, sha256, created_at FROM backups WHERE user_id = ? ORDER BY created_at DESC LIMIT 20',
  )
    .bind(userId)
    .all<{ id: string; size: number; sha256: string; created_at: number }>();

  return json(
    200,
    (rows.results ?? []).map((r) => ({
      id: r.id,
      size: r.size,
      sha256: r.sha256,
      createdAt: new Date(r.created_at * 1000).toISOString(),
    })),
  );
}
