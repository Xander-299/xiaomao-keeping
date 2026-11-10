/**
 * 纯函数层：JWT / 验证码哈希 / 邮箱规整。
 *
 * 单独成文件是为了**能在没有 Workers 运行时的地方跑测试**（`node --test`），
 * 也为了逼自己把「安全相关的分支」写成纯函数，而不是藏在 fetch handler 里。
 *
 * ⚠️ 只用可擦除的 TS 语法（不用 enum / namespace / 参数属性），
 * Node 的类型剥离才能直接跑。
 */

export interface Claims {
  sub: string; // userId
  iat: number;
  exp: number;
}

const enc = new TextEncoder();

/** 字节 → base64url（无 padding）。 */
export function b64url(bytes: Uint8Array): string {
  let bin = '';
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/** base64url → 字节。
 *
 * 显式用 `new Uint8Array(new ArrayBuffer(n))` 而不是 `new Uint8Array(n)`：
 * 后者在 TS 5.7 的新类型里是 `Uint8Array<ArrayBufferLike>`，喂给 WebCrypto 的
 * `verify()`（要 `BufferSource`）会报类型不兼容。
 */
export function b64urlDecode(s: string): Uint8Array<ArrayBuffer> {
  const pad = s.length % 4 === 0 ? '' : '='.repeat(4 - (s.length % 4));
  const b64 = s.replace(/-/g, '+').replace(/_/g, '/') + pad;
  const bin = atob(b64);
  const out = new Uint8Array(new ArrayBuffer(bin.length));
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/** SHA-256 → 小写 hex。 */
export async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', enc.encode(input));
  return [...new Uint8Array(digest)]
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

/** 恒时比较（长度不同直接 false，长度相同走完整循环）。 */
export function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

async function hmacKey(secret: string): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    'raw',
    enc.encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign', 'verify'],
  );
}

/** 签发 HS256 JWT。 */
export async function signJwt(
  claims: Claims,
  secret: string,
): Promise<string> {
  const header = b64url(enc.encode(JSON.stringify({ alg: 'HS256', typ: 'JWT' })));
  const payload = b64url(enc.encode(JSON.stringify(claims)));
  const key = await hmacKey(secret);
  const sig = new Uint8Array(
    await crypto.subtle.sign('HMAC', key, enc.encode(`${header}.${payload}`)),
  );
  return `${header}.${payload}.${b64url(sig)}`;
}

/**
 * 校验 JWT：签名不对 / 结构不对 / 过期 → null。
 *
 * 过期判断用**服务端时间**，不看 token 里的 iat 合法性（客户端时钟不可信）。
 */
export async function verifyJwt(
  token: string,
  secret: string,
  nowSec: number,
): Promise<Claims | null> {
  const parts = token.split('.');
  if (parts.length !== 3) return null;
  const header = parts[0];
  const payload = parts[1];
  const sig = parts[2];
  if (header === undefined || payload === undefined || sig === undefined) return null;
  const key = await hmacKey(secret);
  let ok = false;
  try {
    ok = await crypto.subtle.verify(
      'HMAC',
      key,
      b64urlDecode(sig),
      enc.encode(`${header}.${payload}`),
    );
  } catch {
    return null;
  }
  if (!ok) return null;
  let claims: Claims;
  try {
    claims = JSON.parse(new TextDecoder().decode(b64urlDecode(payload))) as Claims;
  } catch {
    return null;
  }
  if (typeof claims?.sub !== 'string' || typeof claims?.exp !== 'number') return null;
  if (claims.exp <= nowSec) return null;
  return claims;
}

/** 6 位数字验证码（用 CSPRNG，不用 Math.random）。 */
export function generateCode(digits = 6): string {
  const max = 10 ** digits;
  const buf = new Uint32Array(1);
  crypto.getRandomValues(buf);
  return ((buf[0] ?? 0) % max).toString().padStart(digits, '0');
}

/** 随机 token（refresh token 用）。 */
export function randomToken(bytes = 32): string {
  const buf = new Uint8Array(bytes);
  crypto.getRandomValues(buf);
  return b64url(buf);
}

/** 邮箱规整：小写 + 去空白；格式不对返回 null。 */
export function normalizeEmail(raw: unknown): string | null {
  if (typeof raw !== 'string') return null;
  const email = raw.trim().toLowerCase();
  // 故意写得保守：只认最常见的形态，不接受带引号/注释/超长本地部分的花样地址
  if (email.length < 3 || email.length > 254) return null;
  if (!/^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$/.test(email)) return null;
  return email;
}

/** 验证码哈希：绑邮箱，防止同一份码被换邮箱复用。 */
export async function codeHashOf(
  email: string,
  code: string,
  pepper: string,
): Promise<string> {
  return sha256Hex(`${pepper}|${email}|${code}`);
}

/** 从 `Authorization: Bearer xxx` 里取 token。 */
export function parseBearer(header: string | null): string | null {
  if (!header) return null;
  const m = /^Bearer\s+(.+)$/i.exec(header.trim());
  const token = m?.[1]?.trim();
  return token && token.length > 0 ? token : null;
}

/** 备份大小上限（20 MB）：够一个人几年的账，又不至于把免费额度撑爆。 */
export const MAX_BACKUP_BYTES = 20 * 1024 * 1024;

/** 每用户保留的历史快照数。 */
export const KEEP_SNAPSHOTS = 5;

/** 验证码有效期（5 分钟）。 */
export const CODE_TTL_SEC = 5 * 60;

/** 同邮箱重发冷却（60 秒）。 */
export const RESEND_COOLDOWN_SEC = 60;

/** 单邮箱单日发码上限。 */
export const DAILY_CODE_CAP = 10;

/** 验证码最多试几次（防爆破）。 */
export const MAX_CODE_ATTEMPTS = 5;

/** access token 有效期（15 分钟）。 */
export const ACCESS_TTL_SEC = 15 * 60;

/** refresh token 有效期（30 天）。 */
export const REFRESH_TTL_SEC = 30 * 24 * 60 * 60;
