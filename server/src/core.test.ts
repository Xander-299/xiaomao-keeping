/**
 * 纯函数层单测（`node --test src/*.test.ts`，不需要 Workers 运行时）。
 *
 * 这些用例护的是安全分支：签名伪造、过期、验证码长度/格式、邮箱规整 —— 都是
 * 「写错一行就出事、但肉眼看不出来」的地方。fetch handler 的行为要靠真机联调，
 * 这里只保证地基不歪。
 */

import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  ACCESS_TTL_SEC,
  MAX_BACKUP_BYTES,
  b64url,
  b64urlDecode,
  codeHashOf,
  constantTimeEqual,
  generateCode,
  normalizeEmail,
  parseBearer,
  randomToken,
  sha256Hex,
  signJwt,
  verifyJwt,
} from './core.ts';

test('b64url 往返：任意字节都能原样回来', () => {
  const bytes = new Uint8Array([0, 1, 2, 250, 251, 252, 253, 254, 255]);
  const round = b64urlDecode(b64url(bytes));
  assert.deepEqual([...round], [...bytes]);
});

test('b64url 不含 + / = 三个字符（URL 安全）', () => {
  const s = b64url(new Uint8Array([251, 255, 190, 191]));
  assert.ok(!/[+/=]/.test(s), `got ${s}`);
});

test('sha256 已知向量', async () => {
  assert.equal(
    await sha256Hex('abc'),
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
  );
});

test('JWT：签发的 token 能验回来，claims 不变', async () => {
  const secret = 'test-secret-0123456789';
  const now = 1_800_000_000;
  const token = await signJwt({ sub: 'u1', iat: now, exp: now + 900 }, secret);
  const claims = await verifyJwt(token, secret, now);
  assert.ok(claims);
  assert.equal(claims.sub, 'u1');
  assert.equal(claims.exp, now + 900);
});

test('JWT：换密钥 / 改 payload / 结构不全 → 一律 null', async () => {
  const now = 1_800_000_000;
  const token = await signJwt({ sub: 'u1', iat: now, exp: now + 900 }, 'secret-a');

  assert.equal(await verifyJwt(token, 'secret-b', now), null, '换密钥必须失效');

  const [h, , s] = token.split('.');
  const forged = `${h}.${b64url(new TextEncoder().encode('{"sub":"admin","exp":9999999999}'))}.${s}`;
  assert.equal(await verifyJwt(forged, 'secret-a', now), null, '改 payload 必须失效');

  assert.equal(await verifyJwt('a.b', 'secret-a', now), null);
  assert.equal(await verifyJwt('not-a-token', 'secret-a', now), null);
});

test('JWT：过期用服务端时间判定', async () => {
  const secret = 's';
  const iat = 1_800_000_000;
  const token = await signJwt({ sub: 'u1', iat, exp: iat + 60 }, secret);
  assert.ok(await verifyJwt(token, secret, iat + 59));
  assert.equal(await verifyJwt(token, secret, iat + 60), null, '边界：exp <= now 即过期');
});

test('access token 有效期是 15 分钟', () => {
  assert.equal(ACCESS_TTL_SEC, 900);
});

test('验证码：6 位纯数字，且绑定邮箱（换邮箱就不同）', async () => {
  const code = generateCode(6);
  assert.match(code, /^\d{6}$/);

  const a = await codeHashOf('a@b.com', code, 'pepper');
  const b = await codeHashOf('c@d.com', code, 'pepper');
  const c = await codeHashOf('a@b.com', code, 'other-pepper');
  assert.notEqual(a, b, '同一份码换个邮箱不能复用');
  assert.notEqual(a, c, '换 pepper 必须变');
  assert.equal(a.length, 64);
});

test('randomToken：长度足够且两次不同', () => {
  const a = randomToken(32);
  const b = randomToken(32);
  assert.notEqual(a, b);
  assert.ok(b64urlDecode(a).length === 32);
});

test('constantTimeEqual：相等为 true，差一个字符为 false', () => {
  assert.equal(constantTimeEqual('abcdef', 'abcdef'), true);
  assert.equal(constantTimeEqual('abcdef', 'abcdeg'), false);
  assert.equal(constantTimeEqual('abc', 'abcd'), false);
});

test('normalizeEmail：小写去空白，拒绝花样格式', () => {
  assert.equal(normalizeEmail('  A.User+tag@Example.COM '), 'a.user+tag@example.com');
  for (const bad of [
    '',
    'no-at-sign',
    'a@b',
    'a@b.c',
    '@example.com',
    'a b@example.com',
    'a@.com',
    'x'.repeat(250) + '@example.com',
    null,
    42,
  ]) {
    assert.equal(normalizeEmail(bad as unknown), null, `should reject ${String(bad)}`);
  }
});

test('parseBearer：只认 Bearer，大小写不敏感，无头为 null', () => {
  assert.equal(parseBearer('Bearer abc.def'), 'abc.def');
  assert.equal(parseBearer('bearer   abc.def  '), 'abc.def');
  assert.equal(parseBearer('Basic abc'), null);
  assert.equal(parseBearer(null), null);
});

test('备份大小上限是 20 MB', () => {
  assert.equal(MAX_BACKUP_BYTES, 20 * 1024 * 1024);
});
