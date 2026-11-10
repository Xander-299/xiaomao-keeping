/// 导入备份时问一句：「这份备份里还带了外观与布局，要不要一起恢复？」
///
/// 为什么要有这一步：备份恢复的**主语义是「把账本搬过来」**，顺手覆盖掉本机的外观 /
/// 首页布局属于副作用。用户可能只是想把旧手机的账并进当前设备，并不想换主题。
/// 默认给「一并恢复」（换机是最常见场景），但必须让人有反悔的口子。
library;

import 'package:flutter/material.dart';

import 'package:yanxin/core/theme/toon.dart';

/// 返回 true = 一并恢复设置；false = 只恢复账本。
Future<bool> askRestoreBackupSettings(BuildContext context) async {
  final ToonPalette p = context.toon;
  final bool? ok = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 34),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              '备份里带外观与布局',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            Text(
              '这份备份里含外观模式、主题色和首页布局设置。\n'
              '一并恢复会覆盖本机当前的样子；只恢复账本则外观保持不动。',
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: p.ink2,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                ToonButton(
                  label: '只恢复账本',
                  kind: ToonButtonKind.ghost,
                  small: true,
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                ),
                const SizedBox(width: 8),
                ToonButton(
                  label: '一并恢复',
                  small: true,
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  return ok ?? true;
}
