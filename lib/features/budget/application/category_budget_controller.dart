/// 分类级预算的数据装配（FR-BUDGET-10）。
///
/// 与总预算同一个月份来源：**watch 首页的 `ledgerProvider`**（账本 + 年月 + 当月流水），
/// 所以预算页翻月 / 换账本 / 记一笔之后，分类行会跟着变 —— 不需要各自记一份月份。
///
/// 「已花」直接用首页已加载的流水在内存里按分类聚合（当月流水本来就在手上，
/// 不再多打一次库）；口径见 `buildCategoryBudgets`。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/data/providers/category_providers.dart';
import 'package:yanxin/data/providers/database.dart';
import 'package:yanxin/features/ledger/application/budget_metrics.dart';
import 'package:yanxin/features/ledger/application/ledger_controller.dart';
import 'package:yanxin/features/stats/application/stats_controller.dart';

/// 当前月份（账本 + 年月）的**全部**预算行（总预算 + 分类预算）。
final monthBudgetsProvider = FutureProvider<List<BudgetRow>>((Ref ref) async {
  final LedgerState ledger = await ref.watch(ledgerProvider.future);
  return ref
      .read(budgetRepositoryProvider)
      .listForMonth(ledger.bookId, ledger.year, ledger.month);
});

/// 当前月份的分类预算行；没设分类预算时为空列表。
final categoryBudgetsProvider = FutureProvider<List<CategoryBudgetRow>>((
  Ref ref,
) async {
  final LedgerState ledger = await ref.watch(ledgerProvider.future);
  final List<BudgetRow> budgets = await ref.watch(monthBudgetsProvider.future);
  final Map<String, int> budgetByCategory = <String, int>{
    for (final BudgetRow b in budgets)
      if (b.categoryId != null) b.categoryId!: b.amountCents,
  };
  if (budgetByCategory.isEmpty) return const <CategoryBudgetRow>[];

  // 含归档：历史月的预算仍要能显示名字（HANDOFF 不变量 #10 的两个口径别混）
  final List<Category> categories = await ref.watch(categoriesProvider.future);
  return buildCategoryBudgets(
    categories: categories,
    budgetByCategoryId: budgetByCategory,
    spentByCategoryId: spendingByCategory(ledger.items),
  );
});

/// 当月流水 → 「分类 id → 支出（分）」。income / transfer 不计（FR-BUDGET-02）。
Map<String, int> spendingByCategory(List<TxRow> items) {
  final Map<String, int> out = <String, int>{};
  for (final TxRow tx in items) {
    if (tx.deletedAt != null || tx.type != 'expense') continue;
    final String? categoryId = tx.categoryId;
    if (categoryId == null) continue;
    out[categoryId] = (out[categoryId] ?? 0) + tx.amountCents;
  }
  return out;
}

/// 首页预算条要的那一条提示：超得最多的分类（没有超支返回 null）。
({String name, int overCents, int count})? topOverCategory(
  List<CategoryBudgetRow> rows,
) {
  final List<CategoryBudgetRow> over =
      rows.where((CategoryBudgetRow r) => r.over).toList();
  if (over.isEmpty) return null;
  over.sort(
    (CategoryBudgetRow a, CategoryBudgetRow b) =>
        b.overCents.compareTo(a.overCents),
  );
  return (
    name: over.first.name,
    overCents: over.first.overCents,
    count: over.length,
  );
}

/// 「沿用上月」等写操作（页面调用）。
final budgetActionsProvider = Provider<BudgetActions>(BudgetActions.new);

class BudgetActions {
  BudgetActions(this._ref);

  final Ref _ref;

  /// 把上一月的分类预算复制到当前月；返回复制条数（0 = 上月没有分类预算）。
  Future<int> carryFromPreviousMonth() async {
    final LedgerState ledger = await _ref.read(ledgerProvider.future);
    final DateTime prev = DateTime(ledger.year, ledger.month - 1);
    final String from = '${prev.year}-${prev.month.toString().padLeft(2, '0')}';
    final String to = '${ledger.year}-${ledger.month.toString().padLeft(2, '0')}';
    final int copied = await _ref
        .read(budgetRepositoryProvider)
        .carryCategoryBudgets(bookId: ledger.bookId, fromPeriod: from, toPeriod: to);
    _ref.invalidate(monthBudgetsProvider);
    _ref.invalidate(categoryBudgetsProvider);
    return copied;
  }
}

/// 统计页的分类预算叠加（按**统计页自己的**月份，而不是首页月份）。
///
/// 统计页只显示一个月的分类占比，所以能直接套用「该月分类预算」；
/// 一级行用「含全部子级」的已花（与预算页同口径），二级行用自身。
final statsCategoryBudgetsProvider =
    FutureProvider<Map<String, CategoryBudgetRow>>((Ref ref) async {
  final StatsState stats = await ref.watch(statsProvider.future);
  if (stats.kind != 'expense') return const <String, CategoryBudgetRow>{};
  final List<BudgetRow> budgets = await ref
      .read(budgetRepositoryProvider)
      .listForMonth(stats.bookId, stats.year, stats.month);
  final Map<String, int> budgetByCategory = <String, int>{
    for (final BudgetRow b in budgets)
      if (b.categoryId != null) b.categoryId!: b.amountCents,
  };
  if (budgetByCategory.isEmpty) return const <String, CategoryBudgetRow>{};
  final List<Category> categories = await ref.watch(categoriesProvider.future);
  final List<CategoryBudgetRow> rows = buildCategoryBudgets(
    categories: categories,
    budgetByCategoryId: budgetByCategory,
    spentByCategoryId: spendingByCategory(stats.items),
  );
  return <String, CategoryBudgetRow>{
    for (final CategoryBudgetRow r in rows) r.categoryId: r,
  };
});
