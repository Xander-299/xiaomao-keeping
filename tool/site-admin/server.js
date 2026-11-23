#!/usr/bin/env node
/**
 * 小耄记账 · 站点后台 v2（2026-11-24）
 *
 * 相比 v1（每次请求现扫日志）：
 * - 日志**增量入库**（node:sqlite 内置模块，零依赖），滚动窗口 90 天；
 * - 查询走 SQL，随便点哪个时间段都是毫秒级；
 * - 多视图：概览 / 流量 / 下载 / 来源 / 日志检索 / 系统状态；
 * - 日志检索支持关键字（IP / 路径 / UA）、状态码、时间范围、分页，可导出 CSV。
 *
 * 仍然：只监听 127.0.0.1:8081，公网入口由 Nginx（basic auth）+ Cloudflare 隧道提供。
 */
'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const { DatabaseSync } = require('node:sqlite');
const tls = require('tls');
const net = require('net');

// 离线地理位置（可选）：装了就按 IP 归因国家/省/市；没装也不影响其它功能。
let geoip = null;
try { geoip = require('/opt/xiaomao-admin/node_modules/geoip-lite'); } catch (_) { try { geoip = require('geoip-lite'); } catch (_) {} }

/** 云同步那套 SMTP 配置（126 邮箱）；没配就只发站内告警。 */
function loadSmtp() {
  // 优先用 systemd 注入的环境变量（/etc/xiaomao-admin.env，600 root）；
  // 读不到再退回去读 sync 的 .env（那个文件通常 www-data 读不到，只作兜底）。
  const out = { to: process.env.XM_ALERT_TO || '' };
  const keys = ['SMTP_HOST', 'SMTP_PORT', 'SMTP_SECURE', 'SMTP_USER', 'SMTP_PASS', 'MAIL_FROM'];
  for (const k of keys) if (process.env[k]) out[k] = process.env[k];
  if (!out.SMTP_HOST || !out.SMTP_USER) {
    try {
      const f = process.env.XM_SMTP_ENV || '/opt/xiaomao-sync/.env';
      for (const line of fs.readFileSync(f, 'utf8').split('\n')) {
        const m = /^([A-Z_]+)=(.*)$/.exec(line.trim());
        if (m && !out[m[1]]) out[m[1]] = m[2].replace(/^["']|["']$/g, '');
      }
    } catch (_) {}
  }
  return out;
}
const SMTP = loadSmtp();

const LOG_FILE = process.env.XM_LOG || '/www/wwwlogs/xiaomao2.log';
const DB_FILE = process.env.XM_DB || '/var/lib/xiaomao-admin/hits.db';
const PORT = Number(process.env.XM_PORT || 8081);
const HOST = '127.0.0.1';
const RETAIN_DAYS = 90;

const BOT_RE = /bot|crawler|spider|slurp|bingpreview|facebookexternalhit|headless|python-requests|curl\/|wget|monitor|uptime|pingdom|semrush|ahrefs|bytespider|petalbot|scanner|nmap/i;
const ASSET_RE = /\.(png|jpe?g|webp|avif|gif|svg|ico|css|js|map|txt|xml|woff2?)$/i;
const SELF_HOSTS = new Set(['xiaomao2.ccwu.cc', 'www.xiaomao2.ccwu.cc', 'admin.xiaomao2.ccwu.cc']);

fs.mkdirSync(path.dirname(DB_FILE), { recursive: true });
const db = new DatabaseSync(DB_FILE);
db.exec(`
  PRAGMA journal_mode = WAL;
  CREATE TABLE IF NOT EXISTS hits(
    id INTEGER PRIMARY KEY,
    ts TEXT NOT NULL, day TEXT NOT NULL, hour INTEGER NOT NULL,
    ip TEXT NOT NULL, method TEXT, path TEXT, status INTEGER, bytes INTEGER,
    ref TEXT, ua TEXT, bot INTEGER NOT NULL DEFAULT 0,
    device TEXT, os TEXT, is_dl INTEGER NOT NULL DEFAULT 0, dl_file TEXT
  );
  CREATE INDEX IF NOT EXISTS idx_hits_day ON hits(day);
  CREATE INDEX IF NOT EXISTS idx_hits_ip ON hits(ip);
  CREATE INDEX IF NOT EXISTS idx_hits_dl ON hits(is_dl);
  CREATE INDEX IF NOT EXISTS idx_hits_dl_day ON hits(is_dl, day);
  CREATE INDEX IF NOT EXISTS idx_hits_day_bot ON hits(day, bot);
  CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT);
  CREATE TABLE IF NOT EXISTS ipgeo(ip TEXT PRIMARY KEY, country TEXT, region TEXT, city TEXT, at INTEGER);
  CREATE TABLE IF NOT EXISTS alerts(
    id INTEGER PRIMARY KEY AUTOINCREMENT, at TEXT NOT NULL, level TEXT NOT NULL,
    key TEXT NOT NULL, title TEXT NOT NULL, detail TEXT NOT NULL, sent INTEGER DEFAULT 0
  );
`);

// 老库补列（v2 → v3）
for (const col of ['country', 'region', 'city']) {
  const has = db.prepare('PRAGMA table_info(hits)').all().some((c) => c.name === col);
  if (!has) db.exec(`ALTER TABLE hits ADD COLUMN ${col} TEXT DEFAULT ''`);
}

const q = (sql, ...args) => db.prepare(sql).all(...args);
const one = (sql, ...args) => db.prepare(sql).get(...args);
const run = (sql, ...args) => db.prepare(sql).run(...args);

function metaGet(k, d = null) {
  const r = one('SELECT v FROM meta WHERE k = ?', k);
  return r ? r.v : d;
}
function metaSet(k, v) {
  run('INSERT INTO meta(k, v) VALUES(?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v', k, String(v));
}

function localDay(offsetDays = 0) {
  const d = new Date(Date.now() + offsetDays * 86400000);
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

function deviceOf(ua) {
  if (/iPad|Tablet|PlayBook|Silk/i.test(ua)) return 'tablet';
  if (/Mobile|Android|iPhone|iPod/i.test(ua)) return 'mobile';
  return 'desktop';
}
function osOf(ua) {
  if (/Android/i.test(ua)) return 'Android';
  if (/iPhone|iPad|iPod/i.test(ua)) return 'iOS';
  if (/Windows/i.test(ua)) return 'Windows';
  if (/Mac OS X|Macintosh/i.test(ua)) return 'macOS';
  if (/Linux/i.test(ua)) return 'Linux';
  return '其他';
}
function hostOf(ref) {
  if (!ref || ref === '-') return '';
  try {
    const h = new URL(ref).hostname.toLowerCase();
    return SELF_HOSTS.has(h) ? '' : h;
  } catch (_) {
    return '';
  }
}

// ── 地理位置（可选）──────────────────────────────────────
const geoCache = new Map();
function geoOf(ip) {
  const hit = geoCache.get(ip);
  if (hit) return hit;
  let out = { country: '', region: '', city: '' };
  if (geoip) {
    try {
      const r = geoip.lookup(ip);
      if (r) out = { country: r.country || '', region: r.region || '', city: r.city || '' };
    } catch (_) {}
  }
  if (out.country) {
    try {
      db.prepare('INSERT INTO ipgeo(ip,country,region,city,at) VALUES(?,?,?,?,?) ON CONFLICT(ip) DO UPDATE SET country=excluded.country, region=excluded.region, city=excluded.city, at=excluded.at')
        .run(ip, out.country, out.region, out.city, Date.now());
    } catch (_) {}
  }
  geoCache.set(ip, out);
  return out;
}

// ── 增量入库 ──────────────────────────────────────────────
let ingestAt = 0;
let backfillAt = 0;

/** 老数据补地理：每次最多 500 个 IP，避免启动时卡住；与是否有新日志无关。 */
function backfillGeo() {
  if (!geoip || Date.now() - backfillAt < 2000) return;
  backfillAt = Date.now();
  try {
    const pending = q("SELECT DISTINCT ip FROM hits WHERE country = '' OR country IS NULL LIMIT 500");
    for (const r of pending) {
      const g = geoOf(r.ip);
      if (g.country) run('UPDATE hits SET country=?, region=?, city=? WHERE ip=?', g.country, g.region, g.city, r.ip);
    }
  } catch (_) {}
}

function ingest(force = false) {
  if (!force && Date.now() - ingestAt < 5000) return;
  ingestAt = Date.now();
  backfillGeo();
  let st;
  try {
    st = fs.statSync(LOG_FILE);
  } catch (_) {
    return;
  }
  let offset = Number(metaGet('offset', 0)) || 0;
  const inode = String(st.ino);
  if (st.size < offset || metaGet('inode') !== inode) {
    offset = 0; // 轮转：从头读新文件
    metaSet('inode', inode);
  }
  if (st.size === offset) return;

  const fd = fs.openSync(LOG_FILE, 'r');
  const len = st.size - offset;
  const buf = Buffer.allocUnsafe(len);
  fs.readSync(fd, buf, 0, len, offset);
  fs.closeSync(fd);

  const text = buf.toString('utf8');
  const lastNl = text.lastIndexOf('\n');
  if (lastNl < 0) return; // 还没有完整行
  const complete = text.slice(0, lastNl + 1);
  metaSet('offset', offset + Buffer.byteLength(complete, 'utf8'));

  const ins = db.prepare(`INSERT INTO hits(ts,day,hour,ip,method,path,status,bytes,ref,ua,bot,device,os,is_dl,dl_file,country,region,city)
    VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`);
  const tx = () => {
    for (const line of complete.split('\n')) {
      if (!line) continue;
      const f = line.split('\t');
      if (f.length < 8) continue;
      const [ts, ip, method, uri, status, bytes, ref, ua] = f;
      if (!ts || !ip) continue;
      const day = ts.slice(0, 10);
      const hour = Number(ts.slice(11, 13)) || 0;
      const bot = BOT_RE.test(ua || '') ? 1 : 0;
      const isDl = uri.startsWith('/download/') && uri.endsWith('.apk') ? 1 : 0;
      const dlFile = isDl ? uri.split('/').pop() : null;
      const g = geoOf(ip);
      ins.run(ts, day, hour, ip, method, uri, Number(status) || 0, Number(bytes) || 0,
        hostOf(ref), ua || '', bot, deviceOf(ua || ''), osOf(ua || ''), isDl, dlFile,
        g.country, g.region, g.city);
    }
  };
  db.exec('BEGIN');
  try { tx(); db.exec('COMMIT'); } catch (e) { db.exec('ROLLBACK'); throw e; }
  run('DELETE FROM hits WHERE day < ?', localDay(-RETAIN_DAYS));


}

// ── 告警：检测 + 落库 + 可选邮件 ────────────────────────
const { spawn } = require('child_process');

function sendMail(subject, text) {
  return new Promise((resolve) => {
    if (!SMTP.to || !SMTP.SMTP_HOST || !SMTP.SMTP_USER) return resolve(false);
    // MAIL_FROM 可能是「小耄记账 <a@b.com>」这种带显示名的写法；
    // SMTP 的 MAIL FROM 只接受裸地址（126 对带显示名的会回 500）。
    const fromRaw = SMTP.MAIL_FROM || SMTP.SMTP_USER;
    const fromAddr = (/<([^>]+)>/.exec(fromRaw) || [null, fromRaw])[1].trim();
    const secure = String(SMTP.SMTP_SECURE || 'true').toLowerCase() !== 'false';
    const port = SMTP.SMTP_PORT || (secure ? '465' : '587');
    const cfgFile = path.join(path.dirname(DB_FILE), '.smtp.curl');
    const cfg = [
      `url = "${secure ? 'smtps' : 'smtp'}://${SMTP.SMTP_HOST}:${port}"`,
      `user = "${SMTP.SMTP_USER}:${SMTP.SMTP_PASS}"`,
      `mail-from = "${fromAddr}"`,
      `mail-rcpt = "${SMTP.to}"`,
    ].join('\n');
    try {
      fs.writeFileSync(cfgFile, cfg + '\n', { mode: 0o600 });
    } catch (_) { return resolve(false); }
    const msg = [
      `To: ${SMTP.to}`, `From: ${fromRaw}`,
      `Subject: =?UTF-8?B?${Buffer.from(subject, 'utf8').toString('base64')}?=`,
      'MIME-Version: 1.0', 'Content-Type: text/plain; charset=utf-8', '', text, '',
    ].join('\r\n');
    const args = ['-sS', '--config', cfgFile, '--upload-file', '-'];
    if (!secure) args.splice(1, 0, '--ssl-reqd');
    const cp = spawn('curl', args, { stdio: ['pipe', 'ignore', 'ignore'] });
    cp.on('error', () => resolve(false));
    cp.on('close', (code) => resolve(code === 0));
    cp.stdin.end(msg);
  });
}

const SERVICES = ['nginx', 'cloudflared', 'xiaomao-sync'];

function recentAlert(key, withinMin) {
  const since = new Date(Date.now() - withinMin * 60000).toISOString();
  return !!one('SELECT id FROM alerts WHERE key = ? AND at >= ?', key, since);
}

function pushAlert(level, key, title, detail) {
  if (recentAlert(key, 30)) return null;
  const at = new Date().toISOString();
  const sent = 0;
  run('INSERT INTO alerts(at, level, key, title, detail, sent) VALUES(?,?,?,?,?,?)', at, level, key, title, detail, sent);
  const row = one('SELECT * FROM alerts ORDER BY id DESC LIMIT 1');
  sendMail(`[小耄记账] ${title}`, `${title}\n\n${detail}\n\n时间：${at}\n后台：https://admin.xiaomao2.ccwu.cc/`)
    .then((ok) => { if (ok) run('UPDATE alerts SET sent = 1 WHERE id = ?', row.id); })
    .catch(() => {});
  return row;
}

async function checkAlerts() {
  const out = [];
  // 1) 服务状态
  for (const name of SERVICES) {
    let state = 'unknown';
    try { state = require('child_process').execFileSync('systemctl', ['is-active', name], { encoding: 'utf8' }).trim(); }
    catch (e) { state = (e.stdout || '').trim() || 'inactive'; }
    if (state !== 'active') out.push(pushAlert('critical', `svc:${name}`, `服务 ${name} 不是 active`, `当前：${state}`));
  }
  // 2) 近 10 分钟 5xx
  const from = new Date(Date.now() - 10 * 60000).toISOString().slice(0, 19).replace('T', 'T');
  const e5 = one('SELECT COUNT(*) n FROM hits WHERE ts >= ? AND status >= 500', from).n;
  if (e5 > 3) out.push(pushAlert('warn', '5xx', `近 10 分钟出现 ${e5} 次 5xx`, '去「日志检索」按 5xx 过滤看细节。'));
  // 3) 磁盘
  try {
    const df = require('child_process').execFileSync('df', ['-kP', '/'], { encoding: 'utf8' }).trim().split('\n').pop().split(/\s+/);
    const ratio = Number(df[2]) / Number(df[1]);
    if (ratio > 0.85) out.push(pushAlert('warn', 'disk', `磁盘占用 ${(ratio * 100).toFixed(1)}%`, `已用 ${df[2]}KB / 总 ${df[1]}KB`));
  } catch (_) {}
  // 4) 流量突增（今天 PV > max(50, 3× 近 7 日均值)）
  const today = localDay();
  const pvToday = one(`SELECT COUNT(*) n FROM hits WHERE day = ? AND is_dl=0 AND bot=0 AND status<400`, today).n;
  const avg = one(`SELECT AVG(pv) a FROM (SELECT day, COUNT(*) pv FROM hits
      WHERE day >= ? AND day < ? AND is_dl=0 AND bot=0 AND status<400 GROUP BY day)`, localDay(-7), today).a || 0;
  if (pvToday > Math.max(50, avg * 3)) {
    out.push(pushAlert('info', 'spike', `今日 PV 突增：${pvToday}`, `近 7 天日均 ${Math.round(avg)}。`));
  }
  return out.filter(Boolean);
}

// ── 查询 ──────────────────────────────────────────────────
const RANGES = { '1': 1, '7': 7, '14': 14, '30': 30, '90': 90 };
function fromDay(days) {
  return localDay(-(days - 1));
}

function overview(days) {
  const from = fromDay(days);
  const t = one(`SELECT
      SUM(CASE WHEN is_dl=0 AND bot=0 AND status<400 THEN 1 ELSE 0 END) pv,
      COUNT(DISTINCT CASE WHEN is_dl=0 AND bot=0 AND status<400 THEN ip END) uv,
      SUM(CASE WHEN is_dl=1 AND status=200 THEN 1 ELSE 0 END) dlHits,
      COUNT(DISTINCT CASE WHEN is_dl=1 AND status=200 THEN ip||'|'||dl_file END) dl,
      SUM(CASE WHEN status>=400 AND status<500 THEN 1 ELSE 0 END) e4,
      SUM(CASE WHEN status>=500 THEN 1 ELSE 0 END) e5,
      SUM(bot) bots, COUNT(*) total
    FROM hits WHERE day >= ?`, from);
  return { range: days, ...t };
}

function daily(days) {
  const from = fromDay(days);
  const rows = q(`SELECT day,
      SUM(CASE WHEN is_dl=0 AND bot=0 AND status<400 THEN 1 ELSE 0 END) pv,
      COUNT(DISTINCT CASE WHEN is_dl=0 AND bot=0 AND status<400 THEN ip END) uv,
      COUNT(DISTINCT CASE WHEN is_dl=1 AND status=200 THEN ip||'|'||dl_file END) dl
    FROM hits WHERE day >= ? GROUP BY day ORDER BY day`, from);
  const map = new Map(rows.map((r) => [r.day, r]));
  const out = [];
  for (let i = days - 1; i >= 0; i--) {
    const d = localDay(-i);
    const r = map.get(d);
    out.push({ day: d, pv: r ? r.pv : 0, uv: r ? r.uv : 0, dl: r ? r.dl : 0 });
  }
  return out;
}

function hourly(day) {
  const rows = q(`SELECT hour, SUM(CASE WHEN is_dl=0 AND bot=0 AND status<400 THEN 1 ELSE 0 END) pv,
      COUNT(DISTINCT CASE WHEN is_dl=0 AND bot=0 THEN ip END) uv
    FROM hits WHERE day = ? GROUP BY hour`, day);
  const map = new Map(rows.map((r) => [r.hour, r]));
  return Array.from({ length: 24 }, (_, h) => ({
    hour: h, pv: map.get(h)?.pv || 0, uv: map.get(h)?.uv || 0,
  }));
}

function pages(days, limit = 20) {
  return q(`SELECT path, COUNT(*) n FROM hits
    WHERE day >= ? AND is_dl=0 AND bot=0 GROUP BY path ORDER BY n DESC LIMIT ?`, fromDay(days), limit);
}

function downloads(days) {
  return q(`SELECT dl_file file, COUNT(*) hits, COUNT(DISTINCT ip||day) uniq
    FROM hits WHERE day >= ? AND is_dl=1 GROUP BY dl_file ORDER BY hits DESC`, fromDay(days));
}

function referrers(days) {
  return q(`SELECT ref host, COUNT(*) n FROM hits
    WHERE day >= ? AND is_dl=0 AND bot=0 AND ref<>'' GROUP BY ref ORDER BY n DESC LIMIT 15`, fromDay(days));
}

function devices(days) {
  return q(`SELECT device k, COUNT(*) n FROM hits
    WHERE day >= ? AND is_dl=0 AND bot=0 GROUP BY device`, fromDay(days));
}

function systems(days) {
  return q(`SELECT os k, COUNT(*) n FROM hits
    WHERE day >= ? AND is_dl=0 AND bot=0 GROUP BY os ORDER BY n DESC`, fromDay(days));
}

function geo(days) {
  const countries = q(`SELECT country k, COUNT(*) n FROM hits
    WHERE day >= ? AND is_dl=0 AND bot=0 AND country<>'' GROUP BY country ORDER BY n DESC LIMIT 15`, fromDay(days));
  const regions = q(`SELECT region||' · '||country k, COUNT(*) n FROM hits
    WHERE day >= ? AND is_dl=0 AND bot=0 AND region<>'' GROUP BY region, country ORDER BY n DESC LIMIT 15`, fromDay(days));
  const cities = q(`SELECT city||' · '||region k, COUNT(*) n FROM hits
    WHERE day >= ? AND is_dl=0 AND bot=0 AND city<>'' GROUP BY city, region ORDER BY n DESC LIMIT 15`, fromDay(days));
  return { countries, regions, cities };
}

function logs({ days = 7, q: kw = '', status = '', page = 1, size = 50 }) {
  const where = ['day >= ?'];
  const args = [fromDay(days)];
  if (kw) {
    where.push('(ip LIKE ? OR path LIKE ? OR ua LIKE ?)');
    const like = `%${kw}%`;
    args.push(like, like, like);
  }
  if (status === '4xx') where.push('status >= 400 AND status < 500');
  else if (status === '5xx') where.push('status >= 500');
  else if (status === 'bot') where.push('bot = 1');
  else if (status === 'dl') where.push('is_dl = 1');
  else if (status) { where.push('status = ?'); args.push(Number(status)); }
  const w = where.join(' AND ');
  const total = one(`SELECT COUNT(*) n FROM hits WHERE ${w}`, ...args).n;
  const rows = q(`SELECT ts, ip, method, path, status, bytes, ref, ua, bot, dl_file, country, region, city
    FROM hits WHERE ${w} ORDER BY id DESC LIMIT ? OFFSET ?`, ...args, size, (page - 1) * size);
  return { total, page, size, rows };
}

function systemInfo() {
  const out = {};
  try {
    const up = Number(fs.readFileSync('/proc/uptime', 'utf8').split(' ')[0]);
    out.uptime = Math.round(up);
  } catch (_) {}
  try {
    const mem = fs.readFileSync('/proc/meminfo', 'utf8');
    const g = (k) => Number((mem.match(new RegExp(`${k}:\\s+(\\d+)`)) || [])[1] || 0);
    out.memTotalKb = g('MemTotal');
    out.memAvailKb = g('MemAvailable');
  } catch (_) {}
  try {
    const df = execFileSync('df', ['-kP', '/'], { encoding: 'utf8' }).trim().split('\n').pop().split(/\s+/);
    out.diskTotalKb = Number(df[1]);
    out.diskUsedKb = Number(df[2]);
  } catch (_) {}
  try { out.logBytes = fs.statSync(LOG_FILE).size; } catch (_) {}
  try {
    out.dbBytes = fs.statSync(DB_FILE).size
      + (fs.existsSync(DB_FILE + '-wal') ? fs.statSync(DB_FILE + '-wal').size : 0);
  } catch (_) {}
  out.hits = one('SELECT COUNT(*) n FROM hits').n;
  out.oldest = (one('SELECT MIN(day) d FROM hits') || {}).d || null;
  const svc = (name) => {
    try {
      return execFileSync('systemctl', ['is-active', name], { encoding: 'utf8' }).trim();
    } catch (e) {
      return (e.stdout || '').trim() || 'unknown';
    }
  };
  out.services = {
    nginx: svc('nginx'),
    cloudflared: svc('cloudflared'),
    sync: svc('xiaomao-sync') !== 'unknown' ? svc('xiaomao-sync') : undefined,
    admin: 'active',
  };
  out.node = process.version;
  out.generatedAt = Date.now();
  return out;
}

// ── HTTP ──────────────────────────────────────────────────
const PAGE = `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>小耄记账 · 站点后台</title>
<style>
  :root{
    --bg:#FBF4E7; --panel:#FFFFFF; --ink:#26242B; --ink2:#6C6C7C; --ink3:#7A7683;
    --line:#EFE4D2; --brand:#FFB627; --brandInk:#4A3103; --onBrand:#2A1E00;
    --ok:#1F9D6B; --bad:#D64545; --chip:#F4EAD8;
  }
  @media (prefers-color-scheme: dark){
    :root{ --bg:#13110D; --panel:#201D17; --ink:#EDE7DC; --ink2:#B7B1A6; --ink3:#9A9386;
           --line:#3A342A; --brand:#FFB627; --brandInk:#FFE3B0; --onBrand:#2A1E00;
           --ok:#4BD6A0; --bad:#FF7B7B; --chip:#2A251C; }
  }
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif}
  a{color:inherit}
  .layout{display:flex;min-height:100vh}
  aside{width:190px;flex:none;background:var(--panel);border-right:2px solid var(--ink);padding:16px 12px;position:sticky;top:0;height:100vh}
  .brand{font-weight:900;font-size:15px;margin:0 0 14px 4px;display:flex;align-items:center;gap:8px}
  .brand i{width:10px;height:10px;border-radius:3px;background:var(--brand);border:2px solid var(--ink);display:block}
  nav a{display:block;padding:8px 10px;border-radius:10px;text-decoration:none;font-weight:700;color:var(--ink2);font-size:13px}
  nav a.on{background:var(--brand);color:var(--onBrand);border:2px solid var(--ink)}
  nav a:hover{color:var(--ink)}
  .side-foot{margin-top:auto;font-size:11px;color:var(--ink3);position:absolute;bottom:14px;left:18px}
  main{flex:1;min-width:0;padding:18px 22px 40px}
  .topbar{display:flex;align-items:center;gap:10px;flex-wrap:wrap;margin-bottom:14px}
  .topbar h1{font-size:17px;margin:0;font-weight:900}
  .spacer{flex:1}
  .seg{display:inline-flex;border:2px solid var(--ink);border-radius:10px;overflow:hidden}
  .seg button{font:inherit;font-weight:800;font-size:12px;padding:5px 10px;border:0;background:var(--panel);color:var(--ink2);cursor:pointer}
  .seg button.on{background:var(--brand);color:var(--onBrand)}
  .meta{font-size:11.5px;color:var(--ink3);font-weight:600}
  .kpis{display:grid;grid-template-columns:repeat(6,1fr);gap:10px}
  @media (max-width:980px){ .kpis{grid-template-columns:repeat(3,1fr)} }
  @media (max-width:560px){ .kpis{grid-template-columns:repeat(2,1fr)} }
  .kpi{background:var(--panel);border:2px solid var(--ink);border-radius:14px;padding:10px 12px}
  .kpi b{display:block;font-size:22px;font-weight:900;letter-spacing:-.4px;font-variant-numeric:tabular-nums}
  .kpi span{font-size:11.5px;font-weight:700;color:var(--ink2)}
  .kpi.hi{background:var(--brand);color:var(--brandInk)}
  .kpi.hi span{color:var(--brandInk)}
  .grid{display:grid;grid-template-columns:1.4fr 1fr;gap:12px;margin-top:12px}
  @media (max-width:900px){ .grid{grid-template-columns:1fr} }
  .panel{background:var(--panel);border:2px solid var(--ink);border-radius:14px;padding:12px 14px}
  .panel h2{font-size:12.5px;margin:0 0 8px;font-weight:900;letter-spacing:.2px}
  .panel .sub{font-size:11px;color:var(--ink3);margin:-4px 0 8px}
  table{width:100%;border-collapse:collapse;font-size:12.5px}
  th,td{text-align:left;padding:5px 4px;border-bottom:1px dashed var(--line);font-weight:600;vertical-align:top}
  th{font-size:11px;color:var(--ink3);font-weight:800}
  td.n{text-align:right;font-variant-numeric:tabular-nums;font-weight:800}
  code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:11.5px;word-break:break-all}
  .muted{color:var(--ink3);font-size:12px}
  .chips{display:flex;flex-wrap:wrap;gap:6px;margin-top:6px}
  .chip{border:1.5px solid var(--ink);border-radius:999px;padding:2px 9px;font-size:11.5px;font-weight:700;color:var(--ink2);background:var(--chip)}
  .filters{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin-bottom:8px}
  .filters input,.filters select{font:inherit;font-size:12.5px;padding:5px 8px;border:2px solid var(--ink);border-radius:9px;background:var(--panel);color:var(--ink)}
  .filters input[type=search]{min-width:220px}
  .btn{font:inherit;font-weight:800;font-size:12.5px;padding:5px 12px;border:2px solid var(--ink);border-radius:9px;background:var(--brand);color:var(--onBrand);cursor:pointer;text-decoration:none;display:inline-block}
  .btn.ghost{background:var(--panel);color:var(--ink)}
  .pager{display:flex;gap:10px;align-items:center;justify-content:flex-end;margin-top:8px;font-size:12px;color:var(--ink2)}
  .empty{padding:18px;text-align:center;color:var(--ink3);font-size:12.5px}
  svg{display:block;width:100%;height:auto;overflow:visible}
  .tick{font-size:10px;fill:var(--ink3)}
  .legend{display:flex;gap:14px;font-size:11.5px;color:var(--ink2);font-weight:700;margin-top:6px}
  .legend i{display:inline-block;width:12px;height:3px;margin-right:5px;vertical-align:3px;border-radius:2px}
  .bad{color:var(--bad);font-weight:800}
  .ok{color:var(--ok);font-weight:800}
</style>
</head>
<body>
<div class="layout">
  <aside>
    <div class="brand"><i></i>小耄记账 · 后台</div>
    <nav id="nav">
      <a href="#overview" data-view="overview">概览</a>
      <a href="#traffic" data-view="traffic">流量</a>
      <a href="#downloads" data-view="downloads">下载</a>
      <a href="#referrers" data-view="referrers">来源</a>
      <a href="#geo" data-view="geo">地域</a>
      <a href="#logs" data-view="logs">日志检索</a>
      <a href="#alerts" data-view="alerts">告警 <b id="alertBadge" style="display:none;background:var(--bad);color:#fff;border-radius:9px;padding:0 6px;font-size:11px">0</b></a>
      <a href="#system" data-view="system">系统状态</a>
    </nav>
    <div class="side-foot">数据：Nginx 日志 · 保留 90 天</div>
  </aside>
  <main>
    <div class="topbar">
      <h1 id="title">概览</h1>
      <div class="spacer"></div>
      <div class="seg" id="range">
        <button data-days="1">今天</button>
        <button data-days="7">7 天</button>
        <button data-days="14">14 天</button>
        <button data-days="30">30 天</button>
      </div>
      <span class="meta" id="meta">读取中…</span>
    </div>
    <div id="view"></div>
  </main>
</div>
<script>
(function () {
  var state = { view: 'overview', days: 7, page: 1, q: '', status: '' };
  var $ = function (s) { return document.querySelector(s); };
  var view = function () { return $('#view'); };
  var fmt = function (n) { return (n == null ? 0 : n).toLocaleString('zh-CN'); };
  var esc = function (s) { return String(s == null ? '' : s).replace(/[&<>"]/g, function (c) { return ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'})[c]; }); };
  var api = function (path) { return fetch(path, { cache: 'no-store' }).then(function (r) { return r.json(); }); };

  function lineChart(rows, series) {
    var w = 720, h = 200, pad = { l: 34, r: 12, t: 10, b: 22 };
    var n = rows.length || 1;
    var max = 1;
    rows.forEach(function (r) { series.forEach(function (s) { max = Math.max(max, r[s.key] || 0); }); });
    var x = function (i) { return pad.l + (w - pad.l - pad.r) * (n === 1 ? .5 : i / (n - 1)); };
    var y = function (v) { return pad.t + (h - pad.t - pad.b) * (1 - (v || 0) / max); };
    var svg = ['<svg viewBox="0 0 ' + w + ' ' + h + '" role="img">'];
    svg.push('<line x1="' + pad.l + '" y1="' + (h - pad.b) + '" x2="' + (w - pad.r) + '" y2="' + (h - pad.b) + '" stroke="currentColor" stroke-opacity=".25"/>');
    [0, .5, 1].forEach(function (f) {
      var v = Math.round(max * f), yy = y(v);
      svg.push('<line x1="' + pad.l + '" y1="' + yy + '" x2="' + (w - pad.r) + '" y2="' + yy + '" stroke="currentColor" stroke-opacity=".08"/>');
      svg.push('<text class="tick" x="4" y="' + (yy + 3) + '">' + v + '</text>');
    });
    series.forEach(function (s) {
      var pts = rows.map(function (r, i) { return x(i) + ',' + y(r[s.key]); }).join(' ');
      svg.push('<polyline fill="none" stroke="' + s.color + '" stroke-width="2.4" stroke-linejoin="round" stroke-linecap="round" points="' + pts + '"/>');
      rows.forEach(function (r, i) {
        svg.push('<circle cx="' + x(i) + '" cy="' + y(r[s.key]) + '" r="2.6" fill="' + s.color + '"><title>' + esc(r.day) + ' · ' + esc(s.label) + ' ' + fmt(r[s.key]) + '</title></circle>');
      });
    });
    var step = Math.ceil(n / 8);
    rows.forEach(function (r, i) {
      if (i % step) return;
      svg.push('<text class="tick" x="' + x(i) + '" y="' + (h - 6) + '" text-anchor="middle">' + r.day.slice(5) + '</text>');
    });
    svg.push('</svg>');
    return svg.join('');
  }

  function barChart(rows, key) {
    var w = 720, h = 150, pad = { l: 30, r: 8, t: 8, b: 18 };
    var max = Math.max(1, Math.max.apply(null, rows.map(function (r) { return r[key] || 0; })));
    var bw = (w - pad.l - pad.r) / rows.length;
    var svg = ['<svg viewBox="0 0 ' + w + ' ' + h + '">'];
    rows.forEach(function (r, i) {
      var bh = (h - pad.t - pad.b) * (r[key] || 0) / max;
      var x = pad.l + i * bw + 2, y = h - pad.b - bh;
      svg.push('<rect x="' + x + '" y="' + y + '" width="' + Math.max(2, bw - 4) + '" height="' + bh + '" rx="2" fill="var(--brand)" stroke="currentColor" stroke-opacity=".35"><title>' + r.hour + ':00 · ' + fmt(r[key]) + '</title></rect>');
      if (i % 3 === 0) svg.push('<text class="tick" x="' + (x + bw / 2) + '" y="' + (h - 4) + '" text-anchor="middle">' + r.hour + '</text>');
    });
    svg.push('</svg>');
    return svg.join('');
  }

  function table(head, rows, empty) {
    if (!rows.length) return '<div class="empty">' + (empty || '还没有数据') + '</div>';
    return '<table><tr>' + head.map(function (h) { return '<th>' + h + '</th>'; }).join('') + '</tr>' + rows.join('') + '</table>';
  }

  var VIEWS = {
    overview: function (d) {
      var o = d.overview;
      var html = '<div class="kpis">'
        + kpi('PV', o.pv, true) + kpi('UV', o.uv) + kpi('下载', o.dl)
        + kpi('4xx', o.e4) + kpi('5xx', o.e5) + kpi('Bot', o.bots)
        + '</div>'
        + '<div class="grid"><div class="panel"><h2>趋势</h2>'
        + lineChart(d.daily, [{ key: 'pv', label: 'PV', color: 'var(--brand)' }, { key: 'uv', label: 'UV', color: 'var(--ok)' }, { key: 'dl', label: '下载', color: 'var(--bad)' }])
        + '<div class="legend"><span><i style="background:var(--brand)"></i>PV</span><span><i style="background:var(--ok)"></i>UV</span><span><i style="background:var(--bad)"></i>下载</span></div></div>'
        + '<div class="panel"><h2>今天按小时</h2><div id="hourly" class="muted">读取中…</div></div></div>';
      return html;
    },
    traffic: function (d) {
      var rows = d.daily.map(function (r) {
        return '<tr><td>' + r.day + '</td><td class="n">' + fmt(r.pv) + '</td><td class="n">' + fmt(r.uv) + '</td><td class="n">' + fmt(r.dl) + '</td></tr>';
      });
      var dev = d.devices.map(function (x) { return '<span class="chip">' + esc(x.k) + ' ' + fmt(x.n) + '</span>'; }).join('');
      var os = d.systems.map(function (x) { return '<span class="chip">' + esc(x.k) + ' ' + fmt(x.n) + '</span>'; }).join('');
      return '<div class="grid"><div class="panel"><h2>按日</h2>'
        + table(['日期', 'PV', 'UV', '下载'], rows)
        + '</div><div class="panel"><h2>热门页面</h2>'
        + table(['路径', '次数'], d.pages.map(function (p) { return '<tr><td><code>' + esc(p.path) + '</code></td><td class="n">' + fmt(p.n) + '</td></tr>'; }))
        + '<h2 style="margin-top:12px">设备 / 系统</h2><div class="chips">' + dev + '</div><div class="chips">' + os + '</div></div></div>';
    },
    downloads: function (d) {
      var rows = d.downloads.map(function (x) {
        var m = /yanxin-v([0-9.]+)-(arm64-v8a|armeabi-v7a|x86_64)-release\.apk/.exec(x.file || '');
        var label = m ? (m[1] + ' · ' + m[2]) : (x.file || '—');
        return '<tr><td>' + esc(label) + '</td><td class="n">' + fmt(x.hits) + '</td><td class="n">' + fmt(x.uniq) + '</td></tr>';
      });
      return '<div class="grid"><div class="panel"><h2>按版本 · 架构</h2>'
        + table(['版本 · 架构', '下载次数', '去重'], rows, '还没有下载')
        + '<p class="sub" style="margin-top:8px">次数按请求计；「去重」= IP + 文件 + 天。206 分段续传不计。</p></div>'
        + '<div class="panel"><h2>下载趋势</h2>' + lineChart(d.daily, [{ key: 'dl', label: '下载', color: 'var(--brand)' }]) + '</div></div>';
    },
    referrers: function (d) {
      return '<div class="grid"><div class="panel"><h2>站外来源</h2>'
        + table(['来源', '次数'], d.referrers.map(function (r) { return '<tr><td>' + esc(r.host) + '</td><td class="n">' + fmt(r.n) + '</td></tr>'; }), '还没有站外来源')
        + '</div><div class="panel"><h2>设备</h2><div class="chips">'
        + d.devices.map(function (x) { return '<span class="chip">' + esc(x.k) + ' ' + fmt(x.n) + '</span>'; }).join('')
        + '</div><p class="sub" style="margin-top:10px">直接输入网址 / App 内打开通常没有 referer，会记为空。</p></div></div>';
    },
    geo: function (d) {
      var bars = function (rows, key) {
        if (!rows.length) return '<div class="empty">还没有地域数据</div>';
        var max = Math.max.apply(null, rows.map(function (r) { return r.n; })) || 1;
        return '<table><tr><th>' + key + '</th><th style="text-align:right">次数</th></tr>' + rows.map(function (r) {
          var pct = Math.round(r.n / max * 100);
          return '<tr><td><div style="display:flex;align-items:center;gap:8px"><span style="min-width:90px">' + esc(r.k) + '</span>'
            + '<span style="flex:1;height:8px;background:var(--chip);border-radius:4px;overflow:hidden"><i style="display:block;width:' + pct + '%;height:100%;background:var(--brand)"></i></span>'
            + '</div></td><td class="n">' + fmt(r.n) + '</td></tr>';
        }).join('') + '</table>';
      };
      return '<div class="grid"><div class="panel"><h2>国家 / 地区</h2>' + bars(d.countries, '国家')
        + '</div><div class="panel"><h2>省份 · 城市</h2>' + bars(d.regions, '省份') + '<h2 style="margin-top:12px">城市</h2>' + bars(d.cities, '城市') + '</div></div>';
    },
    alerts: function (d) {
      var rows = d.rows.map(function (a) {
        var cls = a.level === 'critical' ? 'bad' : (a.level === 'warn' ? 'bad' : 'ok');
        return '<tr><td class="muted">' + esc(a.at.slice(5, 16).replace('T', ' ')) + '</td>'
          + '<td class="' + cls + '">' + esc(a.level) + '</td><td>' + esc(a.title) + '</td>'
          + '<td class="muted">' + esc(a.detail) + '</td><td class="muted">' + (a.sent ? '已邮件' : '站内') + '</td></tr>';
      });
      return '<div class="panel"><div class="filters"><button class="btn" id="check-alerts">立即巡检</button>'
        + '<span class="muted">每 5 分钟自动巡检：服务状态 / 10 分钟内 5xx / 磁盘 > 85% / 今日 PV 突增</span></div>'
        + table(['时间', '级别', '内容', '详情', '通知'], rows, '还没有告警') + '</div>';
    },
    logs: function () {
      return '<div class="panel"><div class="filters">'
        + '<input id="q" type="search" placeholder="搜 IP / 路径 / UA" value="' + esc(state.q) + '">'
        + '<select id="status"><option value="">全部状态</option><option value="4xx">4xx</option><option value="5xx">5xx</option>'
        + '<option value="200">200</option><option value="206">206</option><option value="dl">仅下载</option><option value="bot">仅 Bot</option></select>'
        + '<button class="btn" id="do-search">搜索</button>'
        + '<a class="btn ghost" href="/export.csv" target="_blank" rel="noopener">导出 CSV</a>'
        + '</div><div id="logtable"></div><div class="pager" id="pager"></div></div>';
    },
    system: function (d) {
      var s = d;
      var mb = function (kb) { return (kb / 1024).toFixed(0) + ' MB'; };
      var gb = function (kb) { return (kb / 1024 / 1024).toFixed(1) + ' GB'; };
      var up = Math.floor((s.uptime || 0) / 86400) + ' 天 ' + Math.floor(((s.uptime || 0) % 86400) / 3600) + ' 小时';
      var svc = Object.keys(s.services).filter(function (k) { return s.services[k]; }).map(function (k) {
        var v = s.services[k];
        return '<span class="chip">' + k + ' <span class="' + (v === 'active' ? 'ok' : 'bad') + '">' + esc(v) + '</span></span>';
      }).join('');
      return '<div class="kpis">'
        + kpi('已入库', s.hits) + kpi('日志文件', (s.logBytes / 1024).toFixed(0) + ' KB') + kpi('数据库', (s.dbBytes / 1024).toFixed(0) + ' KB')
        + kpi('内存可用', mb(s.memAvailKb)) + kpi('磁盘占用', gb(s.diskUsedKb)) + kpi('节点', s.node)
        + '</div><div class="grid"><div class="panel"><h2>服务</h2><div class="chips">' + svc + '</div>'
        + '<p class="sub" style="margin-top:10px">运行时长 ' + up + ' · 最早数据 ' + esc(s.oldest || '—') + '</p></div>'
        + '<div class="panel"><h2>说明</h2><p class="sub">后台只读 Nginx 访问日志，不记录任何用户内容；'
        + '保留 ' + 90 + ' 天，超期自动清理。数据文件 <code>' + esc(s.dbBytes ? 'hits.db' : '—') + '</code>。</p></div></div>';
    }
  };

  function kpi(label, value, hi) {
    return '<div class="kpi' + (hi ? ' hi' : '') + '"><b>' + fmt(value) + '</b><span>' + label + '</span></div>';
  }

  function loadBadge() {
    fetch('/api/alerts', { cache: 'no-store' }).then(function (r) { return r.json(); }).then(function (d) {
      var b = document.getElementById('alertBadge');
      if (!b) return;
      b.style.display = d.unread ? 'inline-block' : 'none';
      b.textContent = d.unread;
    }).catch(function () {});
  }

  function load() {
    var v = state.view;
    loadBadge();
    $('#meta').textContent = '读取中…';
    var p;
    if (v === 'overview') p = api('/api/overview?range=' + state.days).then(function (d) {
      view().innerHTML = VIEWS.overview(d);
      api('/api/hourly').then(function (h) {
        var el = $('#hourly');
        if (el) el.outerHTML = '<div id="hourly">' + barChart(h, 'pv') + '</div>';
      });
    });
    else if (v === 'traffic') p = api('/api/traffic?range=' + state.days).then(function (d) { view().innerHTML = VIEWS.traffic(d); });
    else if (v === 'downloads') p = api('/api/downloads?range=' + state.days).then(function (d) { view().innerHTML = VIEWS.downloads(d); });
    else if (v === 'referrers') p = api('/api/referrers?range=' + state.days).then(function (d) { view().innerHTML = VIEWS.referrers(d); });
    else if (v === 'geo') p = api('/api/geo?range=' + state.days).then(function (d) { view().innerHTML = VIEWS.geo(d); });
    else if (v === 'alerts') {
      view().innerHTML = '<div class="muted">读取中…</div>';
      p = api('/api/alerts').then(function (d) {
        view().innerHTML = VIEWS.alerts(d);
        $('#check-alerts').onclick = function () {
          fetch('/api/alerts/check', { cache: 'no-store' }).then(function () { load(); });
        };
      });
    }
    else if (v === 'system') p = api('/api/system').then(function (d) { view().innerHTML = VIEWS.system(d); });
    else if (v === 'logs') {
      view().innerHTML = VIEWS.logs();
      $('#status').value = state.status;
      $('#do-search').onclick = function () {
        state.q = $('#q').value.trim(); state.status = $('#status').value; state.page = 1; loadLogs();
      };
      $('#q').addEventListener('keydown', function (e) { if (e.key === 'Enter') $('#do-search').click(); });
      $('#status').onchange = function () { state.status = $('#status').value; state.page = 1; loadLogs(); };
      p = loadLogs();
    }
    Promise.resolve(p).then(function () {
      $('#meta').textContent = '更新于 ' + new Date().toLocaleTimeString('zh-CN');
    }).catch(function (e) {
      $('#meta').textContent = '读取失败';
      view().innerHTML = '<div class="panel empty">' + esc(e) + '</div>';
    });
  }

  function loadLogs() {
    var url = '/api/logs?range=' + state.days + '&page=' + state.page + '&q=' + encodeURIComponent(state.q) + '&status=' + encodeURIComponent(state.status);
    return api(url).then(function (d) {
      var rows = d.rows.map(function (r) {
        var cls = r.status >= 500 ? 'bad' : (r.status >= 400 ? 'bad' : '');
        return '<tr><td class="muted">' + esc(r.ts.slice(5, 19).replace('T', ' ')) + '</td><td><code>' + esc(r.ip) + '</code></td>'
          + '<td><code>' + esc(r.path) + '</code></td><td class="' + cls + '">' + r.status + '</td>'
          + '<td class="muted">' + (r.dl_file ? '⬇ ' + esc(r.dl_file) : '') + '</td>'
          + '<td class="muted">' + esc([r.country, r.region, r.city].filter(Boolean).join(' · ') || '—') + '</td>'
          + '<td class="muted" title="' + esc(r.ua) + '">' + esc((r.ua || '').slice(0, 42)) + '</td></tr>';
      });
      $('#logtable').innerHTML = table(['时间', 'IP', '路径', '状态', '下载', '地区', 'UA'], rows, '没有匹配的记录');
      var pages = Math.max(1, Math.ceil(d.total / d.size));
      $('#pager').innerHTML = '<span>共 ' + fmt(d.total) + ' 条 · 第 ' + d.page + ' / ' + pages + ' 页</span>'
        + '<button class="btn ghost" data-p="' + (d.page - 1) + '"' + (d.page <= 1 ? ' disabled' : '') + '>上一页</button>'
        + '<button class="btn ghost" data-p="' + (d.page + 1) + '"' + (d.page >= pages ? ' disabled' : '') + '>下一页</button>';
      [].forEach.call(document.querySelectorAll('#pager button'), function (b) {
        b.onclick = function () { state.page = Number(b.getAttribute('data-p')); loadLogs(); };
      });
    });
  }

  function syncNav() {
    [].forEach.call(document.querySelectorAll('#nav a'), function (a) {
      a.classList.toggle('on', a.getAttribute('data-view') === state.view);
    });
    [].forEach.call(document.querySelectorAll('#range button'), function (b) {
      b.classList.toggle('on', Number(b.getAttribute('data-days')) === state.days);
    });
    $('#title').textContent = ({ overview: '概览', traffic: '流量', downloads: '下载', referrers: '来源', geo: '地域', logs: '日志检索', alerts: '告警', system: '系统状态' })[state.view];
  }

  [].forEach.call(document.querySelectorAll('#nav a'), function (a) {
    a.onclick = function (e) {
      e.preventDefault();
      state.view = a.getAttribute('data-view'); state.page = 1;
      history.replaceState(null, '', '#' + state.view);
      syncNav(); load();
    };
  });
  [].forEach.call(document.querySelectorAll('#range button'), function (b) {
    b.onclick = function () {
      state.days = Number(b.getAttribute('data-days')); state.page = 1;
      syncNav(); load();
    };
  });
  var init = (location.hash || '').replace('#', '');
  if (init && VIEWS[init]) state.view = init;
  syncNav(); load();
  setInterval(function () { if (document.visibilityState === 'visible') load(); }, 60000);
})();
</script>
</body>
</html>
`;

function json(res, obj, code = 200) {
  res.writeHead(code, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
  res.end(JSON.stringify(obj));
}

const server = http.createServer((req, res) => {
  try { ingest(); } catch (e) { /* 入库失败也要让页面能打开 */ }
  const u = new URL(req.url, 'http://x');
  const p = u.pathname;
  const days = RANGES[u.searchParams.get('range')] || 7;

  if (p === '/healthz') {
    res.writeHead(200, { 'content-type': 'text/plain' });
    return res.end('ok');
  }
  if (p === '/api/overview') return json(res, { overview: overview(days), daily: daily(days) });
  if (p === '/api/traffic') return json(res, {
    daily: daily(days), pages: pages(days), devices: devices(days), systems: systems(days),
  });
  if (p === '/api/downloads') return json(res, { downloads: downloads(days), daily: daily(days) });
  if (p === '/api/referrers') return json(res, { referrers: referrers(days), devices: devices(days) });
  if (p === '/api/logs') return json(res, logs({
    days,
    q: (u.searchParams.get('q') || '').trim(),
    status: (u.searchParams.get('status') || '').trim(),
    page: Math.max(1, Number(u.searchParams.get('page') || 1)),
    size: Math.min(200, Math.max(10, Number(u.searchParams.get('size') || 50))),
  }));
  if (p === '/api/geo') return json(res, geo(days));
  if (p === '/api/alerts') return json(res, {
    unread: one('SELECT COUNT(*) n FROM alerts WHERE sent = 0').n,
    rows: q('SELECT id, at, level, title, detail, sent FROM alerts ORDER BY id DESC LIMIT 30'),
  });
  if (p === '/api/alerts/test') {
    sendMail('[小耄记账] 告警通道测试', '这是一封来自站点后台的测试邮件。收到它说明 SMTP 配置可用。')
      .then((ok) => json(res, { sent: ok, to: SMTP.to || null }));
    return;
  }
  if (p === '/api/alerts/check') {
    checkAlerts().then((a) => json(res, { created: a.length })).catch((e) => json(res, { error: String(e) }, 500));
    return;
  }
  if (p === '/api/hourly') return json(res, hourly(u.searchParams.get('day') || localDay()));
  if (p === '/api/system') return json(res, systemInfo());
  if (p === '/export.csv') {
    // 导出「最近 90 天」的全部命中（上限 5 万行，防止一次拉爆内存）
    const r = logs({ days: 90, size: 50000, page: 1 });
    const head = 'ts,ip,method,path,status,bytes,bot,dl_file,ua\n';
    const esc = (v) => `"${String(v ?? '').replace(/"/g, '""')}"`;
    const body = r.rows.map((x) => [x.ts, x.ip, x.method, x.path, x.status, x.bytes, x.bot, x.dl_file, x.ua].map(esc).join(',')).join('\n');
    res.writeHead(200, { 'content-type': 'text/csv; charset=utf-8', 'content-disposition': 'attachment; filename="xiaomao-hits.csv"' });
    return res.end('\ufeff' + head + body);
  }
  res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
  res.end(PAGE);
});

server.listen(PORT, HOST, () => console.log(`[xiaomao-admin] http://${HOST}:${PORT} log=${LOG_FILE} db=${DB_FILE}`));

setTimeout(() => { checkAlerts().catch(() => {}); }, 8000);
setInterval(() => { checkAlerts().catch(() => {}); }, 5 * 60000);
