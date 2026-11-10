/// 日历页状态：**可见年月** 与 **选中日** 解耦，数据分两段加载。
///
/// 三条产品约束（2026-10-29 用户要求）决定了这个结构：
/// 1. **先日历、再账单、最后标注**：打开页面时网格要立刻出来（它不依赖任何数据），
///    选中日的账单单独查一次，整月的「日标注 + 月结余」再补上 —— 不要整页等齐才显示；
/// 2. **不能翻到未来月**：与首页 `canGoNext` 同一口径；
/// 3. **翻月不动选中日**：翻到 9 月时下面仍是「10月12日」那批账单，
///    只有用户真的点了别的日子，账单才换。
///
/// 所以 `selectedDate` 是**完整日期**（可能不在 `year/month` 里），
/// 网格高亮用它 + 可见月一起判断（[CalendarState.selectedDayInGrid]，不在本月就给 0）。
///
/// 与首页的 `ledgerProvider` **刻意分离**：日历翻月/选日不应把首页的月份一起带走。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/data/providers/book_providers.dart';
import 'package:yanxin/data/providers/database.dart';
import 'package:yanxin/data/repositories/transaction_repository.dart';
import 'package:yanxin/features/ledger/application/ledger_controller.dart'
    show canGoNext;
import 'package:yanxin/features/ledger/application/month_summary.dart';

import 'calendar_aggregate.dart';

/// 一个月的聚合结果（只服务网格标注与月汇总条，不含具体流水）。
class MonthAgg {
  const MonthAgg({
    required this.byDay,
    required this.summary,
    required this.dailyAvgExpenseCents,
  });

  /// 按「当月第几天」聚合的收支，供日历格子标注。
  final Map<int, DayAgg> byDay;

  /// 月度汇总（月结余 = 收入 - 支出）。
  final MonthSummary summary;

  /// 日均支出（分）；当月按已过天数折算。
  final int dailyAvgExpenseCents;

  static MonthAgg of(List<TxRow> items, {required int year, required int month}) {
    final MonthSummary summary = summarize(items);
    return MonthAgg(
      byDay: aggregateByDay(items),
      summary: summary,
      dailyAvgExpenseCents: dailyAverageExpenseCents(
        expenseCents: summary.expenseCents,
        year: year,
        month: month,
        nowMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  static const MonthAgg empty = MonthAgg(
    byDay: <int, DayAgg>{},
    summary: MonthSummary(incomeCents: 0, expenseCents: 0, balanceCents: 0),
    dailyAvgExpenseCents: 0,
  );
}

/// 日历页状态快照。
class CalendarState {
  const CalendarState({
    required this.year,
    required this.month,
    required this.selectedDate,
    required this.day,
    required this.monthAgg,
  });

  /// 网格当前显示的年。
  final int year;

  /// 网格当前显示的月（1-12）。
  final int month;

  /// 选中的**完整日期**；翻月不改变它，所以它可能不在 [year]/[month] 里。
  final DateTime selectedDate;

  /// 选中日的账单（第一段数据）。
  final AsyncValue<List<TxRow>> day;

  /// 可见月的聚合（第二段数据：日标注 + 月结余 + 日均）。
  final AsyncValue<MonthAgg> monthAgg;

  /// 选中日是否落在当前可见月里。
  bool get selectionInVisibleMonth =>
      selectedDate.year == year && selectedDate.month == month;

  /// 网格高亮用：不在可见月 → 0（0 永远不会命中任何一天，等于不高亮）。
  int get selectedDayInGrid => selectionInVisibleMonth ? selectedDate.day : 0;

  /// 选中日的流水。
  List<TxRow> get selectedItems => day.value ?? const <TxRow>[];

  /// 选中日 0 点毫秒（记一笔默认日期、空态按钮用）。
  int get selectedDayMs =>
      DateTime(selectedDate.year, selectedDate.month, selectedDate.day)
          .millisecondsSinceEpoch;

  /// 月汇总（未加载时给空数据，汇总条自己显示占位）。
  MonthSummary get summary => monthAgg.value?.summary ?? MonthAgg.empty.summary;

  /// 日标注（未加载时为空表 = 不画标注）。
  Map<int, DayAgg> get byDay => monthAgg.value?.byDay ?? const <int, DayAgg>{};

  /// 日均支出（分）。
  int get dailyAvgExpenseCents =>
      monthAgg.value?.dailyAvgExpenseCents ?? 0;

  CalendarState copyWith({
    int? year,
    int? month,
    DateTime? selectedDate,
    AsyncValue<List<TxRow>>? day,
    AsyncValue<MonthAgg>? monthAgg,
  }) => CalendarState(
    year: year ?? this.year,
    month: month ?? this.month,
    selectedDate: selectedDate ?? this.selectedDate,
    day: day ?? this.day,
    monthAgg: monthAgg ?? this.monthAgg,
  );
}

/// 日历页 controller（**同步 state**：首帧就能画网格）。
final calendarProvider = NotifierProvider<CalendarController, CalendarState>(
  CalendarController.new,
);

class CalendarController extends Notifier<CalendarState> {
  /// 防止并发重入（切日 + 翻月几乎同时触发时只保留最早的加载链）。
  bool _busy = false;

  /// busy 期间收到的 refresh 请求：合并成一次，当前链条结束后补跑。
  ///
  /// 不删除 [_busy] 守卫（否则会并发跑两套 day/month 加载）；也不做无界队列，
  /// 多次 pending 只记一个 bool。
  bool _refreshQueued = false;

  /// 选中日请求序号：每发起一次 [_loadDay] 自增。
  ///
  /// 快速切日时，较早请求可能较晚返回；只有「序号仍是最后一次 + selectedDate
  /// 仍是发起时的日期」才允许写 state，过期结果直接丢弃（成功和失败都一样）。
  int _dayRequestId = 0;

  /// provider 被释放（重建 / 换账本）后，迟到的异步结果不能再写 state。
  bool _disposed = false;

  bool _isCurrentDayRequest(int requestId, DateTime date) =>
      !_disposed &&
      requestId == _dayRequestId &&
      state.selectedDate == date;

  @override
  CalendarState build() {
    _disposed = false;
    _refreshQueued = false;
    ref.onDispose(() => _disposed = true);
    // P3：换账本时**重建自己**。
    //
    // 这个控制器刻意不 watch 账本（日历翻月不该把首页月份带走），代价是：换账本后
    // 实例还活着，在途请求也不会被 `_disposed` 拦住 —— 旧账本的结果会被写进新账本的视图。
    // 只比对 `bookId` 也没用（在途请求手里拿的旧 id 与字段里的旧 id 永远相等），
    // 所以在这里监听：账本真的换了就 invalidateSelf，旧实例 dispose → 迟到结果全丢，
    // 新实例按新账本重新加载。
    //
    // 只认「非 null → 另一个非 null」：启动时 null → 首个账本是正常初始化，不该重置。
    ref.listen<AsyncValue<String?>>(activeBookIdProvider, (
      AsyncValue<String?>? prev,
      AsyncValue<String?> next,
    ) {
      final String? before = prev?.value;
      final String? after = next.value;
      if (before != null && after != null && before != after) {
        ref.invalidateSelf();
      }
    });
    final DateTime now = DateTime.now();
    // 首帧：网格 + 选中今天；两段数据都是 loading。
    // 真正的加载放在 build 之后（不能在这里 await，否则首帧又变成整页转圈）。
    final CalendarState initial = CalendarState(
      year: now.year,
      month: now.month,
      selectedDate: DateTime(now.year, now.month, now.day),
      day: const AsyncValue<List<TxRow>>.loading(),
      monthAgg: const AsyncValue<MonthAgg>.loading(),
    );
    Future<void>.microtask(() {
      if (_disposed) return;
      unawaited(refresh());
    });
    return initial;
  }

  Future<String?> _bookId() => ref.read(activeBookIdProvider.future);

  /// 一段：选中日账单。只查这一天（[startMs, endMs)）。
  Future<void> _loadDay() async {
    final int requestId = ++_dayRequestId;
    // 先同步捕获本次请求对应的日期，再 await；否则 await 期间切日会把
    // 「新日期」写进旧请求的 loading/data。
    final DateTime date = state.selectedDate;
    final int startMs =
        DateTime(date.year, date.month, date.day).millisecondsSinceEpoch;
    final int endMs =
        DateTime(date.year, date.month, date.day + 1).millisecondsSinceEpoch;

    final String? bookId = await _bookId();
    if (!_isCurrentDayRequest(requestId, date) || bookId == null) return;

    state = state.copyWith(day: const AsyncValue<List<TxRow>>.loading());
    try {
      final List<TxRow> rows = await ref
          .read(transactionRepositoryProvider)
          .listByRange(bookId, startMs, endMs);
      // 查询期间可能已经切到别的日期 —— 旧结果不能覆盖新日期。
      if (!_isCurrentDayRequest(requestId, date)) return;
      state = state.copyWith(day: AsyncValue<List<TxRow>>.data(rows));
    } catch (e, st) {
      // 过期请求的失败同样不能把当前日期的成功/loading 改成 error。
      if (!_isCurrentDayRequest(requestId, date)) return;
      state = state.copyWith(day: AsyncValue<List<TxRow>>.error(e, st));
    }
  }

  /// 二段：整月聚合（日标注 / 月结余 / 日均）。
  Future<void> _loadMonth() async {
    final String? bookId = await _bookId();
    if (_disposed || bookId == null) return;
    final CalendarState s = state;
    final int y = s.year;
    final int m = s.month;
    try {
      final List<TxRow> rows = await ref
          .read(transactionRepositoryProvider)
          .listByMonth(bookId, y, m);
      // 查询期间可能已经翻到别的月 / provider 已释放 —— 结果过期就丢掉
      if (_disposed || state.year != y || state.month != m) return;
      state = state.copyWith(monthAgg: AsyncValue<MonthAgg>.data(MonthAgg.of(rows, year: y, month: m)));
    } catch (e, st) {
      if (_disposed || state.year != y || state.month != m) return;
      state = state.copyWith(monthAgg: AsyncValue<MonthAgg>.error(e, st));
    }
  }

  /// 两段都重来（打开页面 / 记完一笔 / 删完一笔）：**先账单，后标注**。
  ///
  /// 如果已有 refresh 在跑，不丢弃本次请求，而是标记 pending；当前链条
  /// 结束后合并补跑一次。dispose 后不再触发新的异步链。
  Future<void> refresh() async {
    if (_disposed) return;
    if (_busy) {
      _refreshQueued = true;
      return;
    }
    _busy = true;
    try {
      await _loadDay();
      if (_disposed) return;
      await _loadMonth();
    } finally {
      _busy = false;
      if (_disposed) {
        _refreshQueued = false;
      } else if (_refreshQueued) {
        _refreshQueued = false;
        unawaited(refresh());
      }
    }
  }

  /// 选中某一天（只重查那天的账单；月份标注不变，不重查）。
  void selectDay(int day) {
    final CalendarState s = state;
    final DateTime next = DateTime(s.year, s.month, day);
    if (next == s.selectedDate) return;
    // 立即把旧日期的数据切成 loading：避免新日期头 + 旧账单短暂错配；
    // 之后的真实结果由 [_loadDay] 的请求序号校验决定是否落地。
    state = s.copyWith(
      selectedDate: next,
      day: const AsyncValue<List<TxRow>>.loading(),
    );
    unawaited(_loadDay());
  }

  /// 翻月：delta = -1 上一月，+1 下一月。
  ///
  /// **不改变选中日**（任务书 §3）：下面继续显示原来那天的账单，
  /// 只是网格换了月、并且本月之外不再高亮。**不能越过当前真实月**（任务书 §2）。
  Future<void> shiftMonth(int delta) async {
    final CalendarState s = state;
    if (delta > 0 && !canGoNext(s.year, s.month)) return;
    var y = s.year;
    var m = s.month + delta;
    if (m < 1) {
      m = 12;
      y--;
    } else if (m > 12) {
      m = 1;
      y++;
    }
    state = s.copyWith(year: y, month: m);
    await _loadMonth();
  }

  /// 直接跳到指定年月（月份选择子页用），可同时指定选中日。
  ///
  /// 未来月一律忽略（与 [canGoNext] 同口径）；同月的未来日也挡掉。
  Future<void> jumpTo(int year, int month, {int? day}) async {
    final DateTime now = DateTime.now();
    if (year * 12 + month > now.year * 12 + now.month) return;
    var target = day;
    if (target != null &&
        year == now.year &&
        month == now.month &&
        target > now.day) {
      target = now.day;
    }
    final CalendarState s = state;
    state = s.copyWith(
      year: year,
      month: month,
      selectedDate: target == null
          ? s.selectedDate
          : DateTime(year, month, target),
    );
    await _loadDay();
    await _loadMonth();
  }

  /// 软删除一笔并刷新（不物理删，DB 里 deleted_at 非空）。
  ///
  /// 返回**是否真的删掉了**（受影响行数 > 0）；P3：行可能已被首页 / 搜索删过。
  Future<bool> removeTx(String id) async {
    final int changed = await ref
        .read(transactionRepositoryProvider)
        .softDelete(id);
    await refresh();
    return changed > 0;
  }

  /// 撤销软删：返回可识别的结果；只有恢复成功才刷新。
  Future<TxRestoreResult> restoreTx(String id) async {
    final TxRestoreResult result = await ref
        .read(transactionRepositoryProvider)
        .restoreTx(id);
    if (result.isRestored) await refresh();
    return result;
  }
}

/// 某一年里「每个月有账的日期集合」：`{月: {日, ...}}`。
///
/// 供月份选择子页在缩略图上标出有账的日期。一次查全年，避免 12 次查询。
final yearDayIndexProvider = FutureProvider.family<Map<int, Set<int>>, int>((
  ref,
  int year,
) async {
  final bookId = await ref.watch(activeBookIdProvider.future);
  if (bookId == null) return const <int, Set<int>>{};
  final rows = await ref
      .watch(transactionRepositoryProvider)
      .listByYear(bookId, year);
  final map = <int, Set<int>>{};
  for (final r in rows) {
    final d = DateTime.fromMillisecondsSinceEpoch(r.occurredAt);
    (map[d.month] ??= <int>{}).add(d.day);
  }
  return map;
});
