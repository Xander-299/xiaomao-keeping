/// 首页「本月预算」——**一行条**（原来是整张卡，腾位置给「记一笔 / 问一句」入口）。
///
/// 数字来源不变：
/// - 预算金额 → [monthBudgetProvider]（当前账本 + 首页当前月份）
/// - 已消费 → 首页已加载的当月流水（`ledger.summary`），所以记账后自动跟着变
/// 口径不变：`buildBudgetView`（日均 / 剩余每日可消费都还是它算）。
///
/// 交互不变：点这一行 → 原预算编辑弹层（[showBudgetEditSheet]）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:yanxin/core/theme/tokens.dart';
import 'package:yanxin/core/theme/toon.dart';
import 'package:yanxin/core/utils/money.dart';

import '../../application/budget_controller.dart';
import '../../application/budget_metrics.dart';
import '../../application/ledger_controller.dart';
import 'budget_edit_sheet.dart';

/// 副行口径：还剩多少 / 已经花掉多少。
enum BudgetStripDetail {
  /// 「还剩 ¥X」（默认，剩余派）。
  remaining,

  /// 「已花 ¥X」（支出派）。
  spent,
}

/// 一行预算条。
///
/// [showDaily] 控制详情里是否显示「每天可花 ¥X」（首页布局参数，默认开）；
/// [detail] 控制副行是「还剩」还是「已花」（另一条布局参数）。
class BudgetStrip extends ConsumerWidget {
  const BudgetStrip({
    super.key,
    this.showDaily = true,
    this.detail = BudgetStripDetail.remaining,
  });

  final bool showDaily;
  final BudgetStripDetail detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ToonPalette p = context.toon;
    final LedgerState? ledger = ref.watch(ledgerProvider).value;
    final AsyncValue<int?> budgetAsync = ref.watch(monthBudgetProvider);
    if (ledger == null) return const SizedBox.shrink();

    final BudgetView view = buildBudgetView(
      budgetCents: budgetAsync.value,
      spentCents: ledger.summary.expenseCents,
      year: ledger.year,
      month: ledger.month,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );

    return Padding(
      // 上/下外边距都不在这里加：竖向节奏统一由 home_page 的 kHomeGap* 控制（2026-10-28）
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: ToonPress(
        dx: 2,
        dy: 2,
        onTap: () => showBudgetEditSheet(context, ref, view: view),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
          decoration: BoxDecoration(
            color: p.paper,
            borderRadius: BorderRadius.circular(Tok.rLg),
            border: p.inkBorder(),
            boxShadow: p.hard(d: 2),
          ),
          child: view.hasBudget
              ? _Filled(view: view, showDaily: showDaily, detail: detail)
              : Row(
                  children: <Widget>[
                    Icon(Icons.savings_outlined, size: 16, color: p.ink2),
                    const SizedBox(width: 8),
                    Text(
                      '设本月预算',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: p.ink2,
                      ),
                    ),
                    const Spacer(),
                    Icon(Icons.chevron_right_rounded, size: 18, color: p.ink3),
                  ],
                ),
        ),
      ),
    );
  }
}

class _Filled extends StatelessWidget {
  const _Filled({
    required this.view,
    this.showDaily = true,
    this.detail = BudgetStripDetail.remaining,
  });

  final BudgetView view;

  /// false 时不显示「每天可花」（首页布局参数）。
  final bool showDaily;

  /// 副行口径（首页布局参数）。
  final BudgetStripDetail detail;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    final double ratio = view.progress.clamp(0.0, 1.0);
    final Color barColor = view.overspent ? p.red : p.brandDeep;
    // 先拼成一句话，再交给 ToonFadeValue 判断「变了没有」
    final String dailySuffix = showDaily
        ? (view.dailyRemainingCents != null
              ? ' · 每天可花 ¥${centsToYuan(view.dailyRemainingCents!)}'
              : '')
        : '';
    // 超支时两种口径说的是同一件事（都是「超了多少」），所以仍走「已超支」。
    final String detailText = view.overspent
        ? '已超支 ¥${centsToYuan(view.overspentCents)}'
              '${view.daysLeft != null ? ' · 本月还剩 ${view.daysLeft} 天' : ''}'
        : switch (detail) {
            BudgetStripDetail.remaining =>
              '还剩 ¥${centsToYuan(view.remainingCents)}$dailySuffix',
            BudgetStripDetail.spent =>
              '已花 ¥${centsToYuan(view.spentCents)}$dailySuffix',
          };

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(Icons.savings_outlined, size: 15, color: p.ink2),
            const SizedBox(width: 6),
            Text(
              '预算 ¥${centsToYuan(view.budgetCents, group: true)}',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
            ),
            const SizedBox(width: 8),
            // 进度条
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: Stack(
                  children: <Widget>[
                    Container(height: 6, color: p.track),
                    FractionallySizedBox(
                      widthFactor: ratio,
                      child: Container(height: 6, color: barColor),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            ToonFadeValue(
              value: view.percentText,
              child: Text(
                view.percentText,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  color: view.overspent ? p.redInk : p.ink2,
                ),
              ),
            ),
            const SizedBox(width: 2),
            Icon(Icons.chevron_right_rounded, size: 18, color: p.ink3),
          ],
        ),
        const SizedBox(height: 3),
        Row(
          children: <Widget>[
            const SizedBox(width: 21),
            Expanded(
              child: ToonFadeValue(
                value: detailText,
                child: Text(
                  detailText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: view.overspent ? p.redInk : p.ink3,
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
