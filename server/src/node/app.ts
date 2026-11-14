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
import { sendSmtpMail, type SmtpConfig } from './mail.ts';

export interface AppConfig {
  jwtSecret: string;
  codePepper: string;
  mailFrom?: string;
  /** `resend`（默认）或 `smtp`（126 / 163 / QQ 授权码）。 */
  mailProvider?: 'resend' | 'smtp';
  smtp?: SmtpConfig;
  resendApiKey?: string;
  /** 本地/测试：验证码不走邮件，交给 onDevCode 或打到 stdout。 */
  devEchoCode?: boolean;
  /** 验证码有效期（秒）；默认 300。联调时可临时放宽。 */
  codeTtlSec?: number;
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

async function readJson(
  req: IncomingMessage,
  limit = 64 * 1024,
): Promise<Record<string, unknown> | null> {
  const raw = await readBody(req, limit);
  if (!raw) return null;
  try {
    const parsed: unknown = JSON.parse(Buffer.from(raw).toString('utf8'));
    return parsed && typeof parsed === 'object' ? (parsed as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

const SYNC_ENTITIES = new Set([
  'book',
  'account',
  'category',
  'transaction',
  'budget',
  // 设置项（P6.4b）：bookId / id 都是 'global' 哨兵值，payload 是白名单三键的 JSON。
  'setting',
]);
const MAX_SYNC_CHANGES = 200;
const MAX_SYNC_BODY = 2 * 1024 * 1024;
const MAX_SYNC_PAYLOAD = 64 * 1024;

interface SyncChangeOut {
  bookId: string;
  entity: string;
  id: string;
  updatedAt: number;
  deleted: boolean;
  payload: Record<string, unknown>;
}

function parseSyncChange(raw: unknown): SyncChangeOut | null {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  const o = raw as Record<string, unknown>;
  const entity = typeof o.entity === 'string' ? o.entity : '';
  const bookId = typeof o.bookId === 'string' ? o.bookId.trim() : '';
  const id = typeof o.id === 'string' ? o.id.trim() : '';
  const updatedAt =
    typeof o.updatedAt === 'number' && Number.isFinite(o.updatedAt)
      ? Math.floor(o.updatedAt)
      : -1;
  const deleted = o.deleted === true;
  const payload = o.payload;
  if (!SYNC_ENTITIES.has(entity)) return null;
  if (!bookId || bookId.length > 64 || !id || id.length > 64) return null;
  if (updatedAt < 0) return null;
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) return null;
  if (Buffer.byteLength(JSON.stringify(payload)) > MAX_SYNC_PAYLOAD) return null;
  return {
    bookId,
    entity,
    id,
    updatedAt,
    deleted,
    payload: payload as Record<string, unknown>,
  };
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
    const userId = claims?.sub;
    if (!userId) return null;
    // JWT 只是签名有效；注销是硬删，用户没了就必须 401（否则能重新上传备份）
    return store.userExists(userId) ? userId : null;
  }

  async function sendCode(email: string, code: string): Promise<boolean> {
    if (cfg.devEchoCode) {
      if (cfg.onDevCode) cfg.onDevCode(email, code);
      else console.log(`[dev] login code for ${email}: ${code}`);
      return true;
    }

    const subject = '小耄记账 · 登录验证码';
    const text = `你的验证码是 ${code}，5 分钟内有效。\n\n不是你本人操作？忽略这封邮件即可，你的账本不会被动。`;

    // SMTP（126 / 163 / QQ 邮箱授权码）：无需域名，适合个人自建
    if (cfg.mailProvider === 'smtp' && cfg.smtp && cfg.mailFrom) {
      try {
        await sendSmtpMail(cfg.smtp, {
          from: cfg.mailFrom,
          to: email,
          subject,
          text,
        });
        return true;
      } catch (error) {
        // 不打印授权码；只留失败原因
        console.error(`[mail] SMTP 发送失败：${(error as Error).message}`);
        return false;
      }
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
        subject,
        text,
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
          store.insertCode(email, await codeHashOf(email, code, cfg.codePepper), t + (cfg.codeTtlSec ?? CODE_TTL_SEC), t, ip);

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

        // ── 双向同步（P6.4）─────────────────────────────────────────
        case 'POST /v1/sync/push': {
          const userId = await userIdOf(req);
          if (!userId) return send(res, 401, { error: 'unauthorized' });
          const body = await readJson(req, MAX_SYNC_BODY);
          const rawChanges = body?.changes;
          if (!Array.isArray(rawChanges) || rawChanges.length === 0) {
            return send(res, 400, { error: 'invalid_input' });
          }
          if (rawChanges.length > MAX_SYNC_CHANGES) {
            return send(res, 413, { error: 'too_many_changes' });
          }
          const parsed: SyncChangeOut[] = [];
          for (const raw of rawChanges) {
            const change = parseSyncChange(raw);
            if (!change) return send(res, 400, { error: 'invalid_change' });
            parsed.push(change);
          }

          let applied = 0;
          const conflicts: SyncChangeOut[] = [];
          for (const change of parsed) {
            const result = store.syncApply(
              userId,
              {
                bookId: change.bookId,
                entity: change.entity,
                id: change.id,
                updatedAt: change.updatedAt,
                deleted: change.deleted,
                payload: JSON.stringify(change.payload),
              },
              now(),
            );
            if (result.applied) {
              applied++;
            } else if (result.existing) {
              conflicts.push({
                bookId: result.existing.book_id,
                entity: result.existing.entity,
                id: result.existing.entity_id,
                updatedAt: Number(result.existing.updated_at),
                deleted: Number(result.existing.deleted) === 1,
                payload: JSON.parse(result.existing.payload) as Record<string, unknown>,
              });
            }
          }
          return send(res, 200, {
            applied,
            conflicts,
            cursor: store.syncMaxSeq(userId),
          });
        }

        case 'GET /v1/sync/pull': {
          const userId = await userIdOf(req);
          if (!userId) return send(res, 401, { error: 'unauthorized' });
          const sinceRaw = Number(url.searchParams.get('since') ?? '0');
          const since = Number.isFinite(sinceRaw) && sinceRaw > 0 ? Math.floor(sinceRaw) : 0;
          const limitRaw = Number(url.searchParams.get('limit') ?? '200');
          const limit =
            Number.isFinite(limitRaw) && limitRaw > 0
              ? Math.min(200, Math.floor(limitRaw))
              : 200;
          const bookId = url.searchParams.get('bookId') ?? undefined;
          const rows = store.syncPull(userId, since, limit + 1, bookId);
          const hasMore = rows.length > limit;
          const page = rows.slice(0, limit);
          const changes: SyncChangeOut[] = page.map((row) => ({
            bookId: row.book_id,
            entity: row.entity,
            id: row.entity_id,
            updatedAt: Number(row.updated_at),
            deleted: Number(row.deleted) === 1,
            payload: JSON.parse(row.payload) as Record<string, unknown>,
          }));
          const cursor = page.length > 0 ? Number(page[page.length - 1]!.seq) : since;
          return send(res, 200, { changes, cursor, hasMore });
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
