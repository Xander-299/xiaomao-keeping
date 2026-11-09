/// 统计页：分类占比（圆环）+ 近 6 月收支趋势 + 当月汇总。
///
/// 入口：首页 header 的「统计」图标 → `/stats`。月份与首页/日历**各自独立**。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:yanxin/core/theme/toon.dart';
import 'package:yanxin/core/utils/money.dart';
import 'package:yanxin/features/ledger/application/ledger_controller.dart';
import 'package:yanxin/features/ledger/application/month_summary.dart';
import 'package:yanxin/ui_kit/app_page_state.dart';

import '../application/stats_aggregate.dart';
import '../application/stats_controller.dart';
import 'widgets/category_pie.dart';
import 'widgets/trend_bars.dart';

/// 统计页。
class StatsPage extends ConsumerWidget {
  const StatsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(statsProvider);
    final StatsState? state = async.value;

    return Scaffold(
      appBar: AppBar(title: const Text('统计')),
      // 翻月时不再闪转圈（controller 不切 loading），这里加一层淡入淡出，
      // 让「月份 × 图表」整体换得柔和一点；key 只看年月，切「支出/收入」不触发换页动画。
      body: state == null
          ? (async.hasError
                ? AppPageError(error: async.error ?? '未知错误')
                : const AppPageLoading())
          : AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: _StatsBody(
                key: ValueKey<String>('${state.year}-${state.month}'),
                state: state,
              ),
            ),
    );
  }
}

/// 统计页内容（按月重绘）。
class _StatsBody extends ConsumerWidget {
  const _StatsBody({super.key, required this.state});

  final StatsState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: <Widget>[
        _MonthBar(
          year: state.year,
          month: state.month,
          onPrev: () => ref.read(statsProvider.notifier).shiftMonth(-1),
          onNext: () => ref.read(statsProvider.notifier).shiftMonth(1),
        ),
        const SizedBox(height: 12),
        _SummaryCard(summary: state.summary),
        const SizedBox(height: 12),
        _BreakdownCard(
          state: state,
          onKindChanged: (String kind) =>
              ref.read(statsProvider.notifier).setKind(kind),
        ),
        const SizedBox(height: 12),
        _TrendCard(state: state),
      ],
    );
  }
}

/// 月份切换条（‹ 2026年9月 ›），与首页一致的「不能超过当前月」约束。
class _MonthBar extends StatelessWidget {
  const _MonthBar({
    required this.year,
    required this.month,
    required this.onPrev,
    required this.onNext,
  });

  final int year;
  final int month;
  final VoidCallback onPrev;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        ToonIconButton(
          icon: Icons.chevron_left_rounded,
          tooltip: '上一月',
          onPressed: onPrev,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            '$year年$month月',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
          ),
        ),
        // 不能翻到未来月：禁用态用三级灰（原型 `iconbtn muted` + opacity .35）
        ToonIconButton(
          icon: Icons.chevron_right_rounded,
          tooltip: '下一月',
          muted: !canGoNext(year, month),
          onPressed: canGoNext(year, month) ? onNext : null,
        ),
      ],
    );
  }
}

/// 当月收支汇总卡。
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.summary});

  final MonthSummary summary;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: <Widget>[
            Expanded(
              child: _StatCell(
                label: '收入',
                value: summary.incomeYuan,
                color: p.green,
              ),
            ),
            Expanded(
              child: _StatCell(
                label: '支出',
                value: summary.expenseYuan,
                color: p.red,
              ),
            ),
            Expanded(
              child: _StatCell(
                label: '结余',
                value: summary.balanceYuan,
                color: p.brandDeep,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatCell extends StatelessWidget {
  const _StatCell({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        ToonFadeValue(
          value: value,
          child: Text(
            value,
            style: TextStyle(
              fontSize: 17.5,
              fontWeight: FontWeight.w900,
              color: color,
            ),
          ),
        ),
      ],
    );
  }
}

/// 分类占比卡：支出/收入切换 + 圆环 + 图例。
class _BreakdownCard extends StatelessWidget {
  const _BreakdownCard({required this.state, required this.onKindChanged});

  final StatsState state;
  final ValueChanged<String> onKindChanged;

  @override
  Widget build(BuildContext context) {
    final slices = state.slices;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Text(
                  '分类占比',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                // key 保给测试用（stats_page_test 依赖它定位切换器）
                ToonSeg(
                  key: const ValueKey<String>('stats-kind-toggle'),
                  labels: const <String>['支出', '收入'],
                  index: state.kind == 'income' ? 1 : 0,
                  small: true,
                  onChanged: (int i) =>
                      onKindChanged(i == 1 ? 'income' : 'expense'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (slices.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 18),
                child: Center(
                  child: Text(
                    state.kind == 'income'
                        ? '${state.year}年${state.month}月还没有收入记录'
                        : '${state.year}年${state.month}月还没有支出记录',
                    style: TextStyle(fontSize: 13, color: muted),
                  ),
                ),
              )
            else
              Row(
                children: <Widget>[
                  CategoryPie(slices: slices),
                  const SizedBox(width: 18),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        for (var i = 0; i < slices.length; i++)
                          _LegendRow(slice: slices[i], color: categoryColor(i)),
                      ],
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// 图例一行：色块 + 分类名 + 占比 + 金额。
class _LegendRow extends StatelessWidget {
  const _LegendRow({required this.slice, required this.color});

  final CategorySlice slice;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: <Widget>[
          // 原型 `.legend-row .dot`：10px 圆 + 2px 墨色描边
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: p.ink, width: 2),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              slice.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            ),
          ),
          ToonFadeValue(
            value: slice.percentText,
            child: Text(
              slice.percentText,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: muted,
              ),
            ),
          ),
          SizedBox(
            width: 78,
            child: ToonFadeValue(
              value: centsToYuan(slice.cents, group: true),
              child: Text(
                centsToYuan(slice.cents, group: true),
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 近 6 个月趋势卡。
class _TrendCard extends StatelessWidget {
  const _TrendCard({required this.state});

  final StatsState state;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Text(
                  '近 6 个月趋势',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                _Dot(color: p.red, label: '支出', muted: muted),
                const SizedBox(width: 12),
                _Dot(color: p.green, label: '收入', muted: muted),
              ],
            ),
            const SizedBox(height: 14),
            TrendBars(points: state.trend, anchorYear: state.year),
          ],
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color, required this.label, required this.muted});

  final Color color;
  final String label;
  final Color muted;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: p.ink, width: 2),
          ),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: muted,
          ),
        ),
      ],
    );
  }
}
