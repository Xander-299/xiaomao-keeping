#!/usr/bin/env node
/**
 * 截图多规格生成：<name>.jpg(540) / <name>-270.jpg / <name>.webp / <name>-270.webp
 *
 * 输入是 docs/shots 里现成的 540 宽 JPEG；用它生成 270 宽变体与 WebP 版本，
 * 页面用 <picture> + srcset 让浏览器自己挑（小屏取 270w，现代浏览器取 WebP）。
 *
 * 用法：node tool/gen_shots.js [--check]
 *   --check 只校验不写盘（CI/构建时用，缺文件或尺寸不对就非 0 退出）
 */
'use strict';
const fs = require('fs');
const path = require('path');

let sharp = null;
try { sharp = require(path.join(__dirname, '..', 'build/tmp/imgtool/node_modules/sharp')); }
catch (_) { try { sharp = require('sharp'); } catch (_) {} }

const DIR = path.join(__dirname, '..', 'docs', 'shots');
const CHECK = process.argv.includes('--check');
const FULL = 540, SMALL = 270;

function variants(name) {
  const base = name.replace(/\.jpg$/, '');
  return {
    smallJpg: `${base}-${SMALL}.jpg`,
    webp: `${base}.webp`,
    smallWebp: `${base}-${SMALL}.webp`,
  };
}

(async () => {
  const files = fs.readdirSync(DIR).filter((f) => f.endsWith('.jpg') && !f.includes('-270'));
  let made = 0, bad = [];

  for (const f of files) {
    const src = path.join(DIR, f);
    const meta = await sharp(src).metadata();
    if (meta.width !== FULL) bad.push(`${f}: 宽度 ${meta.width}，应为 ${FULL}`);
    const v = variants(f);
    const todo = [
      [v.smallJpg, { width: SMALL }],
      [v.webp, { width: FULL, webp: true }],
      [v.smallWebp, { width: SMALL, webp: true }],
    ];
    for (const [out, opt] of todo) {
      const dest = path.join(DIR, out);
      if (CHECK) {
        if (!fs.existsSync(dest)) bad.push(`缺少 ${out}`);
        continue;
      }
      let img = sharp(src).resize({ width: opt.width, withoutEnlargement: true });
      img = opt.webp ? img.webp({ quality: 80, effort: 5 }) : img.jpeg({ quality: 82, mozjpeg: true });
      await img.toFile(dest);
      made++;
    }
  }

  if (CHECK) {
    if (bad.length) {
      console.error('✗ 截图规格检查失败：\n  ' + bad.join('\n  '));
      process.exit(1);
    }
    console.log(`✓ 截图规格 OK（${files.length} 张 × 4 规格）`);
  } else {
    console.log(`已生成 ${made} 个文件（${files.length} 张源图）`);
    if (bad.length) console.warn('注意：\n  ' + bad.join('\n  '));
  }
})().catch((e) => { console.error(e); process.exit(1); });
