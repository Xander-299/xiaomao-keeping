/// UI Kit 公共组件：页面状态 / 弹层头部 / 设置条目。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/core/theme/palette.dart';
import 'package:yanxin/core/theme/tokens.dart';
import 'package:yanxin/ui_kit/app_page_state.dart';
import 'package:yanxin/ui_kit/app_settings_tile.dart';
import 'package:yanxin/ui_kit/app_sheet_header.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: buildToonTheme(ToonPalette.light, Brightness.light),
  home: Scaffold(body: child),
);

void main() {
  testWidgets('AppPageLoading 显示转圈', (WidgetTester tester) async {
    await tester.pumpWidget(_wrap(const AppPageLoading()));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('AppPageError 保持旧文案口径', (WidgetTester tester) async {
    await tester.pumpWidget(_wrap(const AppPageError(error: 'boom')));
    expect(find.text('加载失败：boom'), findsOneWidget);
  });

  testWidgets('AppSheetHeader 渲染抓手 / 标题 / 副标题', (WidgetTester tester) async {
    await tester.pumpWidget(
      _wrap(
        const AppSheetHeader(
          title: '设置预算',
          subtitle: '用于在首页看到本月花销进度',
        ),
      ),
    );

    expect(find.text('设置预算'), findsOneWidget);
    expect(find.text('用于在首页看到本月花销进度'), findsOneWidget);
  });

  testWidgets('AppSettingsTile 可点并显示副标题', (WidgetTester tester) async {
    int taps = 0;
    await tester.pumpWidget(
      _wrap(
        AppSettingsTile(
          icon: Icons.tune_rounded,
          title: '设置',
          subtitle: '外观主题',
          onTap: () => taps++,
        ),
      ),
    );

    expect(find.text('设置'), findsOneWidget);
    expect(find.text('外观主题'), findsOneWidget);
    await tester.tap(find.text('设置'));
    expect(taps, 1);
  });

  testWidgets('AppSettingsTile 未接 onTap 显示建设中', (WidgetTester tester) async {
    await tester.pumpWidget(
      _wrap(
        const AppSettingsTile(
          icon: Icons.tune_rounded,
          title: '设置',
          subtitle: '外观主题',
        ),
      ),
    );

    expect(find.text('建设中'), findsOneWidget);
  });

  test('AppPageError 前缀可覆盖', () {
    expect(const AppPageError(error: 'x', prefix: '读取失败').prefix, '读取失败');
  });
}
