/**
 * SMTP 发信的最小协议测试：起一个假 SMTP 服务器，不连外网。
 *
 * 只覆盖我们真正用到的那条路径（EHLO → AUTH LOGIN → MAIL/RCPT/DATA），
 * 以及中文头 / base64 正文的编码。
 */

import assert from 'node:assert/strict';
import { createServer, type AddressInfo } from 'node:net';
import { test } from 'node:test';

import { buildMessage, encodeHeader, parseAddress, sendSmtpMail } from './mail.ts';

test('encodeHeader：ASCII 原样，中文走 RFC2047 base64', () => {
  assert.equal(encodeHeader('Verify code'), 'Verify code');
  assert.match(encodeHeader('登录验证码'), /^=\?UTF-8\?B\?[A-Za-z0-9+/=]+\?=$/);
  assert.equal(
    Buffer.from(encodeHeader('登录验证码').slice(10, -2), 'base64').toString('utf8'),
    '登录验证码',
  );
});

test('parseAddress：带显示名与纯地址两种形态', () => {
  assert.deepEqual(parseAddress('小耄记账 <no-reply@example.com>'), {
    name: '小耄记账',
    address: 'no-reply@example.com',
  });
  assert.deepEqual(parseAddress('a@b.com'), { name: '', address: 'a@b.com' });
});

test('buildMessage：中文头编码、正文 base64、CRLF 行尾', () => {
  const message = buildMessage(
    {
      from: '小耄记账 <wozai@126.com>',
      to: 'me@example.com',
      subject: '登录验证码',
      text: '你的验证码是 123456',
    },
    new Date('2026-11-14T00:00:00Z'),
  );

  assert.match(message, /^From: =\?UTF-8\?B\?[^\r\n]+\?= <wozai@126\.com>\r\n/);
  assert.match(message, /Subject: =\?UTF-8\?B\?[^\r\n]+\?=\r\n/);
  assert.match(message, /Content-Transfer-Encoding: base64\r\n/);
  assert.ok(!message.includes('\n\n'), '不能出现裸 LF 空行');

  const body = message.split('\r\n\r\n')[1]!.trim();
  assert.equal(Buffer.from(body, 'base64').toString('utf8'), '你的验证码是 123456');
});

test('sendSmtpMail：EHLO / AUTH LOGIN / 发件人 / 收件人 / DATA 全链路', async () => {
  let authUser = '';
  let authPass = '';
  let mailFrom = '';
  let rcptTo = '';
  let dataLines: string[] = [];
  let data = '';

  const server = createServer((socket) => {
    let stage = 0;
    let buffer = '';
    socket.setEncoding('utf8');
    socket.write('220 fake ESMTP\r\n');

    socket.on('data', (chunk: string) => {
      buffer += chunk;
      let index = buffer.indexOf('\r\n');
      while (index >= 0) {
        const line = buffer.slice(0, index);
        buffer = buffer.slice(index + 2);
        index = buffer.indexOf('\r\n');

        if (stage === 4) {
          if (line === '.') {
            data = dataLines.join('\r\n');
            socket.write('250 queued\r\n');
            stage = 5;
          } else {
            dataLines.push(line);
          }
          continue;
        }

        if (line.startsWith('EHLO')) {
          socket.write('250-fake\r\n250-AUTH LOGIN\r\n250 OK\r\n');
        } else if (line === 'AUTH LOGIN') {
          stage = 1;
          socket.write('334 VXNlcm5hbWU6\r\n');
        } else if (stage === 1) {
          authUser = Buffer.from(line, 'base64').toString('utf8');
          stage = 2;
          socket.write('334 UGFzc3dvcmQ6\r\n');
        } else if (stage === 2) {
          authPass = Buffer.from(line, 'base64').toString('utf8');
          stage = 3;
          socket.write('235 auth ok\r\n');
        } else if (line.startsWith('MAIL FROM:')) {
          mailFrom = line;
          socket.write('250 ok\r\n');
        } else if (line.startsWith('RCPT TO:')) {
          rcptTo = line;
          socket.write('250 ok\r\n');
        } else if (line === 'DATA') {
          stage = 4;
          dataLines = [];
          socket.write('354 go ahead\r\n');
        } else if (line === 'QUIT') {
          socket.write('221 bye\r\n');
          socket.end();
        } else {
          socket.write('250 ok\r\n');
        }
      }
    });
  });

  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = (server.address() as AddressInfo).port;

  try {
    await sendSmtpMail(
      {
        host: '127.0.0.1',
        port,
        user: 'wozai@126.com',
        pass: 'auth-code',
        secure: false,
        timeoutMs: 5_000,
      },
      {
        from: '小耄记账 <wozai@126.com>',
        to: 'me@example.com',
        subject: '登录验证码',
        text: '你的验证码是 123456',
      },
    );
  } finally {
    server.close();
  }

  assert.equal(authUser, 'wozai@126.com');
  assert.equal(authPass, 'auth-code');
  assert.equal(mailFrom, 'MAIL FROM:<wozai@126.com>');
  assert.equal(rcptTo, 'RCPT TO:<me@example.com>');
  assert.match(data, /Subject: =\?UTF-8\?B\?/);
  const body = data.split('\r\n\r\n')[1]!.trim();
  assert.equal(Buffer.from(body, 'base64').toString('utf8'), '你的验证码是 123456');
});
