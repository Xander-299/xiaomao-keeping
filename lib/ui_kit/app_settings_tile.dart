/// 设置 / 我的页通用条目行：图标方块 + 标题 / 副标题 + `›`。
///
/// 未接 `onTap` 时显示「建设中」并降透明度，与旧 `_Entry` 行为一致。
library;

import 'package:flutter/material.dart';

import '../core/theme/toon.dart';

class AppSettingsTile extends StatelessWidget {
  const AppSettingsTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.iconBg,
    this.iconFg,
    this.dashedTop = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  /// 图标底 / 图标色；`null` = 品牌浅底 / 品牌深色。
  final Color? iconBg;
  final Color? iconFg;

  final bool dashedTop;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    final Color bg = iconBg ?? p.brandTint;
    final Color fg = iconFg ?? p.brandDeep;
    final Widget row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 13),
      child: Row(
        children: <Widget>[
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(13),
              border: Border.all(color: p.ink, width: 2),
              boxShadow: p.hard(d: 2),
            ),
            child: Icon(icon, size: 20, color: fg),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: p.ink2,
                  ),
                ),
              ],
            ),
          ),
          if (onTap == null)
            Text(
              '建设中',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: p.ink3,
              ),
            )
          else
            Icon(Icons.chevron_right, size: 18, color: p.ink2),
        ],
      ),
    );

    final Widget body = onTap == null
        ? Opacity(opacity: 0.6, child: row)
        : ToonPress(onTap: onTap!, child: row);

    if (!dashedTop) return body;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[const ToonDashedLine(), body],
    );
  }
}
