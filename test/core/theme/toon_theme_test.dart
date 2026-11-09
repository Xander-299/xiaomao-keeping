/// 深浅两套主题真的能从 `BuildContext` 解析出来（F7.17 的根基）。
///
/// 之前色值是 `Tok.*` 编译期常量，换 `themeMode` 不生效；改成 `ThemeExtension`
/// 后必须证明：**同一个 widget 树，拿到的是当前那套调色板**。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/core/theme/palette.dart';
import 'package:yanxin/core/theme/theme_seed.dart';
import 'package:yanxin/core/theme/tokens.dart';

/// 起一棵只有 [themeMode] 不同的树，返回根 context 解析到的调色板。
Future<ToonPalette> pumpAndRead(
  WidgetTester tester,
  ThemeMode mode, {
  Brightness platformBrightness = Brightness.light,
}) async {
  tester.platformDispatcher.platformBrightnessTestValue = platformBrightness;
  ToonPalette? read;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildToonTheme(ToonPalette.light, Brightness.light),
      darkTheme: buildToonTheme(ToonPalette.dark, Brightness.dark),
      themeMode: mode,
      home: Builder(
        builder: (BuildContext context) {
          read = context.toon;
          return const SizedBox();
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  return read!;
}

void main() {
  tearDown(() {
    // 改的是全局单例，漏了会污染同文件后续用例
    TestWidgetsFlutterBinding.instance.platformDispatcher
        .clearPlatformBrightnessTestValue();
  });

  testWidgets('light / dark 各自拿到对应调色板', (WidgetTester tester) async {
    expect((await pumpAndRead(tester, ThemeMode.light)).canvas, ToonPalette.light.canvas);
    expect((await pumpAndRead(tester, ThemeMode.dark)).canvas, ToonPalette.dark.canvas);
  });

  testWidgets('深浅不是「换个底色」就算：文字 / 纸色 / 分割线都不同', (
    WidgetTester tester,
  ) async {
    final ToonPalette light = await pumpAndRead(tester, ThemeMode.light);
    final ToonPalette dark = await pumpAndRead(tester, ThemeMode.dark);

    expect(dark.ink, isNot(light.ink)); // 文字反色
    expect(dark.paper, isNot(light.paper));
    expect(dark.canvas, isNot(light.canvas));
    // M3 的 outlineVariant 在深浅两套里也不同（分割线要跟着表面走）
    expect(dark.line, isNot(light.line));
    // M3 的 shadow 两套都是纯黑（阴影只由 elevation 决定），不再断言它区分深浅
    expect(dark.shadow, const Color(0xFF000000));
  });

  testWidgets('跟随系统：系统切深色，App 解析到的就是深色', (WidgetTester tester) async {
    expect(
      (await pumpAndRead(tester, ThemeMode.system, platformBrightness: Brightness.light))
          .canvas,
      ToonPalette.light.canvas,
    );
    expect(
      (await pumpAndRead(tester, ThemeMode.system, platformBrightness: Brightness.dark))
          .canvas,
      ToonPalette.dark.canvas,
    );
  });

  testWidgets('没注册主题时回落浅色（裸 MaterialApp 不炸）', (WidgetTester tester) async {
    ToonPalette? read;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) {
            read = context.toon;
            return const SizedBox();
          },
        ),
      ),
    );
    expect(read!.canvas, ToonPalette.light.canvas);
  });

  // 2026-10-29：主题色可切换（设置页五选一）—— 换 seed 必须真的换色板
  group('主题色（seed）', () {
    test('不同 seed 给出不同品牌色；饼图首瓣跟品牌色走', () {
      final ToonPalette amber = ToonPalette.lightOf(ToonSeed.amber);
      final ToonPalette forest = ToonPalette.lightOf(ToonSeed.forest);
      expect(forest.brand, isNot(amber.brand));
      expect(forest.pie.first, forest.brand);
      expect(amber.pie.first, amber.brand);
    });

    test('按 seed 缓存：取两次是同一个实例（fromSeed 不便宜，别在 build 里重算）', () {
      expect(
        identical(
          ToonPalette.lightOf(ToonSeed.rose),
          ToonPalette.lightOf(ToonSeed.rose),
        ),
        isTrue,
      );
      expect(
        identical(
          ToonPalette.darkOf(ToonSeed.rose),
          ToonPalette.lightOf(ToonSeed.rose),
        ),
        isFalse,
      );
    });

    test('默认 light/dark 是琥珀（2026-11-10 改默认品牌色）', () {
      expect(ToonPalette.light.brand, ToonPalette.lightOf(ToonSeed.amber).brand);
      expect(ToonPalette.dark.brand, ToonPalette.darkOf(ToonSeed.amber).brand);
    });
  });
}
