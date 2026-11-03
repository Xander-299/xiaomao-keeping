/// 首页顶部「已自动记账 N 笔」提示条（F7.15 SPEC §3.6）。
///
/// 位置：`MonthHero` **上方**；没有待提示批次时**完全不占位**（返回零高度，
/// 不用 `Visibility` 之类留白 —— 首页首屏很挤）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:yanxin/core/theme/toon.dart';
import 'package:yanxin/core/utils/money.dart';
import 'package:yanxin/features/autobook/application/auto_book_notice.dart';
import 'package:yanxin/features/autobook/data/auto_book_batches.dart';
import 'package:yanxin/features/ledger/application/ledger_controller.dart';

class AutoBookBanner extends ConsumerWidget {
  const AutoBookBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ToonPalette p = context.toon;
    final AutoBookBatch? batch = ref.watch(autoBookNoticeProvider);
    if (batch == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: ToonCard(
        color: p.greenTint,
        padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
        child: Row(
          children: <Widget>[
            Icon(Icons.bolt_rounded, size: 24, color: p.green),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '已自动记账 ${batch.count} 笔',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    '合计 ¥${centsToYuan(batch.totalCents)} · 可撤销',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: p.ink2,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            ToonButton(
              small: true,
              kind: ToonButtonKind.tonal,
              label: '查看',
              onPressed: () => _jumpToBatchMonth(ref, batch),
            ),
            const SizedBox(width: 2),
            ToonPress(
              dx: 0,
              dy: 0,
              onTap: () => _undo(context, ref, batch),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Icon(Icons.close_rounded, size: 18, color: p.ink2),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 「查看」→ 跳到本批所在月份（批次时间 = 这批通知的入账时刻，语义上就是「刚刚」）。
  void _jumpToBatchMonth(WidgetRef ref, AutoBookBatch batch) {
    final DateTime at = DateTime.fromMillisecondsSinceEpoch(batch.atMs);
    ref.read(ledgerProvider.notifier).jumpToMonth(at.year, at.month);
    ref.read(autoBookNoticeProvider.notifier).dismiss();
  }

  Future<void> _undo(
    BuildContext context,
    WidgetRef ref,
    AutoBookBatch batch,
  ) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final ToonPalette palette = context.toon;
    final bool ok = await _confirm(context, batch.count);
    if (!ok) return;
    final int deleted;
    try {
      deleted = await ref
          .read(autoBookNoticeProvider.notifier)
          .undo(batch.batchId);
    } catch (_) {
      showToonErrorOnMessenger(
        messenger: messenger,
        palette: palette,
        message: '撤销失败，已保留这一批，请重试',
      );
      return;
    }
    showToonFeedbackOnMessenger(
      messenger: messenger,
      palette: palette,
      message: deleted > 0 ? '已撤销 $deleted 笔自动记账' : '这批已撤销或不复存在',
      kind: deleted > 0 ? ToonFeedbackKind.success : ToonFeedbackKind.info,
    );
  }

  Future<bool> _confirm(BuildContext context, int count) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text('撤销这 $count 笔？'),
        content: const Text('会自动删除这一批自动记账的流水，不影响你手工记的账。'),
        actions: <Widget>[
          ToonButton(
            small: true,
            kind: ToonButtonKind.ghost,
            label: '算了',
            onPressed: () => Navigator.of(ctx).pop(false),
          ),
          ToonButton(
            small: true,
            kind: ToonButtonKind.danger,
            label: '撤销',
            onPressed: () => Navigator.of(ctx).pop(true),
          ),
        ],
      ),
    );
    return ok ?? false;
  }
}
