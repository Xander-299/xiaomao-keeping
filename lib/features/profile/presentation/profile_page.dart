/// 「我的」页：头像卡 + 功能条目卡 + 品牌提示卡（F7.6 P3 卡通化，对齐原型 `scrProfile`）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:yanxin/core/theme/tokens.dart';
import 'package:yanxin/core/theme/toon.dart';
import 'package:yanxin/data/providers/book_providers.dart';
import 'package:yanxin/features/export/presentation/export_sheet.dart';
import 'package:yanxin/ui_kit/app_settings_tile.dart';

/// 我的。
class ProfilePage extends ConsumerWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ToonPalette p = context.toon;
    final bookAsync = ref.watch(currentBookProvider);
    return Scaffold(
      // 原型 `pbody` 用 --surface（纯白），不是全局暖白画布
      backgroundColor: p.paper,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: <Widget>[
            _Head(bookName: bookAsync.value?.name ?? '…'),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: ToonCard(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                clip: true,
                child: Column(
                  children: <Widget>[
                    AppSettingsTile(
                      icon: Icons.tips_and_updates_outlined,
                      title: '新手引导',
                      subtitle: '没有文字的按钮、藏起来的手势，30 秒看懂',
                      onTap: () => context.push('/onboarding'),
                    ),
                    AppSettingsTile(
                      icon: Icons.label_outline_rounded,
                      title: '分类管理',
                      subtitle: '预置分类 · 支持自定义增改删',
                      dashedTop: true,
                      onTap: () => context.push('/categories'),
                    ),
                    AppSettingsTile(
                      icon: Icons.bolt_rounded,
                      title: '自动记账',
                      subtitle: '微信 / 支付宝支付通知自动入账，可一键撤销',
                      iconBg: p.greenTint,
                      iconFg: p.green,
                      dashedTop: true,
                      onTap: () => context.push('/autobook'),
                    ),
                    AppSettingsTile(
                      icon: Icons.description_outlined,
                      title: '导入账单',
                      subtitle: '微信 xlsx / 支付宝 CSV，重复导入不重复记账',
                      iconBg: p.blueTint,
                      iconFg: p.blue,
                      dashedTop: true,
                      onTap: () => context.push('/import'),
                    ),
                    AppSettingsTile(
                      icon: Icons.download_outlined,
                      title: '数据导出',
                      subtitle: '导出 csv / 备份文件',
                      iconBg: p.greenTint,
                      iconFg: p.green,
                      dashedTop: true,
                      onTap: () => showExportSheet(context, ref),
                    ),
                    AppSettingsTile(
                      icon: Icons.tune_rounded,
                      title: '设置',
                      subtitle: '外观主题：浅色 / 深色 / 跟随系统',
                      iconBg: p.purpleTint,
                      iconFg: p.purple,
                      dashedTop: true,
                      onTap: () => context.push('/settings'),
                    ),
                  ],
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: _BrandTip(),
            ),
          ],
        ),
      ),
    );
  }
}

/// 头像卡：品牌圆角方块 + 小猪吉祥物 + 用户名 / 当前账本。
class _Head extends StatelessWidget {
  const _Head({required this.bookName});

  final String bookName;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
      child: Row(
        children: <Widget>[
          Container(
            width: 62,
            height: 62,
            decoration: BoxDecoration(
              color: p.brandTint,
              borderRadius: BorderRadius.circular(Tok.rLg),
            ),
            child: Center(
              child: Icon(Icons.person_rounded, size: 32, color: p.brandInk),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  '小耄记账用户',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 4),
                Text(
                  '当前账本：$bookName · 离线存储',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: p.ink2,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 品牌提示卡（原型 `.card` + `--brand-tint`）。
class _BrandTip extends StatelessWidget {
  const _BrandTip();

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    return ToonCard(
      color: p.brandTint,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                '这一版覆盖到哪',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: p.brandInk,
                ),
              ),
              const Spacer(),
              Text(
                // 与 pubspec.yaml 的 version 对齐（0.8.8+2008）；改版本号时记得同步这里
                'v0.8.8',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: p.brandDeep,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '已覆盖：记一笔 → 按月看账 → 导入账单 → 自动记账 → 截图记账 / 问账本（首页入口）'
            ' → 统计 / 预算 / 资产 → 数据导出 → 浅色 / 深色 / 跟随系统',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: p.brandInk,
            ),
          ),
        ],
      ),
    );
  }
}
