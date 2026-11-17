/// 「预算」页（FR-BUDGET-10）：上半总预算、下半分类预算。
///
/// 为什么要有这个页面：分类预算一多就不是「一行条」能放下的了，
/// 而首页那条预算条继续只做汇总（点它进这里）。
///
/// 月份口径与首页一致：所有数字都从 `ledgerProvider`（当前账本 + 年月 + 当月流水）推导，
/// 不自己记月份 —— 首页翻月后再进来看到的就是同一个月。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/core/theme/tokens.dart';
import 'package:yanxin/core/theme/toon.dart';
import 'package:yanxin/data/providers/category_providers.dart';
import 'package:yanxin/features/budget/application/category_budget_controller.dart';
import 'package:yanxin/features/ledger/application/budget_controller.dart';
import 'package:yanxin/features/ledger/application/budget_metrics.dart';
import 'package:yanxin/features/ledger/application/ledger_controller.dart';
import 'package:yanxin/features/ledger/presentation/widgets/budget_edit_sheet.dart';
import 'package:yanxin/ui_kit/app_page_state.dart';
import 'package:yanxin/ui_kit/app_sheet_header.dart';

class BudgetPage extends ConsumerWidget {
  const BudgetPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ToonPalette p = context.toon;
    final LedgerState? ledger = ref.watch(ledgerProvider).value;
    if (ledger == null) {
      return Scaffold(
        backgroundColor: p.paper,
        appBar: AppBar(title: const Text('预算')),
        body: const AppPageLoading(),
      );
    }

    final AsyncValue<int?> budgetAsync = ref.watch(monthBudgetProvider);
    final BudgetView view = buildBudgetView(
      budgetCents: budgetAsync.value,
      spentCents: ledger.summary.expenseCents,
      year: ledger.year,
      month: ledger.month,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    final AsyncValue<List<CategoryBudgetRow>> rows = ref.watch(
      categoryBudgetsProvider,
    );

    return Scaffold(
      backgroundColor: p.paper,
      appBar: AppBar(title: Text('预算 · ${ledger.month} 月')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
        children: <Widget>[
          _TotalCard(
            view: view,
            onTap: () => showBudgetEditSheet(context, ref, view: view),
          ),
          const SizedBox(height: 18),
          Row(
            children: <Widget>[
              const Text(
                '分类预算',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '一级含子分类',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: p.ink2,
                  ),
                ),
              ),
              ToonButton(
                key: const ValueKey<String>('budgetCarry'),
                label: '沿用上月',
                kind: ToonButtonKind.ghost,
                small: true,
                onPressed: () => _carry(context, ref),
              ),
            ],
          ),
          const SizedBox(height: 10),
          rows.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: AppPageLoading(),
            ),
            error: (Object e, StackTrace _) => AppPageError(error: e),
            data: (List<CategoryBudgetRow> list) => list.isEmpty
                ? _EmptyCategoryBudget(p: p)
                : Column(
                    children: <Widget>[
                      for (final CategoryBudgetRow row in list)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _CategoryRow(
                            row: row,
                            onTap: () => showBudgetEditSheet(
                              context,
                              ref,
                              view: BudgetView(
                                hasBudget: true,
                                budgetCents: row.amountCents,
                                spentCents: row.spentCents,
                                remainingCents: row.remainingCents,
                                overspent: row.over,
                                progress: row.ratio.clamp(0, 1),
                                percentPermille: (row.ratio * 1000).round(),
                                dailyAvgCents: 0,
                                dailyRemainingCents: 0,
                                daysLeft: 0,
                              ),
                              categoryId: row.categoryId,
                              categoryName: row.name,
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: 6),
          ToonButton(
            key: const ValueKey<String>('budgetAddCategory'),
            label: '添加分类预算',
            kind: ToonButtonKind.tonal,
            block: true,
            onPressed: () => _addCategory(context, ref),
          ),
        ],
      ),
    );
  }

  Future<void> _carry(BuildContext context, WidgetRef ref) async {
    final int copied = await ref.read(budgetActionsProvider).carryFromPreviousMonth();
    if (!context.mounted) return;
    showToonFeedback(
      context,
      copied == 0 ? '上月没有分类预算可沿用' : '已沿用 $copied 项',
      kind: copied == 0 ? ToonFeedbackKind.info : ToonFeedbackKind.success,
    );
  }

  /// 选一个**未归档**的支出分类，再弹金额。
  ///
  /// 高度上限 60% 屏高：分类有 10 个一级 + 30 多个二级，不封顶会整屏盖住页面
  /// （用户 2026-11-17 反馈「几乎占满 100%」）。版式沿用 `AppSheetHeader`（抓手 + 标题）。
  Future<void> _addCategory(BuildContext context, WidgetRef ref) async {
    final List<Category> all = await ref.read(
      categoriesByKindProvider('expense').future,
    );
    if (!context.mounted) return;
    final double maxHeight = MediaQuery.sizeOf(context).height * 0.6;
    final Category? picked = await showModalBottomSheet<Category>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.toon.paper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Tok.rXl)),
      ),
      builder: (BuildContext ctx) {
        final ToonPalette p = ctx.toon;
        return ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
                child: AppSheetHeader(
                  title: '选择分类',
                  subtitle: '一级、二级都能单独设额度',
                ),
              ),
              Flexible(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  shrinkWrap: true,
                  itemCount: all.length,
                  itemBuilder: (BuildContext _, int i) {
                    final Category c = all[i];
                    final bool isChild = c.parentId != null;
                    return ListTile(
                      dense: true,
                      visualDensity: const VisualDensity(vertical: -3),
                      contentPadding: EdgeInsets.only(
                        left: isChild ? 32 : 12,
                        right: 12,
                      ),
                      title: Text(
                        c.name,
                        style: TextStyle(
                          fontSize: isChild ? 13.5 : 14.5,
                          fontWeight: isChild
                              ? FontWeight.w600
                              : FontWeight.w700,
                          color: isChild ? p.ink2 : p.ink,
                        ),
                      ),
                      trailing: Icon(
                        Icons.chevron_right_rounded,
                        size: 18,
                        color: p.ink3,
                      ),
                      onTap: () => Navigator.of(ctx).pop(c),
                    );
                  },
                ),
              ),
              const SafeArea(top: false, child: SizedBox(height: 4)),
            ],
          ),
        );
      },
    );
    if (picked == null || !context.mounted) return;
    await showBudgetEditSheet(
      context,
      ref,
      view: const BudgetView(
        hasBudget: false,
        budgetCents: 0,
        spentCents: 0,
        remainingCents: 0,
        overspent: false,
        progress: 0,
        percentPermille: 0,
        dailyAvgCents: 0,
        dailyRemainingCents: 0,
        daysLeft: 0,
      ),
      categoryId: picked.id,
      categoryName: picked.name,
    );
  }
}

class _TotalCard extends StatelessWidget {
  const _TotalCard({required this.view, required this.onTap});

  final BudgetView view;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    return ToonPress(
      dx: 2,
      dy: 2,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          color: p.paper,
          borderRadius: BorderRadius.circular(Tok.rLg),
          border: p.inkBorder(),
          boxShadow: p.hard(d: 2),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Text(
                  '本月总预算',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
                ),
                const Spacer(),
                Icon(Icons.edit_rounded, size: 15, color: p.ink3),
              ],
            ),
            const SizedBox(height: 8),
            if (!view.hasBudget)
              Text(
                '还没设总预算 · 点这里设置',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: p.ink2,
                ),
              )
            else ...<Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Text(
                    '¥${(view.spentCents / 100).toStringAsFixed(2)}',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w900,
                      color: view.overspent ? p.red : p.ink,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '/ ¥${(view.budgetCents / 100).toStringAsFixed(2)}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: p.ink2,
                      ),
                    ),
                  ),
                  const Spacer(),
                  if (view.overspent)
                    Text(
                      '已超支',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w900,
                        color: p.red,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              _Bar(ratio: view.progress, over: view.overspent),
            ],
          ],
        ),
      ),
    );
  }
}

class _CategoryRow extends StatelessWidget {
  const _CategoryRow({required this.row, required this.onTap});

  final CategoryBudgetRow row;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    return ToonPress(
      dx: 1,
      dy: 1,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        decoration: BoxDecoration(
          color: p.paper,
          borderRadius: BorderRadius.circular(Tok.rMd),
          border: p.inkBorder(),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    row.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  '¥${(row.spentCents / 100).toStringAsFixed(2)} / '
                  '¥${(row.amountCents / 100).toStringAsFixed(2)}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: row.over ? p.red : p.ink2,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            _Bar(ratio: row.ratio.clamp(0, 1), over: row.over),
            if (row.over)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '已超支 ¥${(row.overCents / 100).toStringAsFixed(2)}',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: p.red,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.ratio, required this.over});

  final double ratio;
  final bool over;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    return ClipRRect(
      borderRadius: BorderRadius.circular(Tok.rSm),
      child: Container(
        height: 7,
        color: p.track,
        child: FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: ratio.clamp(0, 1),
          child: Container(color: over ? p.red : p.brand),
        ),
      ),
    );
  }
}

class _EmptyCategoryBudget extends StatelessWidget {
  const _EmptyCategoryBudget({required this.p});

  final ToonPalette p;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 18),
    child: Text(
      '还没有分类预算。点下面「添加分类预算」，或一键沿用上月。',
      style: TextStyle(
        fontSize: 12.5,
        fontWeight: FontWeight.w600,
        color: p.ink2,
        height: 1.5,
      ),
    ),
  );
}
