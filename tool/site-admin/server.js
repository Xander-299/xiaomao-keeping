#!/usr/bin/env node
/**
 * 小耄记账 · 站点访问后台（2026-11-24）
 *
 * 设计取舍：
 * - **零依赖**：只用 Node 内置模块，机房小机器（1.7G）上不该为统计再装一套运行时/数据库；
 * - **读 Nginx 日志**而不是前端埋点：APK 是直链下载，只有服务端日志能数准（还能分版本/架构）；
 * - 日志由 Nginx 的 `xiaomao` 格式写入（Tab 分隔、真实 IP 取 `CF-Connecting-IP`）；
 * - 只在 127.0.0.1:8081 监听，公网入口由 Nginx（basic auth）+ Cloudflare 隧道提供；
 * - 解析结果缓存 30s，日志再大也不会每次刷新都全量扫。
 */
'use strict';

const http = require('http');
const fs = require('fs');

const LOG_FILE = process.env.XM_LOG || '/www/wwwlogs/xiaomao2.log';
const PORT = Number(process.env.XM_PORT || 8081);
const HOST = '127.0.0.1';
const CACHE_MS = 30 * 1000;
const DAYS = 14;

const BOT_RE = /bot|crawler|spider|slurp|bingpreview|facebookexternalhit|headless|python-requests|curl\/|wget|monitor|uptime|pingdom|semrush|ahrefs|bytespider|petalbot/i;
const ASSET_RE = /\.(png|jpe?g|webp|avif|gif|svg|ico|css|js|map|txt|xml|woff2?)$/i;

const cache = { at: 0, data: null };

function dayOf(ts) {
  return ts.slice(0, 10);
}

/** 服务器本地日期（日志用 +08:00 本地时间，别用 toISOString 的 UTC）。 */
function localDay(offsetDays = 0) {
  const d = new Date(Date.now() + offsetDays * 86400000);
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

function parseLine(line) {
  const f = line.split('\t');
  if (f.length < 8) return null;
  const [ts, ip, method, uri, status, bytes, ref, ua] = f;
  if (!ts || !ip) return null;
  return {
    ts,
    day: dayOf(ts),
    ip,
    method,
    uri,
    status: Number(status) || 0,
    bytes: Number(bytes) || 0,
    ref: ref || '',
    ua: ua || '',
    bot: BOT_RE.test(ua || ''),
    asset: ASSET_RE.test(uri || ''),
  };
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
  if (!ref) return '';
  try {
    const u = new URL(ref);
    return u.hostname.toLowerCase();
  } catch (_) {
    return '';
  }
}

function bump(map, key, n = 1) {
  map.set(key, (map.get(key) || 0) + n);
}

function topEntries(map, n) {
  return [...map.entries()].sort((a, b) => b[1] - a[1]).slice(0, n)
    .map(([key, count]) => ({ key, count }));
}

function build() {
  let raw = '';
  try {
    raw = fs.readFileSync(LOG_FILE, 'utf8');
  } catch (e) {
    return { error: `读不到日志：${LOG_FILE}（${e.code || e.message}）`, generatedAt: Date.now() };
  }

  const lines = raw.split('\n');
  const today = localDay();
  const perDay = new Map(); // day -> {pv, uvSet, dlSet, dlHits}
  const pageMap = new Map();
  const dlMap = new Map();
  const refMap = new Map();
  const osMap = new Map();
  const devices = { mobile: 0, tablet: 0, desktop: 0, bot: 0 };
  const recent = [];
  let pvTotal = 0;
  let dlHitsTotal = 0;
  let parsed = 0;

  const ensureDay = (d) => {
    if (!perDay.has(d)) perDay.set(d, { pv: 0, uv: new Set(), dl: new Set(), dlHits: 0 });
    return perDay.get(d);
  };

  for (const line of lines) {
    if (!line) continue;
    const r = parseLine(line);
    if (!r) continue;
    parsed++;
    const d = ensureDay(r.day);

    if (r.bot) {
      devices.bot++;
      continue;
    }

    // 下载：APK 直链（只算完整下载 200；206 分段不计，避免续传把数字翻倍）
    if (r.uri.startsWith('/download/') && r.uri.endsWith('.apk')) {
      const file = r.uri.split('/').pop();
      if (r.status === 200) {
        d.dlHits++;
        d.dl.add(`${r.ip}|${file}`);
        dlHitsTotal++;
        const m = file.match(/yanxin-v([0-9.]+)-(arm64-v8a|armeabi-v7a|x86_64)-release\.apk/);
        const key = m ? `${m[1]} · ${m[2]}` : file;
        bump(dlMap, key);
      }
      continue;
    }

    // 页面浏览：非静态资源、非下载、2xx/3xx
    const isDoc = !r.asset && (r.method === 'GET' || r.method === 'HEAD');
    if (isDoc && r.status >= 200 && r.status < 400) {
      d.pv++;
      d.uv.add(r.ip);
      pvTotal++;
      bump(pageMap, r.uri.split('?')[0]);
      const h = hostOf(r.ref);
      if (h && h !== 'xiaomao2.ccwu.cc' && h !== 'www.xiaomao2.ccwu.cc') bump(refMap, h);
      devices[deviceOf(r.ua)]++;
      bump(osMap, osOf(r.ua));
    } else if (isDoc) {
      // 404 之类也记在热门页面里，方便发现坏链
      bump(pageMap, r.uri.split('?')[0]);
    }

    if (recent.length < 40 && !r.asset) {
      recent.push({
        time: r.ts.replace('T', ' ').slice(5, 19),
        path: r.uri,
        status: r.status,
        ip: r.ip.replace(/^(\d+\.\d+)\.\d+\.\d+$/, '$1.*.*'),
        ua: r.ua.slice(0, 90),
      });
    }
  }

  // 连续 14 天（没有流量的日子补 0，图上才不会断档）
  const days = [];
  for (let i = DAYS - 1; i >= 0; i--) {
    const day = localDay(-i);
    const d = perDay.get(day);
    days.push({
      day,
      pv: d ? d.pv : 0,
      uv: d ? d.uv.size : 0,
      dl: d ? d.dl.size : 0,
      dlHits: d ? d.dlHits : 0,
    });
  }

  const lastDay = today;
  const td = perDay.get(today) || { pv: 0, uv: new Set(), dl: new Set(), dlHits: 0 };

  return {
    generatedAt: Date.now(),
    logFile: LOG_FILE,
    logLines: parsed,
    today: {
      day: lastDay,
      pv: td.pv,
      uv: td.uv.size,
      dl: td.dl.size,
      dlHits: td.dlHits,
    },
    totals: {
      pv: pvTotal,
      dl: days.reduce((a, d) => a + d.dl, 0),
      dlHits: dlHitsTotal,
      uv7: (() => {
        const s = new Set();
        for (const d of days.slice(-7)) {
          const x = perDay.get(d.day);
          if (x) x.uv.forEach((ip) => s.add(ip));
        }
        return s.size;
      })(),
    },
    days,
    topPages: topEntries(pageMap, 10).map((e) => ({ path: e.key, count: e.count })),
    downloads: topEntries(dlMap, 10).map((e) => ({ name: e.key, count: e.count })),
    referrers: topEntries(refMap, 8).map((e) => ({ host: e.key, count: e.count })),
    devices,
    os: topEntries(osMap, 6).map((e) => ({ name: e.key, count: e.count })),
    recent: recent.reverse(),
  };
}

function summary() {
  if (cache.data && Date.now() - cache.at < CACHE_MS) return cache.data;
  try {
    cache.data = build();
  } catch (e) {
    cache.data = { error: String(e && e.stack ? e.stack : e) };
  }
  cache.at = Date.now();
  return cache.data;
}

const PAGE = `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>小耄记账 · 访问后台</title>
<style>
  :root{
    --bg:#FFF7EA; --card:#FFFFFF; --ink:#2A2A35; --ink2:#6C6C7C; --ink3:#6E6E7D;
    --line:#F0E7D8; --brand:#FFB627; --brand-ink:#4A3103; --on-brand:#2A1E00;
    --ok:#2FC98A; --bad:#E15757;
  }
  @media (prefers-color-scheme: dark){
    :root{ --bg:#14120E; --card:#221F1A; --ink:#EDE7DC; --ink2:#B7B1A6; --ink3:#9A9386;
           --line:#3A342A; --brand:#FFB627; --brand-ink:#FFE3B0; --on-brand:#2A1E00;
           --ok:#4BD6A0; --bad:#FF7B7B; }
  }
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--ink);
       font:14px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif}
  header{position:sticky;top:0;z-index:2;display:flex;align-items:center;gap:12px;
         padding:12px 20px;background:var(--card);border-bottom:2px solid var(--ink)}
  header h1{margin:0;font-size:15px;font-weight:900;letter-spacing:.2px}
  header .meta{margin-left:auto;color:var(--ink3);font-size:12px;font-weight:600}
  button{font:inherit;font-weight:800;background:var(--brand);color:var(--on-brand);
         border:2px solid var(--ink);border-radius:10px;padding:6px 12px;cursor:pointer;box-shadow:0 2px 0 var(--ink)}
  button:active{transform:translate(1px,2px);box-shadow:0 1px 0 var(--ink)}
  main{max-width:1100px;margin:0 auto;padding:18px 20px 40px}
  .kpis{display:grid;grid-template-columns:repeat(6,1fr);gap:10px}
  @media (max-width:900px){ .kpis{grid-template-columns:repeat(3,1fr)} }
  @media (max-width:520px){ .kpis{grid-template-columns:repeat(2,1fr)} }
  .kpi{background:var(--card);border:2px solid var(--ink);border-radius:14px;padding:10px 12px}
  .kpi b{display:block;font-size:22px;font-weight:900;letter-spacing:-.5px}
  .kpi span{font-size:11.5px;font-weight:700;color:var(--ink2)}
  .kpi.hi{background:var(--brand);color:var(--brand-ink)}
  .kpi.hi span{color:var(--brand-ink);opacity:.9}
  h2{font-size:13px;font-weight:900;margin:22px 0 8px}
  .panel{background:var(--card);border:2px solid var(--ink);border-radius:14px;padding:12px 14px}
  .chart{display:flex;align-items:flex-end;gap:6px;height:150px;padding-top:6px}
  .bar{flex:1;display:flex;flex-direction:column;justify-content:flex-end;gap:2px;min-width:0}
  .bar i{display:block;background:var(--brand);border:1.5px solid var(--ink);border-radius:4px 4px 0 0;min-height:2px}
  .bar i.dl{background:var(--ok)}
  .bar em{font-style:normal;font-size:9.5px;color:var(--ink3);text-align:center;white-space:nowrap;overflow:hidden}
  .legend{display:flex;gap:14px;font-size:11.5px;color:var(--ink2);font-weight:700;margin-top:6px}
  .legend i{display:inline-block;width:10px;height:10px;border:1.5px solid var(--ink);border-radius:3px;margin-right:4px;vertical-align:-1px}
  .cols{display:grid;grid-template-columns:1fr 1fr 1fr;gap:12px}
  @media (max-width:820px){ .cols{grid-template-columns:1fr} }
  table{width:100%;border-collapse:collapse;font-size:12.5px}
  td,th{text-align:left;padding:5px 4px;border-bottom:1px dashed var(--line);font-weight:600}
  th{color:var(--ink3);font-size:11px;font-weight:800}
  td.n{text-align:right;font-variant-numeric:tabular-nums;font-weight:800}
  .chips{display:flex;flex-wrap:wrap;gap:6px;margin-top:8px}
  .chip{border:1.5px solid var(--ink);border-radius:999px;padding:2px 9px;font-size:11.5px;font-weight:700;color:var(--ink2)}
  .err{border-color:var(--bad);color:var(--bad)}
  .muted{color:var(--ink3);font-size:12px}
  code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:11.5px}
</style>
</head>
<body>
<header>
  <h1>小耄记账 · 访问后台</h1>
  <span class="meta" id="meta">读取中…</span>
  <button id="refresh" type="button">刷新</button>
</header>
<main>
  <div class="kpis" id="kpis"></div>

  <h2>最近 14 天</h2>
  <div class="panel">
    <div class="chart" id="chart"></div>
    <div class="legend"><span><i style="background:var(--brand)"></i>页面浏览 PV</span><span><i style="background:var(--ok)"></i>APK 下载</span></div>
  </div>

  <div class="cols" style="margin-top:12px">
    <div><h2>热门页面</h2><div class="panel"><table id="pages"></table></div></div>
    <div><h2>APK 下载</h2><div class="panel"><table id="dls"></table><div class="chips" id="devices"></div></div></div>
    <div><h2>来源</h2><div class="panel"><table id="refs"></table><div class="chips" id="os"></div></div></div>
  </div>

  <h2>最近请求</h2>
  <div class="panel"><table id="recent"></table></div>
  <p class="muted" id="note"></p>
</main>
<script>
(function () {
  var $ = function (id) { return document.getElementById(id); };
  var fmt = function (n) { return (n || 0).toLocaleString('zh-CN'); };

  function kpi(label, value, hi) {
    return '<div class="kpi' + (hi ? ' hi' : '') + '"><b>' + fmt(value) + '</b><span>' + label + '</span></div>';
  }

  function render(d) {
    if (d.error) {
      $('meta').textContent = '出错了';
      $('kpis').innerHTML = '<div class="kpi err" style="grid-column:1/-1"><b>!</b><span>' + d.error + '</span></div>';
      return;
    }
    $('meta').textContent = '更新于 ' + new Date(d.generatedAt).toLocaleString('zh-CN') + ' · 日志 ' + fmt(d.logLines) + ' 行';

    $('kpis').innerHTML = [
      kpi('今日 PV', d.today.pv, true),
      kpi('今日 UV', d.today.uv),
      kpi('今日下载', d.today.dl),
      kpi('近 14 天 PV', d.totals.pv),
      kpi('近 7 天 UV', d.totals.uv7),
      kpi('近 14 天下载', d.totals.dl)
    ].join('');

    var max = Math.max(1, Math.max.apply(null, d.days.map(function (x) { return Math.max(x.pv, x.dl); })));
    $('chart').innerHTML = d.days.map(function (x) {
      var h1 = Math.round(x.pv / max * 128), h2 = Math.round(x.dl / max * 128);
      return '<div class="bar" title="' + x.day + ' · PV ' + x.pv + ' / UV ' + x.uv + ' / 下载 ' + x.dl + '">'
        + '<i style="height:' + h2 + 'px"></i><i class="dl" style="height:' + h1 + 'px"></i>'
        + '<em>' + x.day.slice(5).replace('-', '/') + '</em></div>';
    }).join('');

    $('pages').innerHTML = '<tr><th>路径</th><th style="text-align:right">次数</th></tr>' +
      (d.topPages.length ? d.topPages.map(function (p) {
        return '<tr><td><code>' + p.path + '</code></td><td class="n">' + fmt(p.count) + '</td></tr>';
      }).join('') : '<tr><td colspan="2" class="muted">还没有数据</td></tr>');

    $('dls').innerHTML = '<tr><th>版本 · 架构</th><th style="text-align:right">次数</th></tr>' +
      (d.downloads.length ? d.downloads.map(function (x) {
        return '<tr><td>' + x.name + '</td><td class="n">' + fmt(x.count) + '</td></tr>';
      }).join('') : '<tr><td colspan="2" class="muted">还没有下载</td></tr>');

    var dv = d.devices;
    $('devices').innerHTML = '<span class="chip">手机 ' + fmt(dv.mobile) + '</span><span class="chip">桌面 ' + fmt(dv.desktop) + '</span>'
      + '<span class="chip">平板 ' + fmt(dv.tablet) + '</span><span class="chip">机器人 ' + fmt(dv.bot) + '</span>';

    $('refs').innerHTML = '<tr><th>来源</th><th style="text-align:right">次数</th></tr>' +
      (d.referrers.length ? d.referrers.map(function (r) {
        return '<tr><td>' + r.host + '</td><td class="n">' + fmt(r.count) + '</td></tr>';
      }).join('') : '<tr><td colspan="2" class="muted">还没有站外来源</td></tr>');

    $('os').innerHTML = d.os.map(function (o) { return '<span class="chip">' + o.name + ' ' + fmt(o.count) + '</span>'; }).join('');

    $('recent').innerHTML = '<tr><th>时间</th><th>路径</th><th>状态</th><th>IP</th></tr>' +
      (d.recent.length ? d.recent.map(function (r) {
        return '<tr><td class="muted">' + r.time + '</td><td><code>' + r.path + '</code></td><td>' + r.status + '</td><td class="muted">' + r.ip + '</td></tr>';
      }).join('') : '<tr><td colspan="4" class="muted">还没有请求</td></tr>');

    $('note').textContent = '统计口径：PV 只算页面（不含图片/CSS/JS），下载只算完整下载（206 分段续传不计）；'
      + '机器人（Bot）已从 PV/UV 中剔除，单独计数。';
  }

  function load() {
    $('meta').textContent = '读取中…';
    fetch('/api/summary', { cache: 'no-store' })
      .then(function (r) { return r.json(); })
      .then(render)
      .catch(function (e) {
        $('meta').textContent = '读取失败';
        $('kpis').innerHTML = '<div class="kpi err" style="grid-column:1/-1"><b>!</b><span>' + e + '</span></div>';
      });
  }

  $('refresh').addEventListener('click', load);
  load();
  setInterval(load, 60000);
})();
</script>
</body>
</html>
`;

const server = http.createServer((req, res) => {
  const url = req.url.split('?')[0];
  if (url === '/api/summary') {
    const body = JSON.stringify(summary());
    res.writeHead(200, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
    res.end(body);
    return;
  }
  if (url === '/healthz') {
    res.writeHead(200, { 'content-type': 'text/plain' });
    res.end('ok');
    return;
  }
  res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
  res.end(PAGE);
});

server.listen(PORT, HOST, () => {
  console.log(`[xiaomao-admin] http://${HOST}:${PORT}  log=${LOG_FILE}`);
});
