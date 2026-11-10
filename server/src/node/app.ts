/**
 * HTTP 处理（Node 版）：与 Cloudflare 版**同一套契约、同一套语义**，
 * 只把 D1/R2 换成了 SQLite + 本地文件。
 *
 * 刻意做成「store + config → handler」的纯函数形状，测试可以直接
 * `http.createServer(createHandler(store, cfg))` 起一个真服务打真请求 —— 这是
 * Cloudflare 版做不到的（那边要有 workerd 才能跑）。
 */

import type { IncomingMessage, ServerResponse } from 'node:http';

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
} from '../core.ts';
import type { Store } from './store.ts';

export interface AppConfig {
  jwtSecret: string;
  codePepper: string;
  mailFrom?: string;
  resendApiKey?: string;
  /** 本地/测试：验证码不走邮件，交给 onDevCode 或打到 stdout。 */
  devEchoCode?: boolean;
  /** 测试钩子（生产不传）。 */
  onDevCode?: (email: string, code: string) => void;
  maxBackupBytes?: number;
  now?: () => number;
}

const send = (res: ServerResponse, status: number, body: unknown): void => {
  const text = JSON.stringify(body);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(text),
    'cache-control': 'no-store',
  });
  res.end(text);
};

const sendEmpty = (res: ServerResponse, status: number, headers: Record<string, string> = {}): void => {
  res.writeHead(status, headers);
  res.end();
};

const sendRaw = (res: ServerResponse, body: Uint8Array): void => {
  res.writeHead(200, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': body.byteLength,
    'cache-control': 'no-store',
  });
  res.end(Buffer.from(body));
};

async function readBody(req: IncomingMessage, limit: number): Promise<Uint8Array | null> {
  const chunks: Buffer[] = [];
  let total = 0;
  for await (const chunk of req) {
    const buf = chunk as Buffer;
    total += buf.byteLength;
    if (total > limit) return null;
    chunks.push(buf);
  }
  return new Uint8Array(Buffer.concat(chunks));
}

async function readJson(req: IncomingMessage): Promise<Record<string, unknown> | null> {
  const raw = await readBody(req, 64 * 1024);
  if (!raw) return null;
  try {
    const parsed: unknown = JSON.parse(Buffer.from(raw).toString('utf8'));
    return parsed && typeof parsed === 'object' ? (parsed as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

export function createHandler(store: Store, cfg: AppConfig) {
  const now = cfg.now ?? (() => Math.floor(Date.now() / 1000));
  const maxBackup = cfg.maxBackupBytes ?? MAX_BACKUP_BYTES;

  async function issueTokens(userId: string) {
    const t = now();
    const accessToken = await signJwt({ sub: userId, iat: t, exp: t + ACCESS_TTL_SEC }, cfg.jwtSecret);
    const refreshToken = randomToken(32);
    store.insertRefresh(
      crypto.randomUUID(),
      userId,
      await sha256Hex(refreshToken),
      t + REFRESH_TTL_SEC,
      t,
    );
    return { accessToken, refreshToken, expiresIn: ACCESS_TTL_SEC };
  }

  async function userIdOf(req: IncomingMessage): Promise<string | null> {
    const token = parseBearer(req.headers.authorization ?? null);
    if (!token) return null;
    const claims = await verifyJwt(token, cfg.jwtSecret, now());
    return claims?.sub ?? null;
  }

  async function sendCode(email: string, code: string): Promise<boolean> {
    if (cfg.devEchoCode) {
      if (cfg.onDevCode) cfg.onDevCode(email, code);
      else console.log(`[dev] login code for ${email}: ${code}`);
      return true;
    }
    if (!cfg.mailFrom || !cfg.resendApiKey) return false;

    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        authorization: `Bearer ${cfg.resendApiKey}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        from: cfg.mailFrom,
        to: [email],
        subject: '小耄记账 · 登录验证码',
        text: `你的验证码是 ${code}，5 分钟内有效。\n\n不是你本人操作？忽略这封邮件即可，你的账本不会被动。`,
      }),
    });
    return res.ok;
  }

  return async function handler(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const url = new URL(req.url ?? '/', 'http://localhost');
    const route = `${req.method} ${url.pathname}`;

    try {
      switch (route) {
        // ── 登录 ────────────────────────────────────────────────────
        case 'POST /v1/auth/request-code': {
          const body = await readJson(req);
          const email = normalizeEmail(body?.email);
          if (!email) return send(res, 400, { error: 'invalid_email' });

          const t = now();
          const ip =
            (req.headers['x-forwarded-for'] as string | undefined)?.split(',')[0]?.trim() ??
            req.socket.remoteAddress ??
            '';

          // 冷却与日上限看的是 `code_sends`（发码账本），**不是** `auth_codes` ——
          // 登录成功会清掉验证码，如果限流也看那张表，「登录一次再发」就能绕过。
          const lastSent = store.lastSendAt(email);
          if (lastSent !== null && t - lastSent < RESEND_COOLDOWN_SEC) {
            return sendEmpty(res, 429, {
              'retry-after': String(RESEND_COOLDOWN_SEC - (t - lastSent)),
            });
          }

          const dayStart = t - (t % 86400);
          if (
            store.countSendsByEmail(email, dayStart) >= DAILY_CODE_CAP ||
            store.countSendsByIp(ip, dayStart) >= DAILY_CODE_CAP * 3
          ) {
            return send(res, 429, { error: 'daily_limit' });
          }

          const code = generateCode(6);
          store.recordSend(email, ip, t);
          store.clearCodes(email, t);
          store.insertCode(email, await codeHashOf(email, code, cfg.codePepper), t + CODE_TTL_SEC, t, ip);

          if (!(await sendCode(email, code))) {
            store.clearCodes(email, t);
            return send(res, 503, { error: 'mail_not_configured' });
          }
          return sendEmpty(res, 204);
        }

        case 'POST /v1/auth/verify': {
          const body = await readJson(req);
          const email = normalizeEmail(body?.email);
          const code = typeof body?.code === 'string' ? body.code.trim() : '';
          if (!email || !/^\d{6}$/.test(code)) return send(res, 400, { error: 'invalid_input' });

          const t = now();
          const row = store.lastCode(email);
          if (!row || row.expires_at < t) return send(res, 400, { error: 'code_expired' });
          if (row.attempts >= MAX_CODE_ATTEMPTS) return send(res, 429, { error: 'too_many_attempts' });

          const expected = await codeHashOf(email, code, cfg.codePepper);
          if (!constantTimeEqual(expected, row.code_hash)) {
            store.bumpAttempts(email);
            return send(res, 400, { error: 'code_mismatch' });
          }

          store.clearCodes(email, t);
          store.ensureUser(email, t);
          const userId = store.userIdByEmail(email);
          if (!userId) return send(res, 500, { error: 'internal' });
          return send(res, 200, await issueTokens(userId));
        }

        case 'POST /v1/auth/refresh': {
          const body = await readJson(req);
          const token = typeof body?.refreshToken === 'string' ? body.refreshToken : '';
          if (!token) return send(res, 400, { error: 'invalid_input' });

          const t = now();
          const row = store.findRefresh(await sha256Hex(token));
          if (!row || row.revoked_at !== null || row.expires_at < t) {
            return send(res, 401, { error: 'invalid_refresh_token' });
          }
          store.revokeRefresh(row.id, t); // 轮换
          return send(res, 200, await issueTokens(row.user_id));
        }

        case 'POST /v1/auth/logout': {
          const body = await readJson(req);
          const token = typeof body?.refreshToken === 'string' ? body.refreshToken : '';
          if (token) store.revokeRefreshByHash(await sha256Hex(token), now());
          return sendEmpty(res, 204);
        }

        // ── 注销 ────────────────────────────────────────────────────
        case 'DELETE /v1/account': {
          const userId = await userIdOf(req);
          if (!userId) return send(res, 401, { error: 'unauthorized' });
          store.removeUserDir(userId); // 先删文件（删了行就找不到 key）
          store.deleteUser(userId);
          return sendEmpty(res, 204);
        }

        // ── 备份 ────────────────────────────────────────────────────
        case 'PUT /v1/backups/latest': {
          const userId = await userIdOf(req);
          if (!userId) return send(res, 401, { error: 'unauthorized' });

          const raw = await readBody(req, maxBackup);
          if (raw === null) return send(res, 413, { error: 'too_large' });
          if (raw.byteLength === 0) return send(res, 400, { error: 'empty_body' });

          const t = now();
          const digest = await sha256Hex(Buffer.from(raw).toString('utf8'));
          const key = store.writeBackup(userId, raw, t);
          store.insertBackup({
            id: crypto.randomUUID(),
            user_id: userId,
            object_key: key,
            size: raw.byteLength,
            sha256: digest,
            created_at: t,
          });

          for (const old of store.backupsBeyond(userId, KEEP_SNAPSHOTS)) {
            store.removeBackup(old.object_key);
            store.deleteBackupRow(old.id);
          }

          return send(res, 200, {
            size: raw.byteLength,
            sha256: digest,
            createdAt: new Date(t * 1000).toISOString(),
          });
        }

        case 'GET /v1/backups/latest': {
          const userId = await userIdOf(req);
          if (!userId) return send(res, 401, { error: 'unauthorized' });
          const row = store.latestBackup(userId);
          if (!row) return send(res, 404, { error: 'not_found' });
          const bytes = store.readBackup(row.object_key);
          if (!bytes) return send(res, 404, { error: 'not_found' });
          return sendRaw(res, bytes);
        }

        case 'GET /v1/backups': {
          const userId = await userIdOf(req);
          if (!userId) return send(res, 401, { error: 'unauthorized' });
          return send(
            res,
            200,
            store.listBackups(userId).map((r) => ({
              id: r.id,
              size: r.size,
              sha256: r.sha256,
              createdAt: new Date(r.created_at * 1000).toISOString(),
            })),
          );
        }

        default:
          return send(res, 404, { error: 'not_found' });
      }
    } catch (e) {
      // 只记路由与错误类型：不记邮箱、不记验证码、不记备份正文
      console.error(`[error] ${route} ${(e as Error)?.name ?? 'unknown'}`);
      if (!res.headersSent) send(res, 500, { error: 'internal' });
    }
  };
}
