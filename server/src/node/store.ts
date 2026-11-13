/**
 * SQLite + 文件存储（Node 版，跑在 ECS 上）。
 *
 * 用 `node:sqlite`（Node 22.5+ 内置，24/26 默认可用）—— **不需要 better-sqlite3**，
 * 也就不需要在 ECS 上装编译工具链。
 *
 * 表结构与 Cloudflare 版**共用同一份 `schema.sql`**（两边都是 SQLite），
 * 这样迁移时不用维护两套 DDL。
 */

import { DatabaseSync } from 'node:sqlite';
import { mkdirSync, readFileSync, rmSync, writeFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';

export interface CodeRow {
  code_hash: string;
  expires_at: number;
  attempts: number;
}

export interface BackupRow {
  id: string;
  object_key: string;
  size: number;
  sha256: string;
  created_at: number;
}

export class Store {
  readonly db: DatabaseSync;
  readonly dataDir: string;

  constructor(dataDir: string) {
    this.dataDir = dataDir;
    mkdirSync(join(dataDir, 'backups'), { recursive: true });
    this.db = new DatabaseSync(join(dataDir, 'sync.db'));
    this.db.exec('PRAGMA journal_mode = WAL;');
    this.db.exec('PRAGMA foreign_keys = ON;');
    this.db.exec(readFileSync(join(dataDir, '..', 'schema.sql'), 'utf8'));
  }

  /** 传入 schema 文本（测试用，避免依赖工作目录）。 */
  static open(dataDir: string, schemaSql: string): Store {
    const s = Object.create(Store.prototype) as Store;
    mkdirSync(join(dataDir, 'backups'), { recursive: true });
    (s as { dataDir: string }).dataDir = dataDir;
    (s as { db: DatabaseSync }).db = new DatabaseSync(join(dataDir, 'sync.db'));
    s.db.exec('PRAGMA journal_mode = WAL;');
    s.db.exec(schemaSql);
    return s;
  }

  close(): void {
    try {
      this.db.close();
    } catch {
      /* 已关 */
    }
  }

  // ── 用户 ────────────────────────────────────────────────────────────

  userIdByEmail(email: string): string | null {
    const row = this.db.prepare('SELECT id FROM users WHERE email = ?').get(email) as
      | { id: string }
      | undefined;
    return row?.id ?? null;
  }

  /**
   * 用户行是否还在。
   *
   * 注销是**硬删**：access token 是 stateless JWT，签名仍有效，所以每个请求都要
   * 用这个函数确认用户没被删 —— 否则注销后 15 分钟内还能读/写备份（等于「复活」）。
   */
  userExists(userId: string): boolean {
    const row = this.db.prepare('SELECT 1 AS ok FROM users WHERE id = ?').get(userId);
    return row !== undefined;
  }

  ensureUser(email: string, nowSec: number): string {
    const existing = this.userIdByEmail(email);
    if (existing) return existing;
    const id = crypto.randomUUID();
    this.db
      .prepare('INSERT INTO users (id, email, created_at) VALUES (?, ?, ?)')
      .run(id, email, nowSec);
    return id;
  }

  // ── 验证码 ──────────────────────────────────────────────────────────

  lastCode(email: string): CodeRow | null {
    const row = this.db
      .prepare(
        'SELECT code_hash, expires_at, attempts FROM auth_codes WHERE email = ? ORDER BY created_at DESC LIMIT 1',
      )
      .get(email) as CodeRow | undefined;
    return row ?? null;
  }

  clearCodes(email: string, nowSec: number): void {
    this.db.prepare('DELETE FROM auth_codes WHERE email = ? OR expires_at < ?').run(email, nowSec);
  }

  insertCode(email: string, hash: string, expiresAt: number, nowSec: number, ip: string): void {
    this.db
      .prepare(
        'INSERT INTO auth_codes (email, code_hash, expires_at, attempts, created_at, ip) VALUES (?, ?, ?, 0, ?, ?)',
      )
      .run(email, hash, expiresAt, nowSec, ip);
  }

  bumpAttempts(email: string): void {
    this.db.prepare('UPDATE auth_codes SET attempts = attempts + 1 WHERE email = ?').run(email);
  }

  // ── 发码记录（限流用；登录成功清码后仍然保留）──────────────────────

  recordSend(email: string, ip: string, nowSec: number): void {
    this.db
      .prepare('INSERT INTO code_sends (email, ip, sent_at) VALUES (?, ?, ?)')
      .run(email, ip, nowSec);
    // 顺手清理一天前的记录，表不会无限长
    this.db.prepare('DELETE FROM code_sends WHERE sent_at < ?').run(nowSec - 86400);
  }

  lastSendAt(email: string): number | null {
    const row = this.db
      .prepare('SELECT MAX(sent_at) AS t FROM code_sends WHERE email = ?')
      .get(email) as { t: number | null } | undefined;
    return row?.t ?? null;
  }

  countSendsByEmail(email: string, sinceSec: number): number {
    const row = this.db
      .prepare('SELECT COUNT(*) AS n FROM code_sends WHERE email = ? AND sent_at >= ?')
      .get(email, sinceSec) as { n: number };
    return row.n;
  }

  countSendsByIp(ip: string, sinceSec: number): number {
    const row = this.db
      .prepare('SELECT COUNT(*) AS n FROM code_sends WHERE ip = ? AND sent_at >= ?')
      .get(ip, sinceSec) as { n: number };
    return row.n;
  }

  countCodesByEmail(email: string, sinceSec: number): number {
    const row = this.db
      .prepare('SELECT COUNT(*) AS n FROM auth_codes WHERE email = ? AND created_at >= ?')
      .get(email, sinceSec) as { n: number };
    return row.n;
  }

  countCodesByIp(ip: string, sinceSec: number): number {
    const row = this.db
      .prepare('SELECT COUNT(*) AS n FROM auth_codes WHERE ip = ? AND created_at >= ?')
      .get(ip, sinceSec) as { n: number };
    return row.n;
  }

  // ── refresh token ───────────────────────────────────────────────────

  insertRefresh(id: string, userId: string, hash: string, expiresAt: number, nowSec: number): void {
    this.db
      .prepare(
        'INSERT INTO refresh_tokens (id, user_id, token_hash, expires_at, created_at) VALUES (?, ?, ?, ?, ?)',
      )
      .run(id, userId, hash, expiresAt, nowSec);
  }

  findRefresh(
    hash: string,
  ): { id: string; user_id: string; expires_at: number; revoked_at: number | null } | null {
    const row = this.db
      .prepare(
        'SELECT id, user_id, expires_at, revoked_at FROM refresh_tokens WHERE token_hash = ?',
      )
      .get(hash) as
      | { id: string; user_id: string; expires_at: number; revoked_at: number | null }
      | undefined;
    return row ?? null;
  }

  revokeRefresh(id: string, nowSec: number): void {
    this.db.prepare('UPDATE refresh_tokens SET revoked_at = ? WHERE id = ?').run(nowSec, id);
  }

  revokeRefreshByHash(hash: string, nowSec: number): void {
    this.db
      .prepare('UPDATE refresh_tokens SET revoked_at = ? WHERE token_hash = ? AND revoked_at IS NULL')
      .run(nowSec, hash);
  }

  // ── 备份 ────────────────────────────────────────────────────────────

  insertBackup(row: BackupRow & { user_id: string }): void {
    this.db
      .prepare(
        'INSERT INTO backups (id, user_id, object_key, size, sha256, created_at) VALUES (?, ?, ?, ?, ?, ?)',
      )
      .run(row.id, row.user_id, row.object_key, row.size, row.sha256, row.created_at);
  }

  latestBackup(userId: string): BackupRow | null {
    const row = this.db
      .prepare(
        'SELECT id, object_key, size, sha256, created_at FROM backups WHERE user_id = ? ORDER BY created_at DESC LIMIT 1',
      )
      .get(userId) as BackupRow | undefined;
    return row ?? null;
  }

  listBackups(userId: string, limit = 20): BackupRow[] {
    return this.db
      .prepare(
        'SELECT id, object_key, size, sha256, created_at FROM backups WHERE user_id = ? ORDER BY created_at DESC LIMIT ?',
      )
      .all(userId, limit) as unknown as BackupRow[];
  }

  /** 超出保留份数的旧备份（返回待删除的行）。 */
  backupsBeyond(userId: string, keep: number): BackupRow[] {
    return this.db
      .prepare(
        'SELECT id, object_key, size, sha256, created_at FROM backups WHERE user_id = ? ORDER BY created_at DESC LIMIT -1 OFFSET ?',
      )
      .all(userId, keep) as unknown as BackupRow[];
  }

  deleteBackupRow(id: string): void {
    this.db.prepare('DELETE FROM backups WHERE id = ?').run(id);
  }

  // ── 文件 ────────────────────────────────────────────────────────────

  writeBackup(userId: string, bytes: Uint8Array, stamp: number): string {
    const key = `${userId}/${stamp}-${crypto.randomUUID()}.json`;
    const path = join(this.dataDir, 'backups', key);
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, bytes);
    return key;
  }

  readBackup(key: string): Uint8Array | null {
    const path = join(this.dataDir, 'backups', key);
    if (!existsSync(path)) return null;
    return readFileSync(path);
  }

  removeBackup(key: string): void {
    rmSync(join(this.dataDir, 'backups', key), { force: true });
  }

  removeUserDir(userId: string): void {
    rmSync(join(this.dataDir, 'backups', userId), { recursive: true, force: true });
  }

  // ── 注销（硬删）─────────────────────────────────────────────────────

  deleteUser(userId: string): void {
    this.db.prepare('DELETE FROM backups WHERE user_id = ?').run(userId);
    this.db.prepare('DELETE FROM refresh_tokens WHERE user_id = ?').run(userId);
    this.db
      .prepare('DELETE FROM auth_codes WHERE email IN (SELECT email FROM users WHERE id = ?)')
      .run(userId);
    this.db.prepare('DELETE FROM users WHERE id = ?').run(userId);
  }
}
