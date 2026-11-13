/**
 * 最小 SMTP 发信（P6.2 账号验证码）。
 *
 * 为什么手写而不是引 `nodemailer`：这个服务端**零运行时依赖**是刻意保持的
 * （见 `server/README.md`：Node 自带 http/sqlite/fetch/WebCrypto）。
 * 我们只需要「EHLO + AUTH LOGIN + MAIL FROM + RCPT TO + DATA」这一条最小路径，
 * 支持隐式 TLS（465，126/163/QQ 都支持）与明文（仅用于本地测试）。
 *
 * 支持范围（刻意很小）：
 * - 一个收件人、纯文本正文、UTF-8；
 * - AUTH LOGIN（126 / 163 / QQ 邮箱的授权码模式）；
 * - 15 s 超时；任何非预期响应码都抛错（由调用方转成「发信失败」）。
 */

import { randomUUID } from 'node:crypto';
import { connect as netConnect, type Socket } from 'node:net';
import { connect as tlsConnect } from 'node:tls';

export interface SmtpConfig {
  host: string;
  port: number;
  user: string;
  pass: string;
  /** `true` = 隐式 TLS（465）；`false` = 明文（仅测试）。 */
  secure?: boolean;
  timeoutMs?: number;
}

export interface MailMessage {
  /** 可以是 `小耄记账 <no-reply@example.com>`，也可以只有地址。 */
  from: string;
  to: string;
  subject: string;
  text: string;
}

interface SmtpResponse {
  code: number;
  text: string;
}

/** RFC 2047：非 ASCII 头用 base64 编码（From 显示名 / Subject 都会用到）。 */
export function encodeHeader(value: string): string {
  // eslint-disable-next-line no-control-regex
  if (/^[\x20-\x7E]*$/.test(value)) return value;
  return `=?UTF-8?B?${Buffer.from(value, 'utf8').toString('base64')}?=`;
}

/** 从 `Name <addr>` 里拆出地址；没有尖括号就整串当地址。 */
export function parseAddress(from: string): { name: string; address: string } {
  const matched = /^\s*(.*?)\s*<([^>]+)>\s*$/.exec(from);
  if (matched) return { name: matched[1] ?? '', address: matched[2]!.trim() };
  return { name: '', address: from.trim() };
}

/** 构造 RFC 5322 纯文本邮件（正文 base64，避免 8bit / 行尾问题）。 */
export function buildMessage(msg: MailMessage, now: Date = new Date()): string {
  const { name, address } = parseAddress(msg.from);
  const fromHeader = name
    ? `${encodeHeader(name)} <${address}>`
    : address;
  const body = Buffer.from(msg.text, 'utf8').toString('base64');
  const bodyLines = body.match(/.{1,76}/g) ?? [''];
  const headers = [
    `From: ${fromHeader}`,
    `To: ${msg.to}`,
    `Subject: ${encodeHeader(msg.subject)}`,
    `Date: ${now.toUTCString()}`,
    `Message-ID: <${randomUUID()}@xiaomao-sync>`,
    'MIME-Version: 1.0',
    'Content-Type: text/plain; charset=UTF-8',
    'Content-Transfer-Encoding: base64',
  ];
  return `${headers.join('\r\n')}\r\n\r\n${bodyLines.join('\r\n')}\r\n`;
}

/** 行级 SMTP 会话：写一行命令、读一个完整响应（支持 `250-` 多行）。 */
class SmtpSession {
  private buffer = '';
  private readonly lines: string[] = [];
  private readonly waiters: Array<(line: string) => void> = [];
  private failure: Error | null = null;

  private readonly socket: Socket;

  constructor(socket: Socket, timeoutMs: number) {
    this.socket = socket;
    socket.setEncoding('utf8');
    socket.setTimeout(timeoutMs, () => {
      this.fail(new Error('SMTP 超时'));
    });
    socket.on('data', (chunk: string) => {
      this.buffer += chunk;
      let index = this.buffer.indexOf('\r\n');
      while (index >= 0) {
        const line = this.buffer.slice(0, index);
        this.buffer = this.buffer.slice(index + 2);
        this.lines.push(line);
        index = this.buffer.indexOf('\r\n');
      }
      while (this.lines.length > 0 && this.waiters.length > 0) {
        const line = this.lines.shift()!;
        const waiter = this.waiters.shift()!;
        waiter(line);
      }
    });
    socket.on('error', (error: Error) => this.fail(error));
    socket.on('close', () => {
      if (this.waiters.length > 0) this.fail(new Error('SMTP 连接已关闭'));
    });
  }

  private fail(error: Error): void {
    this.failure = error;
    while (this.waiters.length > 0) {
      const waiter = this.waiters.shift()!;
      // 用一行错误文本唤醒等待者，下面 readLine 会检查 failure 并抛出
      waiter('');
    }
  }

  async readLine(): Promise<string> {
    if (this.failure) throw this.failure;
    if (this.lines.length > 0) return this.lines.shift()!;
    return new Promise<string>((resolve) => {
      this.waiters.push(resolve);
    }).then((line) => {
      if (this.failure) throw this.failure;
      return line;
    });
  }

  async readResponse(): Promise<SmtpResponse> {
    const collected: string[] = [];
    for (;;) {
      const line = await this.readLine();
      collected.push(line);
      const matched = /^(\d{3})([ -])/.exec(line);
      if (matched && matched[2] === ' ') {
        return { code: Number(matched[1]), text: collected.join('\n') };
      }
    }
  }

  async command(line: string): Promise<SmtpResponse> {
    this.socket.write(`${line}\r\n`);
    return this.readResponse();
  }

  close(): void {
    this.socket.end();
  }

  destroy(): void {
    this.socket.destroy();
  }
}

function expect(response: SmtpResponse, codes: number[], step: string): void {
  if (!codes.includes(response.code)) {
    throw new Error(`SMTP ${step} 失败：${response.code} ${response.text.replace(/\n/g, ' ')}`);
  }
}

/** 发一封纯文本邮件；失败抛错。 */
export async function sendSmtpMail(cfg: SmtpConfig, msg: MailMessage): Promise<void> {
  const secure = cfg.secure ?? cfg.port === 465;
  const timeoutMs = cfg.timeoutMs ?? 15_000;
  const socket = secure
    ? tlsConnect({ host: cfg.host, port: cfg.port, servername: cfg.host })
    : netConnect({ host: cfg.host, port: cfg.port });

  const session = new SmtpSession(socket, timeoutMs);
  try {
    // 等 TCP/TLS 建连完成（TLS 失败会走 socket error）
    await new Promise<void>((resolve, reject) => {
      if (secure) {
        (socket as ReturnType<typeof tlsConnect>).once('secureConnect', resolve);
      } else {
        socket.once('connect', resolve);
      }
      socket.once('error', reject);
    });

    expect(await session.readResponse(), [220], 'greeting');
    expect(await session.command('EHLO xiaomao-sync'), [250], 'EHLO');
    expect(await session.command('AUTH LOGIN'), [334], 'AUTH LOGIN');
    expect(
      await session.command(Buffer.from(cfg.user, 'utf8').toString('base64')),
      [334],
      'AUTH user',
    );
    expect(
      await session.command(Buffer.from(cfg.pass, 'utf8').toString('base64')),
      [235],
      'AUTH pass',
    );

    const { address } = parseAddress(msg.from);
    expect(await session.command(`MAIL FROM:<${address}>`), [250], 'MAIL FROM');
    expect(await session.command(`RCPT TO:<${msg.to}>`), [250, 251], 'RCPT TO');
    expect(await session.command('DATA'), [354], 'DATA');

    // DATA 内容 + 结束标记（行首的 `.` 已在 base64 正文里不可能出现，仍按规范转义）
    const message = buildMessage(msg);
    const dotStuffed = message
      .split('\r\n')
      .map((line) => (line.startsWith('.') ? `.${line}` : line))
      .join('\r\n');
    socket.write(`${dotStuffed}\r\n.\r\n`);
    expect(await session.readResponse(), [250], 'DATA end');

    // QUIT 失败不影响「已收下」的事实
    try {
      await session.command('QUIT');
    } catch {
      /* ignore */
    }
  } catch (error) {
    session.destroy();
    throw error;
  }
  session.close();
}
