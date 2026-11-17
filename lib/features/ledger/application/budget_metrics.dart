/// 预算计算（纯函数，便于单测）。
///
/// 首页预算卡要的数字全在这里算：进度百分比、剩余额度、本月日均消费、
/// 剩余每日可消费。口径与日历页保持一致（日均按「当月已过天数 / 历史月整月」），
/// 直接复用 `calendar_aggregate.dart` 里已单测过的 [dailyAverageExpenseCents]。
library;

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/core/utils/date.dart';

import '../../calendar/application/calendar_aggregate.dart';

/// 预算卡要渲染的全部数值（一次性算完，UI 只负责排版）。
class BudgetView {
  const BudgetView({
    required this.hasBudget,
    required this.budgetCents,
    required this.spentCents,
    required this.remainingCents,
    required this.overspent,
    required this.progress,
    required this.percentPermille,
    required this.dailyAvgCents,
    required this.dailyRemainingCents,
    required this.daysLeft,
  });

  /// 是否设过预算（未设置 / 预算 ≤ 0 → false）。
  final bool hasBudget;

  /// 预算金额（分）。未设置时为 0。
  final int budgetCents;

  /// 已消费（分，该月 expense 合计）。
  final int spentCents;

  /// 剩余额度（分，可为负；未设置时为 0）。
  final int remainingCents;

  /// 是否已超支。
  final bool overspent;

  /// 环形进度 0.0–1.0（只用于绘制，真实占比见 [percentPermille]）。
  final double progress;

  /// 真实占比的千分比（可 > 1000，即超支）。
  final int percentPermille;

  /// 本月日均消费（分）。
  final int dailyAvgCents;

  /// 剩余每日可消费（分）；不适用时为 null（未设预算 / 已结束的月份）。
  final int? dailyRemainingCents;

  /// 剩余天数（含今天）；不适用时为 null。
  final int? daysLeft;

  /// 展示用占比：`10.2%` / `128.5%`。
  String get percentText => '${(percentPermille / 10).toStringAsFixed(1)}%';

  /// 超支金额（分，恒 >= 0）。
  int get overspentCents => overspent ? spentCents - budgetCents : 0;
}

/// 组装预算卡视图。
///
/// [budgetCents] 为 null 或 ≤ 0 视为「未设置预算」；此时进度与剩余额度均为 0，
/// 但「本月日均消费」照常计算（没预算也该能看到自己每天花多少）。
BudgetView buildBudgetView({
  required int? budgetCents,
  required int spentCents,
  required int year,
  required int month,
  required int nowMs,
}) {
  final hasBudget = budgetCents != null && budgetCents > 0;
  final budget = hasBudget ? budgetCents : 0;
  final spent = spentCents > 0 ? spentCents : 0;

  final remaining = hasBudget ? budget - spent : 0;
  final overspent = hasBudget && spent > budget;

  var permille = 0;
  var progress = 0.0;
  if (hasBudget) {
    // 四舍五入到千分之一（即展示的一位小数百分比），全程整数运算。
    permille = (spent * 1000 + budget ~/ 2) ~/ budget;
    progress = spent / budget;
    if (progress > 1) progress = 1;
    if (progress < 0) progress = 0;
  }

  final now = DateTime.fromMillisecondsSinceEpoch(nowMs);
  final isCurrentMonth = year == now.year && month == now.month;
  final isFutureMonth = year * 12 + month > now.year * 12 + now.month;

  int? daysLeft;
  int? dailyRemaining;
  if (hasBudget) {
    if (isCurrentMonth) {
      daysLeft = daysInMonth(year, month) - now.day + 1;
    } else if (isFutureMonth) {
      // 未来月：整月都还没开始，按整月天数摊。
      daysLeft = daysInMonth(year, month);
    }
    // 历史月：月已结束，「剩余每日可消费」没有意义 → 保持 null（界面显示「—」）。
    if (daysLeft != null && daysLeft > 0) {
      dailyRemaining =
          remaining <= 0 ? 0 : (remaining + daysLeft ~/ 2) ~/ daysLeft;
    }
  }

  return BudgetView(
    hasBudget: hasBudget,
    budgetCents: budget,
    spentCents: spent,
    remainingCents: remaining,
    overspent: overspent,
    progress: progress,
    percentPermille: permille,
    dailyAvgCents: dailyAverageExpenseCents(
      expenseCents: spent,
      year: year,
      month: month,
      nowMs: nowMs,
    ),
    dailyRemainingCents: dailyRemaining,
    daysLeft: daysLeft,
  );
}

// ── 分类级预算（FR-BUDGET-10）──────────────────────────────────────────

/// 分类预算的一行（纯数据，UI 只排版）。
class CategoryBudgetRow {
  const CategoryBudgetRow({
    required this.categoryId,
    required this.name,
    required this.amountCents,
    required this.spentCents,
    this.hasChildren = false,
  });

  final String categoryId;

  /// 展示名：一级「餐饮」，二级「餐饮 · 早餐」。
  final String name;

  /// 额度（分，恒为正）。
  final int amountCents;

  /// 已花（分）：一级 = 自身 + **全部子级**（Q7，允许与子级行重叠计数）。
  final int spentCents;

  /// 是否有一级子分类（用于文案「含子分类」）。
  final bool hasChildren;

  int get remainingCents => amountCents - spentCents;

  bool get over => spentCents > amountCents;

  int get overCents => over ? spentCents - amountCents : 0;

  /// 进度（0..∞，UI 自己 clamp 画条）。
  double get ratio => amountCents <= 0 ? 0 : spentCents / amountCents;
}

/// 把「分类树 + 本月预算 + 本月按分类的支出」算成分类预算行。
///
/// 口径（与 SPEC-F7.3b D3 一致）：
/// - 只收**支出类**分类；只输出**设了预算**的分类（没设的不占位）；
/// - 一级的已花 = 直接记在一级上的支出 + 其全部子级的支出（**含子级会重复计数**）；
/// - 二级的已花 = 该二级自己的支出；
/// - 排序跟随分类树：一级在前，其子级紧随其后（入参顺序即树顺序）。
///
/// 归档分类也要传进来（历史月仍要显示名字），是否进「可编辑列表」由调用方决定。
List<CategoryBudgetRow> buildCategoryBudgets({
  required List<Category> categories,
  required Map<String, int> budgetByCategoryId,
  required Map<String, int> spentByCategoryId,
}) {
  if (budgetByCategoryId.isEmpty) return const <CategoryBudgetRow>[];

  final Map<String, Category> byId = <String, Category>{
    for (final Category c in categories) c.id: c,
  };
  final Map<String, List<Category>> childrenOf = <String, List<Category>>{};
  for (final Category c in categories) {
    final String? parent = c.parentId;
    if (parent == null) continue;
    childrenOf.putIfAbsent(parent, () => <Category>[]).add(c);
  }

  int spentOf(String id) {
    int total = spentByCategoryId[id] ?? 0;
    for (final Category child in childrenOf[id] ?? const <Category>[]) {
      total += spentByCategoryId[child.id] ?? 0;
    }
    return total;
  }

  final List<CategoryBudgetRow> rows = <CategoryBudgetRow>[];
  for (final Category parent in categories) {
    if (parent.parentId != null || parent.kind != 'expense') continue;
    final int? parentBudget = budgetByCategoryId[parent.id];
    if (parentBudget != null) {
      rows.add(
        CategoryBudgetRow(
          categoryId: parent.id,
          name: parent.name,
          amountCents: parentBudget,
          spentCents: spentOf(parent.id),
          hasChildren: (childrenOf[parent.id] ?? const <Category>[]).isNotEmpty,
        ),
      );
    }
    for (final Category child in childrenOf[parent.id] ?? const <Category>[]) {
      final int? childBudget = budgetByCategoryId[child.id];
      if (childBudget == null) continue;
      rows.add(
        CategoryBudgetRow(
          categoryId: child.id,
          name: '${parent.name} · ${child.name}',
          amountCents: childBudget,
          spentCents: spentByCategoryId[child.id] ?? 0,
        ),
      );
    }
  }

  // 兜底：父级已归档/找不到但在预算表里还有行的分类（历史数据），仍要能显示。
  for (final MapEntry<String, int> e in budgetByCategoryId.entries) {
    if (rows.any((CategoryBudgetRow r) => r.categoryId == e.key)) continue;
    final Category? c = byId[e.key];
    // 收入类不参与预算（与主循环同口径；否则「工资」这种预算行会漏进来）
    if (c == null || c.kind != 'expense') continue;
    rows.add(
      CategoryBudgetRow(
        categoryId: c.id,
        name: c.name,
        amountCents: e.value,
        spentCents: spentOf(c.id),
      ),
    );
  }
  return rows;
}
