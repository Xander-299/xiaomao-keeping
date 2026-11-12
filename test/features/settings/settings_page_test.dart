/// 设置页 → 外观三选一（F7.17）。
///
/// 断言靠**行 key**（`themeMode_<name>`）而不是文本：标题「深色」是副标题
/// 「一直使用深色」的子串，按文本找会命中两处。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/core/theme/palette.dart';
import 'package:yanxin/core/theme/theme_mode.dart';
import 'package:yanxin/core/theme/theme_seed.dart';
import 'package:yanxin/core/theme/tokens.dart';
import 'package:yanxin/data/providers/database.dart';
import 'package:yanxin/data/repositories/app_meta_repository.dart';
import 'package:yanxin/features/settings/application/theme_controller.dart';
import 'package:yanxin/features/settings/presentation/settings_page.dart';

import '../../helpers/test_database.dart';

Key rowKey(ToonThemeMode m) => ValueKey<String>('themeMode_${m.name}');

/// 主题色圆点的 key（`themeSeed_<name>`）。
Key seedKey(ToonSeed s) => ValueKey<String>('themeSeed_${s.name}');

/// 当前选中态（实心对勾）落在哪一行。
Finder selectedMark(ToonThemeMode m) => find.descendant(
  of: find.byKey(rowKey(m)),
  matching: find.byIcon(Icons.check_circle_rounded),
);

Future<void> pumpSettings(WidgetTester tester, AppDatabase db) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
      child: MaterialApp(
        theme: buildToonTheme(ToonPalette.light, Brightness.light),
        darkTheme: buildToonTheme(ToonPalette.dark, Brightness.dark),
        home: const SettingsPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 等写库完成（真实异步，pumpAndSettle 可能抢先返回）→ 轮询 KV。
Future<String?> pumpUntilStored(WidgetTester tester, AppDatabase db) async {
  String? value;
  for (int i = 0; i < 20 && value == null; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    value = await AppMetaRepository(db).get(kThemeModeKey);
  }
  return value;
}

/// 同上，读主题色那个键。
Future<String?> pumpUntilSeedStored(WidgetTester tester, AppDatabase db) async {
  String? value;
  for (int i = 0; i < 20 && value == null; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    value = await AppMetaRepository(db).get(kThemeSeedKey);
  }
  return value;
}

void main() {
  testWidgets('界面外观：一张卡片进一页，外观模式三行都在，默认选中「浅色」', (
    WidgetTester tester,
  ) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    await pumpSettings(tester, db);

    // 2026-11-13：外观模式与主题色合并成**一张卡片**（「界面外观」），副标题显示当前两项的值
    expect(find.text('界面外观'), findsOneWidget);
    expect(find.text('外观模式'), findsNothing, reason: '不再是独立入口卡片');
    expect(find.text('浅色 · 琥珀 主题色'), findsOneWidget);

    await tester.tap(find.text('界面外观'));
    await tester.pumpAndSettle();

    for (final ToonThemeMode m in ToonThemeMode.values) {
      expect(find.byKey(rowKey(m)), findsOneWidget);
      expect(find.text(m.label), findsWidgets);
    }
    // 只有一行有实心对勾 = 单选
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    expect(selectedMark(ToonThemeMode.light), findsOneWidget);
    expect(selectedMark(ToonThemeMode.system), findsNothing);
    expect(selectedMark(ToonThemeMode.dark), findsNothing);
  });

  testWidgets('点「深色」→ 选中态立刻切过去并落库', (WidgetTester tester) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    await pumpSettings(tester, db);
    await tester.tap(find.text('界面外观'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(rowKey(ToonThemeMode.dark)));
    await tester.pumpAndSettle();

    expect(selectedMark(ToonThemeMode.dark), findsOneWidget);
    expect(selectedMark(ToonThemeMode.light), findsNothing);

    expect(await pumpUntilStored(tester, db), 'dark');
  });

  testWidgets('冷启动沿用上次选择：库里是 dark 就选中深色', (WidgetTester tester) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    await AppMetaRepository(db).set(kThemeModeKey, 'dark');

    await pumpSettings(tester, db);
    await tester.tap(find.text('界面外观'));
    await tester.pumpAndSettle();
    expect(selectedMark(ToonThemeMode.dark), findsOneWidget);
    expect(selectedMark(ToonThemeMode.light), findsNothing);
  });

  // 2026-10-29：主题色（seed）切换
  testWidgets('主题色子页：五个色点都在，默认选中琥珀；点森绿 → 选中态 + 落库', (
    WidgetTester tester,
  ) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    await pumpSettings(tester, db);

    // 同一张「界面外观」页里，外观模式下面就是主题色（不再是独立子页）
    await tester.tap(find.text('界面外观'));
    await tester.pumpAndSettle();

    expect(find.text('主题色'), findsWidgets);
    for (final ToonSeed s in ToonSeed.values) {
      expect(find.byKey(seedKey(s)), findsOneWidget, reason: '缺色点：${s.label}');
    }
    // 默认琥珀：只有它带对勾
    expect(find.descendant(of: find.byKey(seedKey(ToonSeed.amber)), matching: find.byIcon(Icons.check_rounded)), findsOneWidget);
    expect(find.descendant(of: find.byKey(seedKey(ToonSeed.forest)), matching: find.byIcon(Icons.check_rounded)), findsNothing);

    await tester.tap(find.byKey(seedKey(ToonSeed.forest)));
    await tester.pumpAndSettle();

    expect(find.descendant(of: find.byKey(seedKey(ToonSeed.forest)), matching: find.byIcon(Icons.check_rounded)), findsOneWidget);
    expect(find.descendant(of: find.byKey(seedKey(ToonSeed.amber)), matching: find.byIcon(Icons.check_rounded)), findsNothing);

    expect(await pumpUntilSeedStored(tester, db), 'forest');
  });
}
