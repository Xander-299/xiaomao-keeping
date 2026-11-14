/// 月历翻页的布局前提：**每一页一样高**。
///
/// 跟手翻页时两页会同时在场；如果 5 行月与 6 行月高度不同，
/// 翻页途中下面的账单区就会被顶一下（或者被裁掉最后一周）。
/// 所以网格固定按 6 行的高度出图，少的那几行补**空白**（不是相邻月的灰日期）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanxin/core/theme/palette.dart';
import 'package:yanxin/core/theme/tokens.dart';
import 'package:yanxin/features/calendar/application/calendar_aggregate.dart';
import 'package:yanxin/features/calendar/presentation/widgets/month_grid.dart';

Future<double> _heightOf(WidgetTester tester, int year, int month) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildToonTheme(ToonPalette.light, Brightness.light),
      home: Scaffold(
        body: MonthGrid(
          year: year,
          month: month,
          byDay: const <int, DayAgg>{},
          selectedDay: 1,
          onSelectDay: (int _) {},
        ),
      ),
    ),
  );
  return tester.getSize(find.byType(MonthGrid)).height;
}

void main() {
  testWidgets('5 行月与 6 行月同高（翻页时下面内容不被顶动）', (WidgetTester tester) async {
    // 2026-11：11 月 1 日是周日 + 30 天 = 正好 5 行
    final double five = await _heightOf(tester, 2026, 11);
    // 2026-08：8 月 1 日是周六 + 31 天 = 6 行
    final double six = await _heightOf(tester, 2026, 8);
    expect(five, closeTo(six, 0.01), reason: '两页高度必须一致，否则翻页会跳');
  });
}
