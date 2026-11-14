/// 日历页：月份 header + 月历（每天标支出/收入）+ 月结余/日均支出 + 选中日账单。
///
/// 加载顺序（2026-10-29 用户要求，见 `calendar_controller.dart` 的类注释）：
/// **网格先出 → 选中日账单 → 整月标注**。所以页面里「网格 + 月汇总」和「当日账单」
/// 是两块独立区域：翻月只换上面那块（`MonthPager` 只包它），
/// 下面账单继续跟着**选中的日期**走，不会跟着月份跳。
///
/// 视觉参考 docs/design/calendar.jpg（布局对齐，配色沿用 App 品牌色）。
/// 页面无 Scaffold（壳路由 AppShell 提供抽屉与底栏）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/core/providers/data_epoch.dart';
import 'package:yanxin/core/theme/tokens.dart';
import 'package:yanxin/core/theme/toon.dart';
import 'package:yanxin/core/utils/date.dart';
import 'package:yanxin/core/utils/money.dart';
import 'package:yanxin/data/providers/category_providers.dart';
import 'package:yanxin/data/repositories/transaction_repository.dart';
import 'package:yanxin/features/ledger/application/ledger_controller.dart';
import 'package:yanxin/features/ledger/application/month_summary.dart';
import 'package:yanxin/features/ledger/presentation/tx_restore_message.dart';
import 'package:yanxin/features/ledger/presentation/widgets/swipe_action_row.dart';
import 'package:yanxin/features/ledger/presentation/widgets/tx_delete_dialog.dart';
import 'package:yanxin/features/ledger/presentation/widgets/tx_group_list.dart';
import 'package:yanxin/features/reports/application/reports_controller.dart';
import 'package:yanxin/features/shared/write_failure.dart';
import 'package:yanxin/features/stats/application/stats_controller.dart';

import '../application/calendar_aggregate.dart';
import '../application/calendar_controller.dart';
import 'widgets/month_grid.dart';
import 'widgets/month_pager.dart';

/// 日历页。
class CalendarPage extends ConsumerStatefulWidget {
  const CalendarPage({super.key});

  @override
  ConsumerState<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends ConsumerState<CalendarPage> {
  @override
  Widget build(BuildContext context) {
    // ⚠️ 同步 state（不是 AsyncValue）：首帧就能画网格，不用等任何查询。
    final CalendarState state = ref.watch(calendarProvider);
    final AsyncValue<List<Category>> categoriesAsync = ref.watch(
      categoriesProvider,
    );
    final String Function(String?) nameOf = _categoryNameResolver(
      categoriesAsync.value,
    );

    return SafeArea(
      bottom: false,
      child: Column(
        children: <Widget>[
          const _HeaderBody(),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  // 上半块：网格 + 月汇总。**只有这块跟着月份翻** ——
                  // 下半块的账单属于「选中日」，翻月不该动它。
                  _buildPager(state),

                  _SelectedDaySection(
                    state: state,
                    categoryNameOf: nameOf,
                    onEdit: (TxRow tx) => context.push('/record', extra: tx.id),
                    onDelete: (TxRow tx) => _confirmDelete(context, ref, tx),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 上半块：**跟手翻页**的月历（翻到一半就停在一半，松手再落定）。
  ///
  /// 相邻月在这里就提前取好（[monthAggPreviewProvider]）：手指还在拖的时候，
  /// 另一页已经有日标注与月汇总，不会先看到一张空网格再「补数字」。
  Widget _buildPager(CalendarState state) {
    final bool hasNext = canGoNext(state.year, state.month);
    final DateTime prev = _shiftMonth(state.year, state.month, -1);
    final DateTime next = _shiftMonth(state.year, state.month, 1);
    final MonthAgg? prevAgg = ref
        .watch(monthAggPreviewProvider((year: prev.year, month: prev.month)))
        .value;
    final MonthAgg? nextAgg = hasNext
        ? ref
              .watch(
                monthAggPreviewProvider((year: next.year, month: next.month)),
              )
              .value
        : null;

    return MonthPager(
      year: state.year,
      month: state.month,
      onTurn: (int delta) =>
          ref.read(calendarProvider.notifier).shiftMonth(delta),
      current: _MonthBlock(
        key: ValueKey<String>('${state.year}-${state.month}'),
        year: state.year,
        month: state.month,
        byDay: state.byDay,
        summary: state.summary,
        dailyAvgExpenseCents: state.dailyAvgExpenseCents,
        ready: state.monthAgg.hasValue,
        selectedDay: state.selectedDayInGrid,
        onSelectDay: (int day) =>
            ref.read(calendarProvider.notifier).selectDay(day),
        onLongPressDay: (DateTime day) {
          ref.read(calendarProvider.notifier).selectDay(day.day);
          context.push('/record?date=${day.millisecondsSinceEpoch}');
        },
      ),
      previous: _previewBlock(prev, prevAgg),
      next: hasNext ? _previewBlock(next, nextAgg) : null,
    );
  }

  /// 相邻月的「预览页」：不可点、不高亮选中日，只负责在翻页途中被看见。
  Widget _previewBlock(DateTime ym, MonthAgg? agg) => _MonthBlock(
    key: ValueKey<String>('preview-${ym.year}-${ym.month}'),
    year: ym.year,
    month: ym.month,
    byDay: agg?.byDay ?? const <int, DayAgg>{},
    summary: agg?.summary ?? MonthAgg.empty.summary,
    dailyAvgExpenseCents: agg?.dailyAvgExpenseCents ?? 0,
    ready: agg != null,
    selectedDay: 0,
  );

  DateTime _shiftMonth(int year, int month, int delta) {
    final int m = month + delta;
    if (m < 1) return DateTime(year - 1, 12);
    if (m > 12) return DateTime(year + 1, 1);
    return DateTime(year, m);
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    TxRow tx,
  ) async {
    if (!await confirmDeleteTx(context)) return;
    final bool deleted;
    try {
      deleted = await ref.read(calendarProvider.notifier).removeTx(tx.id);
    } catch (e) {
      if (context.mounted) {
        showToonError(context, writeFailureMessage(e, action: '删除'));
      }
      return;
    }
    ref.invalidate(yearDayIndexProvider);
    // 首页是同月数据的另一视图，保持一致
    unawaited(ref.read(ledgerProvider.notifier).refresh());
    // 统计页同理（常驻 Notifier，不会自己感知删除）
    unawaited(ref.read(statsProvider.notifier).refresh());
    // 资产页 watch 数据版本号，bump 即重算
    ref.read(dataEpochProvider.notifier).bump();
    if (!context.mounted) return;
    // P3：与首页同一口径 —— 0 行 = 早被别处删过，不报「已删除」也不给撤销。
    if (!deleted) {
      showToonFeedback(context, kTxAlreadyGoneMessage);
      return;
    }
    final String label = tx.note.isNotEmpty
        ? tx.note
        : '${centsToYuan(tx.amountCents, group: true)} 元';
    showToonUndo(
      context,
      '已删除「$label」',
      onUndo: () async {
        final TxRestoreResult result;
        try {
          result = await ref.read(calendarProvider.notifier).restoreTx(tx.id);
        } catch (e) {
          if (context.mounted) {
            showToonError(context, writeFailureMessage(e, action: '撤销'));
          }
          return;
        }
        if (result.isRestored) {
          ref.invalidate(yearDayIndexProvider);
          unawaited(ref.read(ledgerProvider.notifier).refresh());
          unawaited(ref.read(statsProvider.notifier).refresh());
          ref.read(dataEpochProvider.notifier).bump();
        } else if (context.mounted) {
          showToonError(context, txRestoreFailureMessage(result));
        }
      },
    );
  }

  String Function(String?) _categoryNameResolver(List<Category>? categories) {
    if (categories == null) {
      return (String? _) => '未分类';
    }
    final map = <String, String>{
      for (final c in categories) c.id: c.name,
    };
    return (String? id) => (id == null ? null : map[id]) ?? '未分类';
  }
}

/// 上半块：月历网格 + 月结余/日均。
///
/// 数据全部走参数（不再直接读 [CalendarState]）：翻页时同一个组件既要画
/// 「当前月」，也要画相邻月的**预览页**（数据来自 [monthAggPreviewProvider]）。
class _MonthBlock extends StatelessWidget {
  const _MonthBlock({
    super.key,
    required this.year,
    required this.month,
    required this.byDay,
    required this.summary,
    required this.dailyAvgExpenseCents,
    required this.ready,
    required this.selectedDay,
    this.onSelectDay,
    this.onLongPressDay,
  });

  final int year;
  final int month;
  final Map<int, DayAgg> byDay;
  final MonthSummary summary;
  final int dailyAvgExpenseCents;

  /// 整月聚合是否已经到手（没到手时汇总条显示「—」，不挡住网格）。
  final bool ready;

  /// 高亮的日子；0 = 不高亮（预览页、或选中日不在本月）。
  final int selectedDay;

  /// 预览页不传这两个回调：它只负责被看见，不响应点按。
  final ValueChanged<int>? onSelectDay;
  final ValueChanged<DateTime>? onLongPressDay;

  @override
  Widget build(BuildContext context) {
    final ValueChanged<int>? select = onSelectDay;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          // 原型 `.cal { padding: 6px 8px 0 }`
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: MonthGrid(
            year: year,
            month: month,
            byDay: byDay,
            selectedDay: selectedDay,
            onSelectDay: select ?? (int _) {},
            // F7.7 E 批：长按某天 → 直接记这一天的账（顺带把那天选中，
            // 回来就能看到刚记的那笔）；左右拖动 → 翻月（由外面那层管手势）
            onLongPressDay: onLongPressDay,
          ),
        ),
        // 网格与月结余卡之间不再另加间距：原型是 `.day` 的 2px 外边距
        // + `.summary-bar` 的 10px margin（= 12px），由卡的 margin 承担。
        _SummaryBar(
          summary: summary,
          dailyAvgExpenseCents: dailyAvgExpenseCents,
          ready: ready,
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

/// 顶部栏：左侧侧面栏（抽屉）+ 中间年月（点开月份选择子页）+ 报表(建设中) + 统计。
///
/// 日历页 header 用的是原型 `.hdr`（不是 `.appbar`），所以图标是**带框**的。
class _HeaderBody extends ConsumerWidget {
  const _HeaderBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final int year = ref.watch(
      calendarProvider.select((CalendarState s) => s.year),
    );
    final int month = ref.watch(
      calendarProvider.select((CalendarState s) => s.month),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: Row(
        children: <Widget>[
          ToonIconButton(
            icon: Icons.menu_rounded,
            tooltip: '账本',
            boxed: true,
            onPressed: () => Scaffold.maybeOf(context)?.openDrawer(),
          ),
          Expanded(
            child: Center(
              child: ToonPress(
                dx: 0,
                dy: 0,
                onTap: () => context.push('/month-picker'),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        '$year年$month月',
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(width: 2),
                      const Icon(Icons.keyboard_arrow_down_rounded, size: 20),
                    ],
                  ),
                ),
              ),
            ),
          ),
          ToonIconButton(
            icon: Icons.receipt_long_rounded,
            tooltip: '报表',
            boxed: true,
            // 「明细」档 + 月份对齐日历页当前月（SPEC-F7.7 §A.2.3）
            onPressed: () => context.push(
              '/reports',
              extra: ReportsArgs(
                tab: kReportTabDetail,
                year: year,
                month: month,
              ),
            ),
          ),
          ToonIconButton(
            icon: Icons.pie_chart_outline_rounded,
            tooltip: '统计',
            boxed: true,
            onPressed: () => context.push('/stats'),
          ),
        ],
      ),
    );
  }
}

/// 月结余 + 日均支出。
///
/// 整月聚合是**第二段数据**：还没回来时显示「—」，不挡住网格。
class _SummaryBar extends StatelessWidget {
  const _SummaryBar({
    required this.summary,
    required this.dailyAvgExpenseCents,
    required this.ready,
  });

  final MonthSummary summary;
  final int dailyAvgExpenseCents;
  final bool ready;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    final int balance = summary.balanceCents;
    final Color balanceColor = balance < 0
        ? p.red
        : balance > 0
        ? p.green
        : p.ink;
    return Container(
      // 原型 `.summary-bar { margin: 10px 16px; padding: 13px 16px }`
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      decoration: p.cardDeco(),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          _SummaryItem(
            label: '月结余',
            value: ready ? centsToYuan(balance) : '—',
            valueColor: balanceColor,
          ),
          _SummaryItem(
            label: '日均支出',
            value: ready ? centsToYuan(dailyAvgExpenseCents) : '—',
            valueColor: p.red,
          ),
        ],
      ),
    );
  }
}

class _SummaryItem extends StatelessWidget {
  const _SummaryItem({
    required this.label,
    required this.value,
    required this.valueColor,
  });

  final String label;
  final String value;
  final Color valueColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: <Widget>[
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          value,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: valueColor,
          ),
        ),
      ],
    );
  }
}

/// 选中日期的账单区：日期头 + 账单列表 / 空态 / 加载占位。
///
/// 日期头跟的是**选中日**（`state.selectedDate`），翻月不会变 —— 这是任务书第 3 条。
/// F7.8：删除入口改为**左滑露出按钮**，单开协调器由本 State 持有。
class _SelectedDaySection extends StatefulWidget {
  const _SelectedDaySection({
    required this.state,
    required this.categoryNameOf,
    required this.onEdit,
    required this.onDelete,
  });

  final CalendarState state;
  final String Function(String?) categoryNameOf;
  final ValueChanged<TxRow> onEdit;

  /// 点左滑动作区后执行（内部弹确认框）；Future 完成即收起该行。
  final Future<void> Function(TxRow) onDelete;

  @override
  State<_SelectedDaySection> createState() => _SelectedDaySectionState();
}

class _SelectedDaySectionState extends State<_SelectedDaySection> {
  /// 当前展开（左滑露出删除按钮）的行 id —— 单开协调器。
  final ValueNotifier<String?> _openRow = ValueNotifier<String?>(null);

  @override
  void dispose() {
    _openRow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    final CalendarState state = widget.state;
    // ⚠️ 用选中日的完整日期，不是「可见年月 + 选中日号」
    //    （翻到 9 月时这里仍然是 10月12日）
    final DateTime day = DateTime(
      state.selectedDate.year,
      state.selectedDate.month,
      state.selectedDate.day,
    );
    final List<TxRow> items = state.selectedItems;
    final int dayExpenseCents = items
        .where((TxRow t) => t.type == 'expense')
        .fold(0, (int a, TxRow t) => a + t.amountCents);
    final bool loading = state.day.isLoading;

    return Column(
      // stretch（不是 start）：空态块自己只有「最宽子项」那么宽，
      // 用 start 会被顶到左边 —— 它内部的居中就成了「块内居中、整块偏左」。
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
          child: Row(
            children: <Widget>[
              // 原型 `.dayhead .bar`：品牌色小圆点（不是竖条）
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: p.brand,
                  shape: BoxShape.circle,
                  border: Border.all(color: p.ink, width: 2),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _dayHeader(day),
                style: const TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const Spacer(),
              if (!loading)
                Text(
                  '${items.length} 笔 · 支出 ¥${centsToYuan(dayExpenseCents)}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: p.ink2,
                  ),
                ),
            ],
          ),
        ),
        if (loading)
          _DayLoadingPlaceholder()
        else if (state.day.hasError)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Text(
              '账单加载失败：${state.day.error}',
              style: TextStyle(fontSize: 12.5, color: p.redInk),
            ),
          )
        else if (items.isEmpty)
          _EmptyDay(dayMs: state.selectedDayMs)
        else
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: <Widget>[
                for (int i = 0; i < items.length; i++)
                  Column(
                    children: <Widget>[
                      if (i > 0) const ToonDashedLine(),
                      SwipeActionRow(
                        key: ValueKey<String>('swipe-${items[i].id}'),
                        rowId: items[i].id,
                        openRow: _openRow,
                        onAction: () => widget.onDelete(items[i]),
                        child: TxTile(
                          tx: items[i],
                          categoryName: widget.categoryNameOf(
                            items[i].categoryId,
                          ),
                          onTap: () => widget.onEdit(items[i]),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
      ],
    );
  }

  /// 「今天 9月11日 周五」/「昨天 …」/「2025年12月3日 周三」。
  String _dayHeader(DateTime d) {
    final DateTime now = DateTime.now();
    final String core = '${d.month}月${d.day}日 ${weekdayLabel(d)}';
    final bool isToday =
        d.year == now.year && d.month == now.month && d.day == now.day;
    if (isToday) return '今天 $core';
    final DateTime yesterday = DateTime(now.year, now.month, now.day - 1);
    final bool isYesterday =
        d.year == yesterday.year &&
        d.month == yesterday.month &&
        d.day == yesterday.day;
    if (isYesterday) return '昨天 $core';
    return d.year == now.year ? core : '${d.year}年$core';
  }
}

/// 账单段加载中的轻量占位（**不是整页转圈**：网格已经在那儿了）。
class _DayLoadingPlaceholder extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 26),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: p.ink3),
          ),
          const SizedBox(width: 8),
          Text(
            '正在加载这天的账单…',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: p.ink3,
            ),
          ),
        ],
      ),
    );
  }
}

/// 当天没有账单时的空态 + 「记一笔」（默认日期 = 选中日）。
///
/// 原型 `.empty-block`：虚线圆底里放小猪 + 两行文案 + tonal 按钮。
class _EmptyDay extends StatelessWidget {
  const _EmptyDay({required this.dayMs});

  final int dayMs;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    return Padding(
      padding: const EdgeInsets.fromLTRB(26, 14, 26, 30),
      child: Column(
        children: <Widget>[
          ToonDashedBorder(
            circle: true,
            color: p.ink,
            thickness: Tok.bw,
            dash: 7,
            gap: 5,
            background: p.brandTint,
            child: SizedBox(
              width: 76,
              height: 76,
              child: Center(
                child: Icon(
                  Icons.calendar_today_rounded,
                  size: 32,
                  color: p.brandInk,
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            '这天没有账单哦，赶紧记一笔吧~',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            '长按日历里任意一天，也能直接记这一天的账',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: p.ink2,
            ),
          ),
          const SizedBox(height: 16),
          ToonButton(
            label: '记一笔',
            icon: Icons.add,
            kind: ToonButtonKind.tonal,
            small: true,
            onPressed: () => context.push('/record?date=$dayMs'),
          ),
        ],
      ),
    );
  }
}
