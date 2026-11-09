/// BottomSheet 头部：抓手 + 标题 + 可选副标题。
///
/// 各业务弹层只负责正文与底部动作；抓手尺寸、标题字号、副标题样式统一在这里。
library;

import 'package:flutter/material.dart';

import '../core/theme/toon.dart';

class AppSheetHeader extends StatelessWidget {
  const AppSheetHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.subtitleGap = 6,
  });

  final String title;
  final String? subtitle;

  /// 标题与副标题之间的间距；各弹层历史值不同（4 / 6），由调用方传。
  final double subtitleGap;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    final String? sub = subtitle;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Center(
          child: Container(
            width: 46,
            height: 6,
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: p.ink,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
        ),
        Text(
          title,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
        ),
        if (sub != null) ...<Widget>[
          SizedBox(height: subtitleGap),
          Text(
            sub,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: p.ink2,
            ),
          ),
        ],
      ],
    );
  }
}
