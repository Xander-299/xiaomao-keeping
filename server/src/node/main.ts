/**
 * 入口：读环境变量、开库、起 HTTP 服务（ECS 上用）。
 *
 * 默认只监听 127.0.0.1 —— 让它待在 Nginx / Caddy 后面收 HTTPS，
 * 而不是自己裸奔 80 端口。要直接对外（不推荐）就设 HOST=0.0.0.0。
 */

import { createServer } from 'node:http';
import { mkdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

import { createHandler } from './app.ts';
import { Store } from './store.ts';

const dataDir = process.env.DATA_DIR ?? join(process.cwd(), 'data');
mkdirSync(dataDir, { recursive: true });

const schemaPath = process.env.SCHEMA_PATH ?? join(process.cwd(), 'schema.sql');
const schemaSql = readFileSync(schemaPath, 'utf8');
const store = Store.open(dataDir, schemaSql);

const jwtSecret = process.env.JWT_SECRET ?? '';
const codePepper = process.env.CODE_PEPPER ?? '';
if (jwtSecret.length < 32 || codePepper.length < 32) {
  console.error('JWT_SECRET / CODE_PEPPER 必须各自 ≥ 32 字符（openssl rand -base64 48）');
  process.exit(1);
}

const smtpPort = Number(process.env.SMTP_PORT ?? 465);
const smtp = process.env.SMTP_HOST && process.env.SMTP_USER && process.env.SMTP_PASS
  ? {
      host: process.env.SMTP_HOST,
      port: smtpPort,
      user: process.env.SMTP_USER,
      pass: process.env.SMTP_PASS,
      // 465 = 隐式 TLS；其他端口默认明文（测试用），可用 SMTP_SECURE=1 强制
      secure: (process.env.SMTP_SECURE ?? (smtpPort === 465 ? '1' : '0')) === '1',
    }
  : undefined;
const mailProvider =
  process.env.MAIL_PROVIDER === 'smtp' || process.env.MAIL_PROVIDER === 'resend'
    ? process.env.MAIL_PROVIDER
    : smtp
      ? 'smtp'
      : 'resend';

const codeTtlRaw = Number(process.env.CODE_TTL_SEC ?? '');
const codeTtlSec =
  Number.isFinite(codeTtlRaw) && codeTtlRaw > 0 ? codeTtlRaw : undefined;

const handler = createHandler(store, {
  jwtSecret,
  codePepper,
  mailFrom: process.env.MAIL_FROM,
  mailProvider,
  smtp,
  resendApiKey: process.env.RESEND_API_KEY,
  devEchoCode: process.env.DEV_ECHO_CODE === '1',
  codeTtlSec,
});

const port = Number(process.env.PORT ?? 8787);
const host = process.env.HOST ?? '127.0.0.1';
const server = createServer((req, res) => {
  void handler(req, res);
});

server.listen(port, host, () => {
  console.log(`xiaomao-sync listening on http://${host}:${port}  data=${dataDir}`);
});

const shutdown = (signal: string) => {
  console.log(`收到 ${signal}，正在关闭…`);
  server.close(() => {
    store.close();
    process.exit(0);
  });
};
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
