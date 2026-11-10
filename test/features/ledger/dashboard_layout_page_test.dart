/// P5 · 首页布局页的三种参数控件（树形二级行）。
///
/// 树的规矩不变：**父模块不展开就看不到子项**；展开后按参数类型渲染
/// 开关 / 几选一 chips / 步进器，且改动要立刻落进 `dashboardConfigProvider`。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/core/theme/palette.dart';
import 'package:yanxin/core/theme/tokens.dart';
import 'package:yanxin/data/providers/database.dart';
import 'package:yanxin/features/ledger/presentation/dashboard/dashboard_config.dart';
import 'package:yanxin/features/ledger/presentation/dashboard/dashboard_config_controller.dart';
import 'package:yanxin/features/ledger/presentation/dashboard/dashboard_layout_page.dart';

import '../../helpers/test_database.dart';

Future<ProviderContainer> _pump(WidgetTester tester) async {
  final AppDatabase db = openTestDatabase();
  addTearDown(db.close);
  final ProviderContainer container = ProviderContainer(
    overrides: [appDatabaseProvider.overrideWithValue(db)],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildToonTheme(ToonPalette.light, Brightness.light),
        home: const DashboardLayoutPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

DashboardConfig _configOf(ProviderContainer c) =>
    c.read(dashboardConfigProvider).value ?? DashboardConfig.defaults;

void main() {
  testWidgets('不展开父模块时看不到内部组件；展开后才出现', (WidgetTester tester) async {
    await _pump(tester);

    expect(find.text('副行显示'), findsNothing);
    expect(find.text('示例条数'), findsNothing);

    await tester.tap(find.byKey(const ValueKey<String>('dashboard_expand_budget_strip')));
    await tester.pumpAndSettle();

    expect(find.text('副行显示'), findsOneWidget);
    expect(find.text('还剩'), findsOneWidget);
    expect(find.text('已花'), findsOneWidget);
  });

  testWidgets('几选一：点 chip 立即生效并落库', (WidgetTester tester) async {
    final ProviderContainer c = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey<String>('dashboard_expand_budget_strip')));
    await tester.pumpAndSettle();

    expect(_configOf(c).params?['budget_strip']?['detail'], isNull, reason: '初始未配置');

    await tester.tap(
      find.byKey(const ValueKey<String>('dashboard_param_budget_strip_detail_spent')),
    );
    await tester.pumpAndSettle();

    expect(_configOf(c).params?['budget_strip']?['detail'], 'spent');
  });

  testWidgets('步进器：减一 / 加一都写入，到边界按钮不可点', (WidgetTester tester) async {
    final ProviderContainer c = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey<String>('dashboard_expand_chat_entry')));
    await tester.pumpAndSettle();

    // 默认 3（= max），此时「加」不可点
    expect(
      _configOf(c).params?['chat_entry']?['sample_count'],
      isNull,
      reason: '未配置时读默认值，不写库',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('dashboard_param_chat_entry_sample_count_minus')),
    );
    await tester.pumpAndSettle();
    expect(_configOf(c).params?['chat_entry']?['sample_count'], 2);

    await tester.tap(
      find.byKey(const ValueKey<String>('dashboard_param_chat_entry_sample_count_plus')),
    );
    await tester.pumpAndSettle();
    expect(_configOf(c).params?['chat_entry']?['sample_count'], 3);
  });

  testWidgets('账单条数：全部 / 10 / 20 三个 chip', (WidgetTester tester) async {
    final ProviderContainer c = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey<String>('dashboard_expand_tx_list')));
    await tester.pumpAndSettle();

    expect(find.text('全部'), findsOneWidget);
    expect(find.text('10'), findsOneWidget);
    expect(find.text('20'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('dashboard_param_tx_list_limit_10')),
    );
    await tester.pumpAndSettle();
    expect(_configOf(c).params?['tx_list']?['limit'], '10');
  });
}
