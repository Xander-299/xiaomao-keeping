/// 月历网格：表头「日一二三四五六」+ 日期格（日期下方标当天支出/收入）。
///
/// 视觉参考 docs/design/calendar.jpg：有支出的格子给淡红底，今天用品牌色，
/// 选中日用品牌色描边。金额为紧凑写法（-23.1 / +20.8）。
library;

import 'package:flutter/material.dart';

import 'package:yanxin/core/theme/palette.dart';
import 'package:yanxin/core/theme/tokens.dart';
import 'package:yanxin/core/utils/date.dart';
import 'package:yanxin/features/calendar/application/calendar_aggregate.dart';

/// 月历网格。
class MonthGrid extends StatelessWidget {
  const MonthGrid({
    super.key,
    required this.year,
    required this.month,
    required this.byDay,
    required this.selectedDay,
    required this.onSelectDay,
    this.onLongPressDay,
    this.now,
    this.maxDate,
  });

  final int year;

  /// 1-12。
  final int month;

  /// 按「当月第几天」聚合的收支（跨月格子不显示金额）。
  final Map<int, DayAgg> byDay;

  final int selectedDay;

  final ValueChanged<int> onSelectDay;

  /// 长按某个**在当月且可选**的格子（F7.7 E 批）。传空 = 不响应长按。
  ///
  /// 传的是该格子的本地 0 点 [DateTime]，调用方自己决定怎么用
  /// （日历页用它直接进「记一笔」并带上这一天）。
  final ValueChanged<DateTime>? onLongPressDay;

  /// 覆盖「今天」（测试注入用；为空取真实当前时间）。
  final DateTime? now;

  /// 晚于该日期的格子灰显且不可点（原型 calGrid 的 `disableFuture`；
  /// 记一笔选日期用它挡住「记未来的账」）。为空 = 全部可选。
  final DateTime? maxDate;

  @override
  Widget build(BuildContext context) {
    final DateTime today = now ?? DateTime.now();
    final int leading = DateTime(year, month, 1).weekday % 7; // 周日起始
    final int total = daysInMonth(year, month);
    // **固定 6 行**：翻页时两页必须一样高，否则下面的账单区会被顶一下。
    // 多出来的格子是相邻月的灰日期（与「月初补格」同一套画法），看起来就是
    // 完整的一页月历，而不是一块空白。
    const int kRows = 6;
    final int natural = ((leading + total) / 7).ceil();
    final int rows = natural < kRows ? kRows : natural;

    final Widget grid = Column(
      children: <Widget>[
        Row(
          children: <Widget>[
            for (final String w in weekdayHeaders)
              Expanded(
                child: Center(
                  child: Text(
                    w,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        for (int r = 0; r < rows; r++)
          Row(
            children: <Widget>[
              for (int c = 0; c < 7; c++)
                Expanded(
                  child: _buildCell(
                    context,
                    // DateTime 的日号溢出/为 0 时会自动落到相邻月，正好用于补格
                    date: DateTime(year, month, 1 - leading + r * 7 + c),
                    today: today,
                  ),
                ),
            ],
          ),
      ],
    );

    return grid;
  }

  Widget _buildCell(
    BuildContext context, {
    required DateTime date,
    required DateTime today,
  }) {
    final ToonPalette p = context.toon;
    final bool inMonth = date.month == month && date.year == year;
    final bool isToday =
        date.year == today.year &&
        date.month == today.month &&
        date.day == today.day;
    final DayAgg? agg = inMonth ? byDay[date.day] : null;
    final bool selected = inMonth && date.day == selectedDay;
    final DateTime? limit = maxDate;
    final bool disabled =
        limit != null &&
        DateTime(date.year, date.month, date.day).isAfter(
          DateTime(limit.year, limit.month, limit.day),
        );

    // 原型 `.day.tint-e / .tint-i`：支出优先于收入；`.day.sel` 写在后面
    // 覆盖 tint 底色 → 选中日一定是品牌浅底 + 墨色描边 + 硬阴影。
    final Color? cellBg = selected
        ? p.brandTint
        : agg == null
        ? null
        : agg.hasExpense
        ? p.redTint
        : agg.hasIncome
        ? p.greenTint
        : null;

    return InkWell(
      onTap: inMonth && !disabled ? () => onSelectDay(date.day) : null,
      // 长按只对「在当月且可选」的格子生效（跨月补格 / 未来格与点击同口径）
      onLongPress: inMonth && !disabled && onLongPressDay != null
          ? () => onLongPressDay!(date)
          : null,
      borderRadius: BorderRadius.circular(Tok.rSm),
      child: Opacity(
        // 跨月格子与「超过上限」的格子（原型 `.day.out` / `disableFuture`）
        opacity: inMonth && !disabled ? 1 : 0.3,
        child: Container(
          height: 62,
          margin: const EdgeInsets.all(2),
          padding: const EdgeInsets.fromLTRB(2, 5, 2, 4),
          decoration: BoxDecoration(
            color: cellBg,
            borderRadius: BorderRadius.circular(Tok.rSm),
            border: Border.all(
              color: selected ? p.ink : Colors.transparent,
              width: 2,
            ),
            // 选中态给硬阴影（原型 `.day.sel` 的 `--sh-sm`）
            boxShadow: selected ? p.hard(d: 2.5) : null,
          ),
          child: Column(
            children: <Widget>[
              // 固定 24 高：今天要从文字变成圆底，不固定会让整行跳一下
              SizedBox(
                width: 24,
                height: 24,
                child: Center(
                  child: isToday
                      ? Container(
                          width: 24,
                          height: 24,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: p.brand,
                            shape: BoxShape.circle,
                            // 同上：brand 底 → 描边跟着底色走
                            border: p.inkBorder(w: 2, on: p.brand),
                          ),
                          child: _dayNumber(date, p, isToday: true),
                        )
                      : _dayNumber(date, p, isToday: false),
                ),
              ),
              const Spacer(),
              if (inMonth && agg != null) ...<Widget>[
                if (agg.hasExpense)
                  _amountText('-${compactYuan(agg.expenseCents)}', p.red),
                if (agg.hasIncome)
                  _amountText('+${compactYuan(agg.incomeCents)}', p.green),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 日期数字：今天用品牌深色 + 900 字重（原型 `.day.today .dnum`）。
  Widget _dayNumber(DateTime date, ToonPalette p, {required bool isToday}) =>
      Text(
    '${date.day}',
    style: TextStyle(
      fontSize: 13,
      height: 1.1,
      fontWeight: isToday ? FontWeight.w900 : FontWeight.w800,
      color: isToday ? p.onBrand : p.ink,
    ),
  );

  Widget _amountText(String text, Color color) => FittedBox(
    child: Text(
      text,
      maxLines: 1,
      style: TextStyle(
        fontSize: 9,
        height: 1.25,
        fontWeight: FontWeight.w800,
        color: color,
      ),
    ),
  );
}
