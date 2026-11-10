-- 小耄记账云同步 · D1 表结构（wrangler d1 execute --file schema.sql）
--
-- 设计原则：
--   * 只存「谁 + 什么时候 + 多大 + 哪个对象」，备份正文在 R2；
--   * 注销走硬删（DELETE），不打 deleted_at 标记 —— 用户要求的是「删掉」；
--   * 验证码与 refresh token 都存哈希，不存明文。

CREATE TABLE IF NOT EXISTS users (
  id          TEXT PRIMARY KEY,
  email       TEXT NOT NULL UNIQUE,
  created_at  INTEGER NOT NULL
);

-- 一次性登录验证码（同一邮箱只保留最新的那条）
CREATE TABLE IF NOT EXISTS auth_codes (
  email       TEXT NOT NULL,
  code_hash   TEXT NOT NULL,
  expires_at  INTEGER NOT NULL,
  attempts    INTEGER NOT NULL DEFAULT 0,
  created_at  INTEGER NOT NULL,
  ip          TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_auth_codes_email ON auth_codes(email);
CREATE INDEX IF NOT EXISTS idx_auth_codes_ip ON auth_codes(ip, created_at);

-- refresh token（轮换：旧的立刻 revoked_at）
CREATE TABLE IF NOT EXISTS refresh_tokens (
  id          TEXT PRIMARY KEY,
  user_id     TEXT NOT NULL,
  token_hash  TEXT NOT NULL,
  expires_at  INTEGER NOT NULL,
  created_at  INTEGER NOT NULL,
  revoked_at  INTEGER
);
CREATE INDEX IF NOT EXISTS idx_refresh_user ON refresh_tokens(user_id);
CREATE INDEX IF NOT EXISTS idx_refresh_hash ON refresh_tokens(token_hash);

-- 备份元数据（正文在 R2：u/<userId>/<ts>-<uuid>.json）
CREATE TABLE IF NOT EXISTS backups (
  id          TEXT PRIMARY KEY,
  user_id     TEXT NOT NULL,
  object_key  TEXT NOT NULL,
  size        INTEGER NOT NULL,
  sha256      TEXT NOT NULL,
  created_at  INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_backups_user ON backups(user_id, created_at DESC);
