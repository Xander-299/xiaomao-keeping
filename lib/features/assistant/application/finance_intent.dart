/// 一句话问题 → 可执行的财务查询（**纯函数，不碰数据库、不碰 UI**）。
///
/// 这一层是 M1 的全部"理解能力"：没有模型，只有规则。
/// 之所以敢这样做：`Prompt.md` 阶段二列的 7 个示例问题里，6 个本质是
/// 「选一个时间区间 + 选一个口径（汇总/分类/预算/对比/大额）」——
/// 规则完全够用，而且**算得准**（见 `docs/dev/llm-benchmark.md` §5：
/// 实测模型在这类算术上会编数，规则不会）。
///
/// 解析顺序 = 优先级（先命中先赢，与 `autobook_rules.dart` / `receipt_rules.dart` 同一写法）：
///   储蓄目标 → 预算 → 大额 → 对比 → 分类 → 汇总 → 不认识
/// 顺序的设计理由：
/// - 「这个月**为什么**花得比上个月多」同时含「这个月」「花」「上个月」，
///   必须先判「对比」再判「汇总」，否则会被当成「本月花了多少」；
/// - 「这个月**餐饮**花了多少」必须先判分类，否则分类信息被汇总吞掉。
library;

import '../../../core/utils/date.dart';
import '../../../core/utils/money.dart';

/// 一个时间区间（毫秒，半开 `[startMs, endMs)`）+ 给人看的标签。
///
/// 标签必须出现在回答里 —— 用户问「最近一个月」，答「上月」是错的；
/// 只有把**实际区间**写出来，才谈得上「数字可信」。
class Period {
  const Period({
    required this.startMs,
    required this.endMs,
    required this.label,
    this.year,
    this.month,
  });

  final int startMs;
  final int endMs;

  /// 例：`2026年10月` / `2026年` / `近 30 天（9月26日–10月25日）`。
  final String label;

  /// 仅「整月」时有值（预算要按 `YYYY-MM` 查）。
  final int? year;
  final int? month;

  bool get isWholeMonth => year != null && month != null;

  /// 某年某月。
  factory Period.month(int year, int month) {
    final ({int start, int end}) r = monthRange(year, month);
    return Period(
      startMs: r.start,
      endMs: r.end,
      label: '$year年$month月',
      year: year,
      month: month,
    );
  }

  /// 某一整年。
  factory Period.year(int year) => Period(
    startMs: DateTime(year).millisecondsSinceEpoch,
    endMs: DateTime(year + 1).millisecondsSinceEpoch,
    label: '$year年',
  );

  /// 含今天在内的最近 [days] 天（滚动的，不是自然月）。
  factory Period.lastDays(int nowMs, int days) {
    final DateTime now = DateTime.fromMillisecondsSinceEpoch(nowMs);
    final DateTime start = DateTime(now.year, now.month, now.day - (days - 1));
    final DateTime end = DateTime(now.year, now.month, now.day + 1);
    return Period(
      startMs: start.millisecondsSinceEpoch,
      endMs: end.millisecondsSinceEpoch,
      label: '近 $days 天（${start.month}月${start.day}日–${now.month}月${now.day}日）',
    );
  }

  /// 含本月在内的最近 [months] 个自然月。
  factory Period.lastMonths(int nowMs, int months) {
    final DateTime now = DateTime.fromMillisecondsSinceEpoch(nowMs);
    final DateTime start = DateTime(now.year, now.month - (months - 1), 1);
    final DateTime end = DateTime(now.year, now.month + 1, 1);
    final String label = start.year == now.year
        ? '近 $months 个月（${start.month}月–${now.month}月）'
        : '近 $months 个月（${start.year}年${start.month}月–${now.year}年${now.month}月）';
    return Period(
      startMs: start.millisecondsSinceEpoch,
      endMs: end.millisecondsSinceEpoch,
      label: label,
    );
  }
}

// ────────────────────────────── 会话上下文 ──────────────────────────────

/// 上一句问到的「上下文」，用于多轮追问（`那餐饮呢` / `大额的呢`）。
///
/// 只记**时间区间与方向**：分类名、商户关键词必须由本句给出 ——
/// 继承类别会让「那交通呢」变成「餐饮+交通」，口径就说不清了。
///
/// 解析层仍然是无状态的：上下文由调用方（`ChatController`）持有并显式传入。
class AssistantContext {
  const AssistantContext({this.period, this.kind = 'expense'});

  /// 上一句实际查的区间（null = 还没有过成功的查询）。
  final Period? period;

  /// 上一句的方向：`expense` / `income` / `both`。
  final String kind;

  @override
  String toString() => 'AssistantContext(${period?.label ?? '无区间'}, $kind)';
}

// ────────────────────────────── 意图 ──────────────────────────────

/// 一次查询的意图。
sealed class FinanceIntent {
  const FinanceIntent();
}

/// 收支汇总：这个月花了多少 / 上月收入多少。
final class MonthSummaryIntent extends FinanceIntent {
  const MonthSummaryIntent({required this.period, required this.kind});

  final Period period;

  /// `expense` / `income` / `both`（both = 同时给收入、支出、结余）。
  final String kind;
}

/// 某个分类的支出：这个月餐饮花了多少。
final class CategorySpendingIntent extends FinanceIntent {
  const CategorySpendingIntent({
    required this.period,
    required this.categoryName,
    required this.kind,
  });

  final Period period;
  final String categoryName;

  /// `expense` / `income`（同名分类在两侧都有，必须带方向）。
  final String kind;
}

/// 本月预算：还剩多少。
final class BudgetIntent extends FinanceIntent {
  const BudgetIntent({required this.period});

  final Period period;
}

/// 环比对比：为什么这个月比上个月多花 / 哪个分类涨得最多。
final class CompareIntent extends FinanceIntent {
  const CompareIntent({
    required this.current,
    required this.previous,
    required this.categoryFocus,
  });

  final Period current;
  final Period previous;

  /// true = 用户想知道「哪个分类变化最大」，false = 只想知道总额差。
  final bool categoryFocus;
}

/// 大额支出：最近有哪些大额支出。
final class TopExpensesIntent extends FinanceIntent {
  const TopExpensesIntent({required this.period, this.limit = 5});

  final Period period;
  final int limit;
}

/// 储蓄目标：每月存 2000，多久攒够 2 万（纯算术，不查库）。
final class SavingsGoalIntent extends FinanceIntent {
  const SavingsGoalIntent({
    required this.monthlyCents,
    required this.targetCents,
  });

  final int monthlyCents;
  final int targetCents;
}

/// 某个商户 / 备注关键词的支出：`星巴克花了多少`。
final class MerchantSpendingIntent extends FinanceIntent {
  const MerchantSpendingIntent({
    required this.period,
    required this.keyword,
    required this.kind,
  });

  final Period period;

  /// 原文里的关键词（已去前缀）；回答里原样回显，方便用户确认匹配到了什么。
  final String keyword;

  /// `expense` / `income`。
  final String kind;
}

/// 不认识的问题 → 交给 UI 给「可以这样问」的示例，绝不瞎答。
final class UnknownIntent extends FinanceIntent {
  const UnknownIntent(this.question);

  final String question;
}

/// 这条意图需要查哪段时间的流水；纯算术 / 不认识 → null（不查库）。
Period? windowOf(FinanceIntent intent) => switch (intent) {
  MonthSummaryIntent(:final Period period) => period,
  CategorySpendingIntent(:final Period period) => period,
  BudgetIntent(:final Period period) => period,
  TopExpensesIntent(:final Period period) => period,
  MerchantSpendingIntent(:final Period period) => period,
  CompareIntent(:final Period current, :final Period previous) => Period(
    startMs: previous.startMs,
    endMs: current.endMs,
    label: '${previous.label} 与 ${current.label}',
  ),
  SavingsGoalIntent() => null,
  UnknownIntent() => null,
};

// ────────────────────────────── 词表 ──────────────────────────────

/// 分类别名 → 正式分类名。只在**该分类真的存在**时才生效（避免答出不存在的分类）。
const Map<String, List<String>> kCategoryAliases = <String, List<String>>{
  '餐饮': <String>['吃饭', '外卖', '下馆子', '聚餐', '早午晚饭'],
  '交通': <String>['打车', '地铁', '公交', '加油', '出行', '高铁', '机票'],
  '购物': <String>['买东西', '网购', '剁手', '超市', '日用'],
  '娱乐': <String>['看电影', '玩游戏', '唱歌', '旅游'],
  '居住': <String>['房租', '水电', '物业', '房贷'],
  '医疗': <String>['看病', '买药', '体检', '医院'],
  '通讯': <String>['话费', '流量', '宽带'],
  '工资': <String>['薪水', '发工资', '薪资'],
  '奖金': <String>['年终奖', '绩效'],
  '理财': <String>['利息', '基金', '收益'],
};

/// 判断「大额」类问题的词。
final RegExp _reTop = RegExp(
  r'大额|最贵|最大的一笔|花得最多|花钱最多|前\s*\d+\s*笔|top\s*\d+',
  caseSensitive: false,
);

/// 判断「对比 / 变化」类问题的词。
final RegExp _reCompare = RegExp(r'为什么|为何|比上|对比|相比|增长|下降|多了|少了|多花|少花|变化');

/// 判断「预算」的词。
final RegExp _reBudget = RegExp(r'预算');

/// 判断「储蓄目标」的词。
final RegExp _reSave = RegExp(r'存|攒');

/// 判断「多久」的词。
final RegExp _reHowLong = RegExp(r'多久|几个月|什么时候|多长时间|多久能');

/// 收入方向的词（先判收入，避免「收入 5000」被当成支出问题）。
final RegExp _reIncome = RegExp(r'收入|赚了|赚到|进账|到账|发了多少');

/// 明确指向「支出」的词。
final RegExp _reExpense = RegExp(r'花了|花掉|支出|消费|开支|用了多少');

// ────────────────────────────── 解析入口 ──────────────────────────────

/// 把一句中文问题解析成 [FinanceIntent]。
///
/// [expenseCategories] / [incomeCategories] 是当前账本里**真实存在**的分类名
/// （由调用方从 `categoriesProvider` 取），用来做「问题里提到的分类」匹配。
/// [nowMs] 显式传入（不在这里读时钟），保证测试可复现。
FinanceIntent parseFinanceIntent(
  String raw, {
  required List<String> expenseCategories,
  required List<String> incomeCategories,
  required int nowMs,
  AssistantContext? context,
}) {
  final String text = _normalize(raw);
  final DateTime now = DateTime.fromMillisecondsSinceEpoch(nowMs);
  // 追问时沿用上一句的区间；本句显式说了时间就以本句为准（见 _parsePeriod 末尾）。
  final Period? fallback = context?.period;

  // ① 储蓄目标（纯算术，最优先：它含「存」「多久」，会被后面的词误判）
  final SavingsGoalIntent? savings = _parseSavings(text);
  if (savings != null) return savings;

  // ② 预算
  if (_reBudget.hasMatch(text)) {
    final Period p = _parsePeriod(text, now, nowMs, fallback: fallback);
    // 预算按自然月存，「近 30 天」这种区间没有预算可查 → 退回本月
    return BudgetIntent(
      period: p.isWholeMonth ? p : Period.month(now.year, now.month),
    );
  }

  // ③ 大额支出
  if (_reTop.hasMatch(text)) {
    final Period p = _parseTopPeriod(text, now, nowMs, fallback: fallback);
    return TopExpensesIntent(period: p);
  }

  // ④ 对比（必须早于「汇总」和「分类」）
  if (_reCompare.hasMatch(text)) {
    final ({Period current, Period previous})? pair = _parseComparePair(
      text,
      now,
      nowMs,
      fallback: fallback,
    );
    if (pair != null) {
      return CompareIntent(
        current: pair.current,
        previous: pair.previous,
        categoryFocus:
            text.contains('分类') || text.contains('哪类') || text.contains('哪一项'),
      );
    }
  }

  // ⑤ 分类支出
  final ({String name, String kind})? hit = _findCategory(
    text,
    expenseCategories: expenseCategories,
    incomeCategories: incomeCategories,
  );
  if (hit != null) {
    return CategorySpendingIntent(
      period: _parsePeriod(text, now, nowMs, fallback: fallback),
      categoryName: hit.name,
      kind: hit.kind,
    );
  }

  // ⑥ 商户 / 备注关键词：`星巴克花了多少`（分类优先，避免「餐饮」被当成商户）
  final MerchantSpendingIntent? merchant = _parseMerchant(
    text,
    period: _parsePeriod(text, now, nowMs, fallback: fallback),
    categoryWords: <String>[...expenseCategories, ...incomeCategories],
  );
  if (merchant != null) return merchant;

  // ⑦ 收支汇总（默认口径：只问「多少」时给支出；问「收入」时给收入；含「结余/剩」时两者都给）
  if (RegExp(r'花|支出|消费|开支|收入|赚|结余|剩|多少|账').hasMatch(text)) {
    return MonthSummaryIntent(
      period: _parsePeriod(text, now, nowMs, fallback: fallback),
      kind: _kindOf(text),
    );
  }

  return UnknownIntent(raw.trim());
}

// ────────────────────────────── 各段解析 ──────────────────────────────

String _normalize(String raw) {
  final String s = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
  // 中文数字 → 阿拉伯数字（「最近三个月」「近七天」），只处理「N 个?月 / N 天」这两种
  // 跟时间有关的用法；金额里的「两千」不做转换（宁可不认，也不猜错）。
  return s.replaceAllMapped(RegExp(r'([一二两三四五六七八九十]{1,3})\s*(个)?\s*(月|天|周|星期)'), (
    Match m,
  ) {
    final int? n = _cnNumber(m.group(1)!);
    if (n == null) return m.group(0)!;
    return '$n${m.group(2) ?? ''}${m.group(3)}';
  });
}

/// 「一」…「十二」→ 数字；认不出返回 null（保持原样）。
int? _cnNumber(String s) {
  const Map<String, int> map = <String, int>{
    '一': 1,
    '二': 2,
    '两': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
    '十': 10,
  };
  if (s.length == 1) return map[s];
  if (s.length == 2 && s.startsWith('十')) return 10 + (map[s[1]] ?? 0);
  if (s.length == 2 && s.endsWith('十')) return (map[s[0]] ?? 0) * 10;
  if (s.length == 3 && s[1] == '十') {
    final int? tens = map[s[0]];
    final int? ones = map[s[2]];
    if (tens == null || ones == null) return null;
    return tens * 10 + ones;
  }
  return null;
}

/// 方向：含收入词且不含明确支出词 → income；含「结余/剩」→ both；其余 expense。
String _kindOf(String text) {
  final bool income = _reIncome.hasMatch(text);
  final bool expense = _reExpense.hasMatch(text);
  if (income && !expense) return 'income';
  if (expense && !income) return 'expense';
  if (income && expense) return 'both';
  if (RegExp(r'结余|剩余|剩下的钱').hasMatch(text)) return 'both';
  return 'expense';
}

/// 时段：显式日/周 > 显式年月 > 上/本月 > 今年/去年 > 近 N 天/周/月 > [fallback] > 本月。
///
/// [fallback] 是**多轮追问**用的「上一句区间」：本句没提时间就沿用它 ——
/// 这样「这个月花了多少」→「那餐饮呢」查的还是同一个月。
Period _parsePeriod(String text, DateTime now, int nowMs, {Period? fallback}) {
  final RegExpMatch? ym = RegExp(r'(\d{4})\s*年\s*(\d{1,2})\s*月')
      .firstMatch(text);
  if (ym != null) {
    final int y = int.parse(ym.group(1)!);
    final int m = int.parse(ym.group(2)!);
    if (m >= 1 && m <= 12) return Period.month(y, m);
  }

  if (RegExp(r'上个?月|上月').hasMatch(text)) {
    return Period.month(
      now.month == 1 ? now.year - 1 : now.year,
      now.month == 1 ? 12 : now.month - 1,
    );
  }
  if (RegExp(r'这个?月|本月|当月|这月').hasMatch(text)) {
    return Period.month(now.year, now.month);
  }
  if (RegExp(r'今年|本年').hasMatch(text)) return Period.year(now.year);
  if (RegExp(r'去年').hasMatch(text)) return Period.year(now.year - 1);

  // 今天 / 昨天 / 前天（自然日）
  final RegExpMatch? day = RegExp(r'今天|昨天|前天').firstMatch(text);
  if (day != null) {
    final int back = switch (day.group(0)) {
      '今天' => 0,
      '昨天' => 1,
      _ => 2,
    };
    final DateTime d = DateTime(now.year, now.month, now.day - back);
    final DateTime e = DateTime(now.year, now.month, now.day - back + 1);
    return Period(
      startMs: d.millisecondsSinceEpoch,
      endMs: e.millisecondsSinceEpoch,
      label: '${d.month}月${d.day}日（${day.group(0)}）',
    );
  }

  // 周：以周一为起点（国内习惯）
  if (RegExp(r'上上周|上上星期').hasMatch(text)) {
    return _weekPeriod(
      _weekStart(now).subtract(const Duration(days: 14)),
      label: '上上周',
    );
  }
  if (RegExp(r'上周|上星期|上个星期').hasMatch(text)) {
    return _weekPeriod(
      _weekStart(now).subtract(const Duration(days: 7)),
      label: '上周',
    );
  }
  if (RegExp(r'这周|本周|这星期|这个星期').hasMatch(text)) {
    return _weekPeriod(_weekStart(now), label: '本周');
  }
  final RegExpMatch? weeks = RegExp(r'(?:最近|近)\s*(\d+)\s*(?:个)?\s*(?:周|星期)')
      .firstMatch(text);
  if (weeks != null) {
    final int n = int.parse(weeks.group(1)!);
    if (n > 0 && n <= 52) {
      final DateTime start = _weekStart(now)
          .subtract(Duration(days: 7 * (n - 1)));
      return _weekPeriod(start, label: '近 $n 周', weeks: n);
    }
  }

  // 「10 月」这种单说月份：不晚于当前月 → 今年；否则算去年
  final RegExpMatch? mOnly = RegExp(r'(?<!\d年)(\d{1,2})\s*月').firstMatch(text);
  if (mOnly != null) {
    final int m = int.parse(mOnly.group(1)!);
    if (m >= 1 && m <= 12) {
      if (m <= now.month) return Period.month(now.year, m);
      return Period.month(now.year - 1, m);
    }
  }

  final RegExpMatch? days = RegExp(r'最近?\s*(\d+)\s*天|近\s*(\d+)\s*天')
      .firstMatch(text);
  if (days != null) {
    final int n = int.parse(days.group(1) ?? days.group(2)!);
    if (n > 0 && n <= 3650) return Period.lastDays(nowMs, n);
  }
  final RegExpMatch? months = RegExp(r'最近?\s*(\d+)\s*个?月|近\s*(\d+)\s*个?月')
      .firstMatch(text);
  if (months != null) {
    final int n = int.parse(months.group(1) ?? months.group(2)!);
    if (n > 0 && n <= 120) return Period.lastMonths(nowMs, n);
  }
  if (RegExp(r'最近一个月|近一个月').hasMatch(text)) return Period.lastDays(nowMs, 30);

  return fallback ?? Period.month(now.year, now.month);
}

/// 本周一 00:00（周一起算）。
DateTime _weekStart(DateTime d) {
  final DateTime day = DateTime(d.year, d.month, d.day);
  return day.subtract(Duration(days: day.weekday - 1));
}

/// 从 [start]（必须是周一）开始的整周区间；[weeks] > 1 时连成一段。
Period _weekPeriod(DateTime start, {required String label, int weeks = 1}) {
  final DateTime end = DateTime(start.year, start.month, start.day + 7 * weeks);
  return Period(
    startMs: start.millisecondsSinceEpoch,
    endMs: end.millisecondsSinceEpoch,
    label:
        '$label（${start.month}月${start.day}日–${end.subtract(const Duration(days: 1)).month}月${end.subtract(const Duration(days: 1)).day}日）',
  );
}

/// 上一个**等长**区间（「比上个月呢」用）：
/// 整月 → 上月；整年 → 去年；其余按跨度平移。
Period previousPeriodOf(Period p) {
  if (p.isWholeMonth) {
    final int y = p.year!;
    final int m = p.month!;
    return Period.month(m == 1 ? y - 1 : y, m == 1 ? 12 : m - 1);
  }
  final int span = p.endMs - p.startMs;
  final DateTime start = DateTime.fromMillisecondsSinceEpoch(p.startMs - span);
  final DateTime end = DateTime.fromMillisecondsSinceEpoch(p.startMs);
  return Period(
    startMs: start.millisecondsSinceEpoch,
    endMs: end.millisecondsSinceEpoch,
    label: '${start.month}月${start.day}日–${end.month}月${end.day}日',
  );
}

/// 大额支出默认看「近 90 天」；用户显式说了时间就按用户说的；
/// 追问（「大额的呢」）沿用上一句区间。
Period _parseTopPeriod(
  String text,
  DateTime now,
  int nowMs, {
  Period? fallback,
}) {
  final bool explicitTime = RegExp(
    r'\d+\s*月|\d+\s*天|\d+\s*周|这个?月|上个?月|今年|去年|今天|昨天|前天|这周|上周',
  ).hasMatch(text);
  if (explicitTime) return _parsePeriod(text, now, nowMs, fallback: fallback);
  if (fallback != null && RegExp(r'呢$').hasMatch(text)) return fallback;
  return Period.lastDays(nowMs, 90);
}

/// 对比的两个区间：默认「本月 vs 上月」；「近 N 个月」→「近 N 月 vs 前 N 月」。
({Period current, Period previous})? _parseComparePair(
  String text,
  DateTime now,
  int nowMs, {
  Period? fallback,
}) {
  final RegExpMatch? months = RegExp(r'最近?\s*(\d+)\s*个?月|近\s*(\d+)\s*个?月')
      .firstMatch(text);
  if (months != null) {
    final int n = int.parse(months.group(1) ?? months.group(2)!);
    if (n > 0 && n <= 24) {
      final DateTime startD = DateTime(now.year, now.month - (n - 1), 1);
      final DateTime prevEnd = startD;
      final DateTime prevStart = DateTime(startD.year, startD.month - n, 1);
      return (
        current: Period(
          startMs: startD.millisecondsSinceEpoch,
          endMs: DateTime(now.year, now.month + 1).millisecondsSinceEpoch,
          label: Period.lastMonths(nowMs, n).label,
        ),
        previous: Period(
          startMs: prevStart.millisecondsSinceEpoch,
          endMs: prevEnd.millisecondsSinceEpoch,
          label: '前 $n 个月',
        ),
      );
    }
  }

  // 显式年月：2026年9月 vs 2026年8月
  final RegExpMatch? ym = RegExp(r'(\d{4})\s*年\s*(\d{1,2})\s*月')
      .firstMatch(text);
  if (ym != null) {
    final int y = int.parse(ym.group(1)!);
    final int m = int.parse(ym.group(2)!);
    if (m >= 1 && m <= 12) {
      final Period cur = Period.month(y, m);
      final Period prev = Period.month(m == 1 ? y - 1 : y, m == 1 ? 12 : m - 1);
      return (current: cur, previous: prev);
    }
  }

  // 追问（「比上个月呢」）：拿上一句的区间当「当前」，再取等长的前一段
  if (fallback != null && fallback.isWholeMonth == false) {
    return (current: fallback, previous: previousPeriodOf(fallback));
  }

  // 默认：本月 vs 上月
  final Period cur = Period.month(now.year, now.month);
  final Period prev = Period.month(
    now.month == 1 ? now.year - 1 : now.year,
    now.month == 1 ? 12 : now.month - 1,
  );
  return (current: cur, previous: prev);
}

/// 文本里提到的分类（含别名）。命中多个时取**名字最长**的，避免「餐」吃掉「餐饮」。
({String name, String kind})? _findCategory(
  String text, {
  required List<String> expenseCategories,
  required List<String> incomeCategories,
}) {
  ({String name, String kind})? best;
  int bestLen = 0;

  void consider(String canonical, String word, String kind) {
    if (word.length < 2) return;
    if (!text.contains(word)) return;
    if (word.length > bestLen) {
      best = (name: canonical, kind: kind);
      bestLen = word.length;
    }
  }

  for (final String name in expenseCategories) {
    consider(name, name, 'expense');
  }
  for (final String name in incomeCategories) {
    consider(name, name, 'income');
  }
  // 别名只在正式分类存在时生效
  kCategoryAliases.forEach((String canonical, List<String> aliases) {
    final String? kind = expenseCategories.contains(canonical)
        ? 'expense'
        : (incomeCategories.contains(canonical) ? 'income' : null);
    if (kind == null) return;
    for (final String alias in aliases) {
      consider(canonical, alias, kind);
    }
  });
  return best;
}

/// 解析「每月存 2000，多久攒够 2 万」。
///
/// 数字必须**同时**出现「每个月存的额度」和「目标金额」，否则不算储蓄问题
/// （避免「我存了多少钱」这种记账问题被误判）。
SavingsGoalIntent? _parseSavings(String text) {
  if (!_reSave.hasMatch(text)) return null;
  if (!_reHowLong.hasMatch(text)) return null;

  final RegExpMatch? monthly = RegExp(
    r'每(?:个)?月(?:能|可以)?\s*(?:存|攒|存下|攒下)?\s*(\d+(?:\.\d{1,2})?)\s*(万|千)?',
  ).firstMatch(text);
  final RegExpMatch? target = RegExp(
    r'(?:攒够|存够|凑够|攒到|存到|目标(?:是)?)\s*(\d+(?:\.\d{1,2})?)\s*(万|千)?',
  ).firstMatch(text);
  if (monthly == null || target == null) return null;

  final int perMonth = _amountCents(monthly.group(1)!, monthly.group(2));
  final int goal = _amountCents(target.group(1)!, target.group(2));
  if (perMonth <= 0 || goal <= 0) return null;
  return SavingsGoalIntent(monthlyCents: perMonth, targetCents: goal);
}

int _amountCents(String number, String? unit) {
  final int base = yuanToCents(number);
  return switch (unit) {
    '万' => base * 10000,
    '千' => base * 1000,
    _ => base,
  };
}

/// 商户 / 备注关键词：`星巴克花了多少` / `在星巴克消费了多少`。
///
/// 判据保守：关键词 1–8 字、不含时间词、不是已有分类名 —— 否则「这个月花了多少」
/// 会把「这个月」当成商户。匹配走 `note.contains`（自动记账把通知文案写进备注）。
MerchantSpendingIntent? _parseMerchant(
  String text, {
  required Period period,
  required List<String> categoryWords,
}) {
  final RegExpMatch? m = RegExp(
    r'(?:在)?\s*([^\s，。？！?]{1,8}?)\s*(?:花了|消费了?|付了|用了)\s*(?:多少|多少钱)',
  ).firstMatch(text);
  if (m == null) return null;
  String keyword = m.group(1)!.trim();
  // 去掉常见前缀，别把「我」「这个月」当商户
  keyword = keyword.replaceAll(RegExp(r'^(我|这个|上个月|本月|最近)'), '').trim();
  if (keyword.isEmpty || keyword.length < 2) return null;
  // 时间词 / 分类名 / 纯数字 → 不是商户
  if (RegExp(r'今天|昨天|前天|这周|上周|月|年|天|周|号|星期').hasMatch(keyword)) {
    return null;
  }
  for (final String c in categoryWords) {
    if (c == keyword || keyword.contains(c)) return null;
  }
  if (RegExp(r'^\d+$').hasMatch(keyword)) return null;

  final String kind = _reIncome.hasMatch(text) && !_reExpense.hasMatch(text)
      ? 'income'
      : 'expense';
  return MerchantSpendingIntent(period: period, keyword: keyword, kind: kind);
}
