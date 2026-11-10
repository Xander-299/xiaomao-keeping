/**
 * 端到端集成测试：真起一个 HTTP 服务、真打请求、真落盘。
 *
 * 这是 Cloudflare 版做不到的那层验证（那边要 workerd 才能跑）。这里覆盖：
 * 登录（发码 → 校验 → token）、refresh 轮换、上传/下载备份、跨用户隔离、
 * 限流、注销硬删。
 */

import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { createServer, type Server } from 'node:http';
import { mkdtempSync, readFileSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { createHandler } from './app.ts';
import { Store } from './store.ts';

const SCHEMA = readFileSync(new URL('../../schema.sql', import.meta.url), 'utf8');

let server: Server;
let store: Store;
let base: string;
let dataDir: string;
/** email → 最近一次验证码（通过 onDevCode 钩子拿到，模拟"收到邮件"）。 */
const codes = new Map<string, string>();

before(async () => {
  dataDir = mkdtempSync(join(tmpdir(), 'xiaomao-sync-test-'));
  store = Store.open(dataDir, SCHEMA);
  const handler = createHandler(store, {
    jwtSecret: 'test-jwt-secret-0123456789abcdef',
    codePepper: 'test-code-pepper-0123456789abcd',
    devEchoCode: true,
    onDevCode: (email, code) => codes.set(email, code),
  });
  server = createServer((req, res) => void handler(req, res));
  await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
  const addr = server.address();
  if (addr === null || typeof addr === 'string') throw new Error('no port');
  base = `http://127.0.0.1:${addr.port}`;
});

after(async () => {
  await new Promise<void>((r) => server.close(() => r()));
  store.close();
  rmSync(dataDir, { recursive: true, force: true });
});

async function login(email: string): Promise<{ accessToken: string; refreshToken: string }> {
  const r1 = await fetch(`${base}/v1/auth/request-code`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ email }),
  });
  assert.equal(r1.status, 204, '发码应 204');
  const code = codes.get(email);
  assert.ok(code, '测试钩子应该拿到验证码');

  const r2 = await fetch(`${base}/v1/auth/verify`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ email, code }),
  });
  assert.equal(r2.status, 200, '校验应通过');
  return (await r2.json()) as { accessToken: string; refreshToken: string };
}

const auth = (token: string) => ({ authorization: `Bearer ${token}` });

test('未带 token 访问备份 → 401', async () => {
  const r = await fetch(`${base}/v1/backups/latest`);
  assert.equal(r.status, 401);
});

test('登录全链路：发码 204 → 换 token → 邮箱不存在也不泄露', async () => {
  const tokens = await login('alice@example.com');
  assert.ok(tokens.accessToken.length > 20);
  assert.ok(tokens.refreshToken.length > 20);

  // 同一个邮箱再发一次：60 秒冷却生效 → 429
  const again = await fetch(`${base}/v1/auth/request-code`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ email: 'alice@example.com' }),
  });
  assert.equal(again.status, 429, '60 秒内重发应被限流');
});

test('验证码错误：400 且不签发 token；错 5 次后锁定', async () => {
  const email = 'bob@example.com';
  await fetch(`${base}/v1/auth/request-code`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ email }),
  });

  for (let i = 0; i < 5; i++) {
    const r = await fetch(`${base}/v1/auth/verify`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ email, code: '000000' }),
    });
    assert.equal(r.status, 400, `第 ${i + 1} 次错误码应 400`);
  }

  const locked = await fetch(`${base}/v1/auth/verify`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ email, code: '000000' }),
  });
  assert.equal(locked.status, 429, '超过尝试次数应 429');
});

test('备份：上传 → 下载字节一致 → 列表有元数据', async () => {
  const { accessToken } = await login('carol@example.com');
  const payload = new TextEncoder().encode('{"schemaVersion":5,"transactions":[]}');

  const put = await fetch(`${base}/v1/backups/latest`, {
    method: 'PUT',
    headers: { ...auth(accessToken), 'content-type': 'application/json' },
    body: payload,
  });
  assert.equal(put.status, 200);
  const meta = (await put.json()) as { size: number; sha256: string };
  assert.equal(meta.size, payload.byteLength);

  const got = await fetch(`${base}/v1/backups/latest`, { headers: auth(accessToken) });
  assert.equal(got.status, 200);
  const bytes = new Uint8Array(await got.arrayBuffer());
  assert.deepEqual([...bytes], [...payload], '下载内容必须与上传一致');

  const list = await fetch(`${base}/v1/backups`, { headers: auth(accessToken) });
  const rows = (await list.json()) as Array<{ id: string; size: number; sha256: string }>;
  assert.equal(rows.length, 1);
  assert.equal(rows[0]?.sha256, meta.sha256);
});

test('跨用户隔离：B 看不到 A 的备份', async () => {
  const a = await login('dave@example.com');
  const b = await login('erin@example.com');

  await fetch(`${base}/v1/backups/latest`, {
    method: 'PUT',
    headers: { ...auth(a.accessToken), 'content-type': 'application/json' },
    body: new TextEncoder().encode('{"only":"dave"}'),
  });

  const r = await fetch(`${base}/v1/backups/latest`, { headers: auth(b.accessToken) });
  assert.equal(r.status, 404, '别人的备份必须 404，不能 403（不泄露存在性）');
});

test('refresh 轮换：换新 token，旧的立刻失效', async () => {
  const { refreshToken } = await login('frank@example.com');

  const first = await fetch(`${base}/v1/auth/refresh`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ refreshToken }),
  });
  assert.equal(first.status, 200);
  const next = (await first.json()) as { refreshToken: string };
  assert.notEqual(next.refreshToken, refreshToken);

  const reuse = await fetch(`${base}/v1/auth/refresh`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ refreshToken }),
  });
  assert.equal(reuse.status, 401, '旧 refresh token 必须已作废');
});

test('注销：账本文件与数据库行都真的没了', async () => {
  const { accessToken } = await login('grace@example.com');
  await fetch(`${base}/v1/backups/latest`, {
    method: 'PUT',
    headers: { ...auth(accessToken), 'content-type': 'application/json' },
    body: new TextEncoder().encode('{"bye":true}'),
  });

  const userId = store.userIdByEmail('grace@example.com');
  assert.ok(userId);
  const userDir = join(dataDir, 'backups', userId);
  assert.ok(existsSync(userDir), '注销前文件应在');

  const del = await fetch(`${base}/v1/account`, { method: 'DELETE', headers: auth(accessToken) });
  assert.equal(del.status, 204);

  assert.equal(store.userIdByEmail('grace@example.com'), null, '用户行应被硬删');
  assert.equal(existsSync(userDir), false, '备份文件应被删除');

  // token 还在有效期内，但用户没了 → 备份接口不能再返回任何东西
  const after = await fetch(`${base}/v1/backups/latest`, { headers: auth(accessToken) });
  assert.ok(after.status === 404 || after.status === 401, '注销后不应再拿到数据');
});

test('备份大小上限：超限返回 413', async () => {
  const { accessToken } = await login('heidi@example.com');
  const tooBig = new Uint8Array(20 * 1024 * 1024 + 1);
  const r = await fetch(`${base}/v1/backups/latest`, {
    method: 'PUT',
    headers: { ...auth(accessToken), 'content-type': 'application/json' },
    body: tooBig,
  });
  assert.equal(r.status, 413);
});
