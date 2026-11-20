/// 意图 + 真实数据 → 一条中文回答（**纯函数**）。
///
/// 这个文件是 M1 的"嘴"：所有数字都从既有口径函数里来
/// （`summarize` / `categoryBreakdown` / `buildBudgetView`），
/// 这里只做三件事：选口径、排事实、写成中文。
///
/// 三条硬规矩（`Prompt.md` §3「财务数据计算原则」）：
/// 1. **不许算新的数**：金额只做比较与占比，且占比用整数千分比算；
/// 2. **必须说出实际区间**：问「最近一个月」时回答里要写清是哪 30 天；
/// 3. **没数据就说没数据**：不补零、不猜、不说"应该"。
library;

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/core/utils/money.dart';

import '../../ledger/application/budget_metrics.dart';
import '../../ledger/application/month_summary.dart';
import '../../stats/application/stats_aggregate.dart';
import 'finance_intent.dart';

/// 一条回答里的「事实」：左标签、右数值，可选一句小注。
class AnswerFact {
  const AnswerFact(this.label, this.value, {this.note});

  final String label;
  final String value;
  final String? note;
}

/// 回答的语气（只影响 UI 配色，不影响文案口径）。
enum AnswerTone { neutral, good, warn }

/// 一条回答。
class FinanceAnswer {
  const FinanceAnswer({
    required this.title,
    required this.narrative,
    this.headline,
    this.headlineNote,
    this.facts = const <AnswerFact>[],
    this.suggestions = const <String>[],
    this.tone = AnswerTone.neutral,
  });

  /// 卡片标题（含区间，例：`2026年10月 · 支出`）。
  final String title;

  /// 主数字（大字），没有就只显示 [narrative]。
  final String? headline;

  /// 主数字下面那行小注。
  final String? headlineNote;

  final List<AnswerFact> facts;

  /// 结论文本。**所有金额都来自入参数据**。
  final String narrative;

  /// 追问建议（点了就继续问）。
  final List<String> suggestions;

  final AnswerTone tone;
}

/// 查询所需的数据快照（由 controller 从仓储取好后交进来）。
class FinanceData {
  const FinanceData({
    this.rows = const <TxRow>[],
    this.categoryNames = const <String, String>{},
    this.categoryParents = const <String, String>{},
    this.budgetCents,
    required this.nowMs,
  });

  /// 覆盖所有相关区间（对比时是两个区间）的流水，未删。
  final List<TxRow> rows;

  /// 分类 id → 名称。
  final Map<String, String> categoryNames;

  /// 二级分类 id → 父分类 id（一级分类不出现在这里）。
  ///
  /// 用来把二级账单计入父级：问「餐饮」时，记在「早餐 / 午餐」上的钱也要算进来
  /// （PRD FR-CAT-03「二级计入父分类统计」）。
  final Map<String, String> categoryParents;

  /// 该月预算（分）；null = 没设。
  final int? budgetCents;

  final int nowMs;
}

/// 首页那 5 个「示例问题」—— 也是 UnknownIntent 的兜底引导。
///
/// 每一条都必须是 M1 真能答的（有测试兜着，`assistant_page_test` 会逐条问一遍）。
const List<String> kExampleQuestions = <String>[
  '这个月花了多少',
  '这个月餐饮花了多少',
  '本月预算还剩多少',
  '这个月为什么比上个月多',
  '最近有哪些大额支出',
];

String _yuan(int cents) => '¥${centsToYuan(cents, group: true)}';

/// 占比文本（整数千分比 → 一位小数），避免浮点误差。
String _ratioText(int part, int total) {
  if (total <= 0) return '—';
  final int permille = (part * 1000 + total ~/ 2) ~/ total;
  return '${(permille / 10).toStringAsFixed(1)}%';
}

String _monthDay(int ms) {
  final DateTime d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${d.month}月${d.day}日';
}

/// 挑几笔"值得追问"的建议（按意图给，别每次都是同一套）。
List<String> _defaultSuggestions(FinanceIntent intent) => switch (intent) {
  MonthSummaryIntent() => const <String>[
    '这个月餐饮花了多少',
    '本月预算还剩多少',
    '这个月为什么比上个月多',
  ],
  CategorySpendingIntent(:final String categoryName) => <String>[
    '$categoryName 最近三个月花了多少',
    '这个月花了多少',
  ],
  BudgetIntent() => const <String>['这个月花了多少', '这个月为什么比上个月多'],
  CompareIntent() => const <String>['这个月花了多少', '最近有哪些大额支出'],
  TopExpensesIntent() => const <String>['这个月餐饮花了多少', '这个月花了多少'],
  MerchantSpendingIntent() => const <String>['这个月花了多少', '最近有哪些大额支出'],
  SavingsGoalIntent() => const <String>['这个月花了多少', '本月预算还剩多少'],
  UnknownIntent() => kExampleQuestions,
};

/// 主入口：按意图生成回答。
FinanceAnswer buildFinanceAnswer(FinanceIntent intent, FinanceData data) {
  return switch (intent) {
    MonthSummaryIntent() => _monthSummary(intent, data),
    CategorySpendingIntent() => _categorySpending(intent, data),
    BudgetIntent() => _budget(intent, data),
    CompareIntent() => _compare(intent, data),
    TopExpensesIntent() => _topExpenses(intent, data),
    MerchantSpendingIntent() => _merchant(intent, data),
    SavingsGoalIntent() => _savings(intent, data),
    UnknownIntent() => _unknown(intent),
  };
}

// ────────────────────────────── 汇总 ──────────────────────────────

FinanceAnswer _monthSummary(MonthSummaryIntent intent, FinanceData data) {
  final List<TxRow> rows = _rowsIn(data.rows, intent.period);
  final MonthSummary s = summarize(rows);
  final String period = intent.period.label;
  final int expenseCount = rows.where((TxRow t) => t.type == 'expense').length;
  final int incomeCount = rows.where((TxRow t) => t.type == 'income').length;

  if (rows.isEmpty) {
    return FinanceAnswer(
      title: '$period · 收支',
      narrative: '$period还没有记账记录。',
      tone: AnswerTone.warn,
      suggestions: _defaultSuggestions(intent),
    );
  }

  final List<CategorySlice> expenseSlices = categoryBreakdown(
    rows,
    type: 'expense',
    nameOf: (String? id) => data.categoryNames[id] ?? '未分类',
  );

  final int headline = intent.kind == 'income' ? s.incomeCents : s.expenseCents;

  // 收入 / 支出 / 结余**三个都给**：同一批流水算三遍不值当省，
  // 只给一个反而让用户得再问一次（口径之间本来就要互相印证）。
  final List<AnswerFact> facts = <AnswerFact>[
    AnswerFact('支出', _yuan(s.expenseCents), note: '$expenseCount 笔'),
    AnswerFact('收入', _yuan(s.incomeCents), note: '$incomeCount 笔'),
    AnswerFact(
      '结余',
      _yuan(s.balanceCents),
      note: s.balanceCents >= 0 ? '有结余' : '入不敷出',
    ),
  ];

  final StringBuffer narrative = StringBuffer();
  if (intent.kind == 'income') {
    narrative.write('$period收入 ${_yuan(s.incomeCents)}');
    narrative.write(
      '，支出 ${_yuan(s.expenseCents)}，结余 ${_yuan(s.balanceCents)}。',
    );
  } else {
    narrative.write('$period支出 ${_yuan(s.expenseCents)}');
    narrative.write('，收入 ${_yuan(s.incomeCents)}，结余 ${_yuan(s.balanceCents)}。');
  }
  if (expenseSlices.isNotEmpty) {
    final CategorySlice top = expenseSlices.first;
    narrative.write(
      '花得最多的是「${top.name}」${_yuan(top.cents)}，占 ${_ratioText(top.cents, s.expenseCents)}',
    );
    if (expenseSlices.length > 1) {
      final CategorySlice second = expenseSlices[1];
      narrative.write('；其次是「${second.name}」${_yuan(second.cents)}');
    }
    narrative.write('。');
  }

  return FinanceAnswer(
    title: '$period · ${intent.kind == 'income' ? '收入' : '支出'}',
    headline: _yuan(headline),
    headlineNote: expenseSlices.isEmpty
        ? null
        : '支出共 ${s.expenseCents == 0 ? 0 : expenseCount} 笔 · 最大分类「${expenseSlices.first.name}」',
    facts: facts,
    narrative: narrative.toString(),
    tone: s.expenseCents > 0 && s.balanceCents < 0
        ? AnswerTone.warn
        : AnswerTone.neutral,
    suggestions: _defaultSuggestions(intent),
  );
}

// ────────────────────────────── 分类 ──────────────────────────────

FinanceAnswer _categorySpending(
  CategorySpendingIntent intent,
  FinanceData data,
) {
  final String period = intent.period.label;
  final String name = intent.categoryName;
  final bool isIncome = intent.kind == 'income';
  final String kindWord = isIncome ? '收入' : '支出';

  final List<TxRow> periodRows = _rowsIn(data.rows, intent.period);
  final List<CategorySlice> slices = categoryBreakdown(
    periodRows,
    type: intent.kind,
    nameOf: (String? id) => data.categoryNames[id] ?? '未分类',
  );
  final int total = slices.fold<int>(
    0,
    (int acc, CategorySlice s) => acc + s.cents,
  );

  // 二级账单要计入父级（PRD FR-CAT-03）：问「餐饮」时，记在「早餐 / 午餐」上的钱也算进来。
  // 判据是「自己命中」或「父级命中」—— 问「早餐」只算早餐，不会把整个餐饮都算上。
  // （2026-10-29 预置加二级后暴露：原来按分类名精确匹配，问「餐饮」永远漏掉子分类。）
  int hitCents = 0;
  int count = 0;
  for (final TxRow t in periodRows) {
    if (t.type != intent.kind || t.categoryId == null) continue;
    final String? own = data.categoryNames[t.categoryId];
    final String? parent =
        data.categoryNames[data.categoryParents[t.categoryId]];
    if (own != name && parent != name) continue;
    hitCents += t.amountCents;
    count++;
  }

  if (count == 0) {
    return FinanceAnswer(
      title: '$period · $name',
      narrative: '$period没有「$name」的$kindWord记录。',
      tone: AnswerTone.warn,
      facts: <AnswerFact>[
        if (total > 0) AnswerFact('该期$kindWord合计', _yuan(total)),
      ],
      suggestions: _defaultSuggestions(intent),
    );
  }

  return FinanceAnswer(
    title: '$period · $name',
    headline: _yuan(hitCents),
    headlineNote: '占该期$kindWord ${_ratioText(hitCents, total)}',
    facts: <AnswerFact>[
      AnswerFact('$name$kindWord', _yuan(hitCents), note: '$count 笔'),
      AnswerFact('该期$kindWord合计', _yuan(total)),
      AnswerFact('占比', _ratioText(hitCents, total)),
    ],
    narrative:
        '$period「$name」$kindWord ${_yuan(hitCents)}，共 $count 笔，'
        '占该期全部$kindWord的 ${_ratioText(hitCents, total)}。',
    suggestions: _defaultSuggestions(intent),
  );
}

// ────────────────────────────── 预算 ──────────────────────────────

FinanceAnswer _budget(BudgetIntent intent, FinanceData data) {
  final Period period = intent.period;
  final String label = period.label;
  final int spent = summarize(_rowsIn(data.rows, period)).expenseCents;
  final int? budget = data.budgetCents;

  if (budget == null || budget <= 0) {
    return FinanceAnswer(
      title: '$label · 预算',
      narrative:
          '$label还没设预算（首页「本月预算」卡片可以设）。'
          '${spent > 0 ? '目前已经花了 ${_yuan(spent)}。' : ''}',
      tone: AnswerTone.warn,
      facts: <AnswerFact>[AnswerFact('已花', _yuan(spent))],
      suggestions: _defaultSuggestions(intent),
    );
  }

  final BudgetView view = buildBudgetView(
    budgetCents: budget,
    spentCents: spent,
    year: period.year ?? DateTime.fromMillisecondsSinceEpoch(data.nowMs).year,
    month:
        period.month ?? DateTime.fromMillisecondsSinceEpoch(data.nowMs).month,
    nowMs: data.nowMs,
  );

  final List<AnswerFact> facts = <AnswerFact>[
    AnswerFact('预算', _yuan(view.budgetCents)),
    AnswerFact('已花', _yuan(view.spentCents), note: view.percentText),
    if (view.overspent)
      AnswerFact(
        '超支',
        _yuan(view.overspentCents),
        note: '超出 ${view.percentText}',
      )
    else
      AnswerFact('剩余', _yuan(view.remainingCents)),
    AnswerFact('本月日均', _yuan(view.dailyAvgCents)),
    if (view.dailyRemainingCents != null)
      AnswerFact('剩余 ${view.daysLeft} 天每日可花', _yuan(view.dailyRemainingCents!)),
  ];

  final StringBuffer narrative = StringBuffer();
  if (view.overspent) {
    narrative.write(
      '$label已经超支 ${_yuan(view.overspentCents)}'
      '（预算 ${_yuan(view.budgetCents)}，已花 ${_yuan(view.spentCents)}，'
      '用了 ${view.percentText}）。',
    );
    if (view.daysLeft != null) {
      narrative.write('这个月还剩 ${view.daysLeft} 天，接下来不要再花才能不扩大超支。');
    }
  } else {
    narrative.write(
      '$label预算 ${_yuan(view.budgetCents)}，已花 ${_yuan(view.spentCents)}，'
      '还剩 ${_yuan(view.remainingCents)}（用了 ${view.percentText}）。',
    );
    if (view.dailyRemainingCents != null) {
      narrative.write(
        '剩下 ${view.daysLeft} 天，每天还能花 ${_yuan(view.dailyRemainingCents!)}。',
      );
    }
  }

  return FinanceAnswer(
    title: '$label · 预算',
    headline: view.overspent
        ? _yuan(view.overspentCents)
        : _yuan(view.remainingCents),
    headlineNote: view.overspent
        ? '超支 · 已花 ${_yuan(view.spentCents)} / 预算 ${_yuan(view.budgetCents)}'
        : '剩余 · 已花 ${_yuan(view.spentCents)} / 预算 ${_yuan(view.budgetCents)}',
    facts: facts,
    narrative: narrative.toString(),
    tone: view.overspent ? AnswerTone.warn : AnswerTone.good,
    suggestions: _defaultSuggestions(intent),
  );
}

// ────────────────────────────── 对比 ──────────────────────────────

List<TxRow> _rowsIn(List<TxRow> rows, Period p) => <TxRow>[
  for (final TxRow t in rows)
    if (t.occurredAt >= p.startMs && t.occurredAt < p.endMs) t,
];

/// 一批流水覆盖的「天数」：首末交易日的日历日跨度（含首末）；没有数据返回 0。
///
/// 用途：判断「拿不完整的一期去比完整的一期」——比如账单只导出了 29 天，
/// 上月只有 3 天有记录，这时直接比总额会把差距放大几十倍。
int _spanDaysOf(List<TxRow> rows) {
  if (rows.isEmpty) return 0;
  int min = rows.first.occurredAt;
  int max = rows.first.occurredAt;
  for (final TxRow t in rows) {
    if (t.occurredAt < min) min = t.occurredAt;
    if (t.occurredAt > max) max = t.occurredAt;
  }
  final DateTime a = DateTime.fromMillisecondsSinceEpoch(min);
  final DateTime b = DateTime.fromMillisecondsSinceEpoch(max);
  final int days =
      DateTime(
        b.year,
        b.month,
        b.day,
      ).difference(DateTime(a.year, a.month, a.day)).inDays +
      1;
  return days < 1 ? 1 : days;
}

FinanceAnswer _compare(CompareIntent intent, FinanceData data) {
  final List<TxRow> curRows = _rowsIn(data.rows, intent.current);
  final List<TxRow> prevRows = _rowsIn(data.rows, intent.previous);
  final int cur = summarize(curRows).expenseCents;
  final int prev = summarize(prevRows).expenseCents;
  final String curLabel = intent.current.label;
  final String prevLabel = intent.previous.label;

  if (prevRows.isEmpty) {
    return FinanceAnswer(
      title: '$curLabel vs $prevLabel',
      narrative: '$prevLabel没有支出记录，没法比较（$curLabel支出 ${_yuan(cur)}）。',
      tone: AnswerTone.warn,
      facts: <AnswerFact>[
        AnswerFact(curLabel, _yuan(cur)),
        AnswerFact(prevLabel, '无记录'),
      ],
      suggestions: _defaultSuggestions(intent),
    );
  }

  final int delta = cur - prev;
  final String arrow = delta > 0 ? '多' : (delta < 0 ? '少' : '持平');
  final String pct = prev == 0
      ? '—'
      : '${delta >= 0 ? '+' : ''}${_ratioText(delta.abs(), prev)}';

  // 分类变化（只比较支出）
  Map<String, int> byCategory(List<TxRow> rows) {
    final Map<String, int> map = <String, int>{};
    for (final TxRow t in rows) {
      if (t.type != 'expense') continue;
      final String name = data.categoryNames[t.categoryId] ?? '未分类';
      map[name] = (map[name] ?? 0) + t.amountCents;
    }
    return map;
  }

  final Map<String, int> curCat = byCategory(curRows);
  final Map<String, int> prevCat = byCategory(prevRows);
  final Set<String> names = <String>{...curCat.keys, ...prevCat.keys};
  final List<({String name, int delta})> deltas =
      <({String name, int delta})>[
        for (final String n in names)
          (name: n, delta: (curCat[n] ?? 0) - (prevCat[n] ?? 0)),
      ]..sort(
        (({String name, int delta}) a, ({String name, int delta}) b) =>
            b.delta.compareTo(a.delta),
      );

  final List<({String name, int delta})> ups = deltas
      .where((({String name, int delta}) d) => d.delta > 0)
      .take(3)
      .toList();
  final List<({String name, int delta})> downs = deltas
      .where((({String name, int delta}) d) => d.delta < 0)
      .take(2)
      .toList();

  // 「不完整区间 vs 完整区间」必须点破，否则就是误导（Prompt §3 明确要求）。
  // 判据用**数据本身的跨度**，不猜日历：两边「有记录的天数」差一倍以上就算不平衡
  // （实测场景：微信账单只导出了 8/29–9/29，8 月只有 3 天有记录 → 直接比总额会放大 30 倍）。
  final int curSpan = _spanDaysOf(curRows);
  final int prevSpan = _spanDaysOf(prevRows);
  final bool unbalanced =
      curSpan > 0 &&
      prevSpan > 0 &&
      (curSpan * 10 < prevSpan * 6 || prevSpan * 10 < curSpan * 6);
  final int curDaily = curSpan > 0 ? (cur + curSpan ~/ 2) ~/ curSpan : 0;
  final int prevDaily = prevSpan > 0 ? (prev + prevSpan ~/ 2) ~/ prevSpan : 0;

  final StringBuffer narrative = StringBuffer();
  narrative.write('$curLabel支出 ${_yuan(cur)}，$prevLabel支出 ${_yuan(prev)}，');
  narrative.write(delta == 0 ? '两期持平。' : '$arrow ${_yuan(delta.abs())}（$pct）。');
  if (ups.isNotEmpty) {
    narrative.write('涨得最多的是');
    narrative.write(
      ups
          .map(
            (({String name, int delta}) d) => '「${d.name}」+${_yuan(d.delta)}',
          )
          .join('、'),
    );
    narrative.write('。');
  }
  if (intent.categoryFocus && downs.isNotEmpty) {
    narrative.write('同时');
    narrative.write(
      downs
          .map((({String name, int delta}) d) => '「${d.name}」${_yuan(d.delta)}')
          .join('、'),
    );
    narrative.write(' 有所下降。');
  }
  if (unbalanced) {
    narrative.write(
      '注意：$prevLabel 只有 $prevSpan 天有记录、$curLabel 有 $curSpan 天，'
      '直接比总额会放大差距；按每天算分别是 ${_yuan(prevDaily)} 和 ${_yuan(curDaily)}。',
    );
  }

  return FinanceAnswer(
    title: '$curLabel vs $prevLabel',
    headline: delta == 0
        ? _yuan(0)
        : '${delta > 0 ? '+' : '-'}${_yuan(delta.abs())}',
    headlineNote: delta == 0 ? '两期支出持平' : '$arrow花 · $pct',
    facts: <AnswerFact>[
      AnswerFact(curLabel, _yuan(cur)),
      AnswerFact(prevLabel, _yuan(prev)),
      AnswerFact(
        '差额',
        delta == 0 ? '¥0.00' : '${delta > 0 ? '+' : '-'}${_yuan(delta.abs())}',
        note: pct,
      ),
      if (unbalanced)
        AnswerFact('日均（$curSpan 天）', _yuan(curDaily), note: curLabel),
      if (unbalanced)
        AnswerFact('日均（$prevSpan 天）', _yuan(prevDaily), note: prevLabel),
      if (ups.isNotEmpty)
        AnswerFact('涨最多', '${ups.first.name} +${_yuan(ups.first.delta)}'),
      if (downs.isNotEmpty)
        AnswerFact('降最多', '${downs.first.name} ${_yuan(downs.first.delta)}'),
    ],
    narrative: narrative.toString(),
    tone: delta > 0 ? AnswerTone.warn : AnswerTone.good,
    suggestions: _defaultSuggestions(intent),
  );
}

// ────────────────────────────── 大额 ──────────────────────────────

FinanceAnswer _topExpenses(TopExpensesIntent intent, FinanceData data) {
  final String period = intent.period.label;
  final List<TxRow> periodRows = _rowsIn(data.rows, intent.period);
  final List<TxRow> expenses =
      periodRows.where((TxRow t) => t.type == 'expense').toList()
        ..sort((TxRow a, TxRow b) => b.amountCents.compareTo(a.amountCents));
  final int total = summarize(periodRows).expenseCents;

  if (expenses.isEmpty) {
    return FinanceAnswer(
      title: '$period · 大额支出',
      narrative: '$period没有支出记录。',
      tone: AnswerTone.warn,
      suggestions: _defaultSuggestions(intent),
    );
  }

  final List<TxRow> top = expenses.take(intent.limit).toList();
  final int topSum = top.fold<int>(
    0,
    (int acc, TxRow t) => acc + t.amountCents,
  );

  final List<AnswerFact> facts = <AnswerFact>[
    for (final TxRow t in top)
      AnswerFact(
        '${_monthDay(t.occurredAt)} ${t.note.isEmpty ? (data.categoryNames[t.categoryId] ?? '支出') : t.note}',
        _yuan(t.amountCents),
        note: data.categoryNames[t.categoryId],
      ),
  ];

  return FinanceAnswer(
    title: '$period · 最大的 ${top.length} 笔',
    headline: _yuan(topSum),
    headlineNote: '占该期支出 ${_ratioText(topSum, total)}',
    facts: facts,
    narrative:
        '$period支出 ${_yuan(total)}，金额最大的 ${top.length} 笔合计 ${_yuan(topSum)}，'
        '占 ${_ratioText(topSum, total)}。最大的一笔是 ${_monthDay(top.first.occurredAt)}'
        '「${top.first.note.isEmpty ? (data.categoryNames[top.first.categoryId] ?? '支出') : top.first.note}」'
        '${_yuan(top.first.amountCents)}。',
    suggestions: _defaultSuggestions(intent),
  );
}

// ────────────────────────────── 储蓄目标 ──────────────────────────────

FinanceAnswer _savings(SavingsGoalIntent intent, FinanceData data) {
  final int months =
      (intent.targetCents + intent.monthlyCents - 1) ~/ intent.monthlyCents;
  final DateTime now = DateTime.fromMillisecondsSinceEpoch(data.nowMs);
  final DateTime done = DateTime(now.year, now.month + months, now.day);
  final int saved = intent.monthlyCents * months;

  return FinanceAnswer(
    title: '储蓄计划',
    headline: '$months 个月',
    headlineNote:
        '每月存 ${_yuan(intent.monthlyCents)} → 目标 ${_yuan(intent.targetCents)}',
    facts: <AnswerFact>[
      AnswerFact('每月存', _yuan(intent.monthlyCents)),
      AnswerFact('目标', _yuan(intent.targetCents)),
      AnswerFact('需要', '$months 个月'),
      AnswerFact('大约', '${done.year} 年 ${done.month} 月'),
      AnswerFact(
        '届时共存',
        _yuan(saved),
        note: '多出 ${_yuan(saved - intent.targetCents)}',
      ),
    ],
    narrative:
        '每月存 ${_yuan(intent.monthlyCents)}，攒够 ${_yuan(intent.targetCents)} 需要 $months 个月，'
        '大约 ${done.year} 年 ${done.month} 月达成（届时共存 ${_yuan(saved)}）。'
        '这是按固定金额的纯算术，不含利息。',
    tone: AnswerTone.good,
    suggestions: _defaultSuggestions(intent),
  );
}

// ────────────────────────────── 不认识 ──────────────────────────────

FinanceAnswer _unknown(UnknownIntent _) {
  return const FinanceAnswer(
    title: '这个我还没学会',
    narrative:
        '我现在只能答「账本里的数」，还不做开放式聊天。'
        '试试问我：本月花了多少、某个分类花了多少、预算还剩多少、为什么比上个月多、最近的大额支出。',
    tone: AnswerTone.warn,
    suggestions: kExampleQuestions,
  );
}

// ────────────────────────────── 商户 / 备注 ──────────────────────────────

/// 「星巴克花了多少」：按备注关键词过滤，给合计 + 笔数 + 最近一笔。
///
/// 为什么用备注：自动记账把通知原文写进 `note`，手动记账的商户也常写在备注里 ——
/// 这是唯一跨 App 的商户载体（没有独立的 merchant 字段）。
FinanceAnswer _merchant(MerchantSpendingIntent intent, FinanceData data) {
  final String period = intent.period.label;
  final String needle = intent.keyword.toLowerCase();
  final List<TxRow> matched = <TxRow>[
    for (final TxRow t in _rowsIn(data.rows, intent.period))
      if (t.type == intent.kind && t.note.toLowerCase().contains(needle)) t,
  ]..sort((TxRow a, TxRow b) => b.occurredAt.compareTo(a.occurredAt));

  final String unit = intent.kind == 'income' ? '收入' : '支出';

  if (matched.isEmpty) {
    return FinanceAnswer(
      title: '$period · 「${intent.keyword}」',
      narrative: '$period没有备注里带「${intent.keyword}」的$unit。',
      tone: AnswerTone.warn,
      suggestions: _defaultSuggestions(intent),
    );
  }

  final int total = matched.fold<int>(
    0,
    (int acc, TxRow t) => acc + t.amountCents,
  );
  final TxRow latest = matched.first;

  return FinanceAnswer(
    title: '$period · 「${intent.keyword}」$unit',
    headline: _yuan(total),
    narrative:
        '共 ${matched.length} 笔。最近一笔 ${_monthDay(latest.occurredAt)} ${_yuan(latest.amountCents)}'
        '${latest.note.isEmpty ? '' : '（${latest.note}）'}。',
    tone: AnswerTone.good,
    facts: <AnswerFact>[
      AnswerFact('合计', _yuan(total), note: '${matched.length} 笔'),
      AnswerFact(
        '最近一笔',
        _yuan(latest.amountCents),
        note: _monthDay(latest.occurredAt),
      ),
      if (matched.length > 1)
        AnswerFact(
          '最多一笔',
          _yuan(
            matched
                .map((TxRow t) => t.amountCents)
                .reduce((int a, int b) => a > b ? a : b),
          ),
        ),
    ],
    suggestions: _defaultSuggestions(intent),
  );
}
