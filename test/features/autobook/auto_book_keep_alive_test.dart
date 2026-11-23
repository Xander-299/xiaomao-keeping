/// 「后台常驻」开关（F7.22）。
///
/// 钉住三件事：
/// 1. 默认**关**（不能替用户决定常驻通知）；
/// 2. 开关落库 + 调原生 start/stop；
/// 3. 冷启动/回前台的 `ensureRunning` 是**幂等**的，且关着时什么都不做。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/data/providers/database.dart';
import 'package:yanxin/data/repositories/app_meta_repository.dart';
import 'package:yanxin/features/autobook/application/auto_book_keep_alive.dart';
import 'package:yanxin/features/autobook/data/auto_book_bridge.dart';
import 'package:yanxin/features/autobook/data/auto_book_diagnostics.dart';
import 'package:yanxin/features/autobook/presentation/auto_book_page.dart';

import '../../helpers/test_database.dart';

/// 只记录常驻相关调用；其余读取方法给安全默认值。
class _FakeBridge extends AutoBookBridge {
  int startCount = 0;
  int stopCount = 0;
  bool batteryIgnored = false;

  @override
  bool get supported => true;

  @override
  Future<bool> listenerEnabled() async => true;

  @override
  Future<bool> notificationsAllowed() async => true;

  @override
  Future<AutoBookDiagnostics?> diagnostics() async => null;

  @override
  Future<int> pendingCount() async => 0;

  @override
  Future<void> startKeepAlive() async => startCount++;

  @override
  Future<void> stopKeepAlive() async => stopCount++;

  @override
  Future<bool> keepAliveRunning() async => startCount > stopCount;

  @override
  Future<bool> batteryOptimizationIgnored() async => batteryIgnored;
}

Future<ProviderContainer> _container(AppDatabase db, _FakeBridge bridge) async {
  final ProviderContainer c = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      autoBookBridgeProvider.overrideWithValue(bridge),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  group('开关状态', () {
    test('默认关，且不会调用原生 start', () async {
      final AppDatabase db = openTestDatabase();
      addTearDown(db.close);
      final _FakeBridge bridge = _FakeBridge();
      final ProviderContainer c = await _container(db, bridge);

      expect(await c.read(autoBookKeepAliveProvider.future), isFalse);
      expect(bridge.startCount, 0);
    });

    test('打开 → 落库 + start；关闭 → stop', () async {
      final AppDatabase db = openTestDatabase();
      addTearDown(db.close);
      final _FakeBridge bridge = _FakeBridge();
      final ProviderContainer c = await _container(db, bridge);
      await c.read(autoBookKeepAliveProvider.future);

      final AutoBookKeepAlive notifier = c.read(
        autoBookKeepAliveProvider.notifier,
      );
      await notifier.setEnabled(true);
      expect(bridge.startCount, 1);
      expect(
        await AppMetaRepository(db).get(kAutoBookKeepAliveKey),
        '1',
        reason: '开关要跨启动保留',
      );

      await notifier.setEnabled(false);
      expect(bridge.stopCount, 1);
      expect(await AppMetaRepository(db).get(kAutoBookKeepAliveKey), '0');
    });

    test('ensureRunning：开着才拉起，关着不动（幂等，不叠通知）', () async {
      final AppDatabase db = openTestDatabase();
      addTearDown(db.close);
      final _FakeBridge bridge = _FakeBridge();
      final ProviderContainer c = await _container(db, bridge);
      await c.read(autoBookKeepAliveProvider.future);
      final AutoBookKeepAlive notifier = c.read(
        autoBookKeepAliveProvider.notifier,
      );

      await notifier.ensureRunning();
      expect(bridge.startCount, 0, reason: '默认关，冷启动不该起服务');

      await notifier.setEnabled(true);
      expect(bridge.startCount, 1);
      await notifier.ensureRunning(); // 回前台再来一次
      expect(bridge.startCount, 2, reason: '每次回到前台都再确认一次');
    });
  });

  group('页面：从系统设置回来要重读', () {
    testWidgets('切完省电策略回前台，「省电优化」那行要跟着变', (WidgetTester tester) async {
      final AppDatabase db = openTestDatabase();
      addTearDown(db.close);
      final _FakeBridge bridge = _FakeBridge();
      // 预置为「已开常驻」，省得先点开关
      await AppMetaRepository(db).set(kAutoBookKeepAliveKey, '1');

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            autoBookBridgeProvider.overrideWithValue(bridge),
          ],
          child: const MaterialApp(home: AutoBookPage()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('未忽略'), findsOneWidget);

      // 用户在系统设置里把我们设为「无限制」，然后回到 App
      bridge.batteryIgnored = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(find.textContaining('已忽略'), findsOneWidget);
      expect(find.textContaining('未忽略'), findsNothing);
    });
  });

  group('页面', () {
    testWidgets('开关可点，打开后出现省电优化 / 自启动两行引导', (WidgetTester tester) async {
      final AppDatabase db = openTestDatabase();
      addTearDown(db.close);
      final _FakeBridge bridge = _FakeBridge();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            autoBookBridgeProvider.overrideWithValue(bridge),
          ],
          // 与其它页面测试一致：不单独塞主题，页面用 context.toon 读默认调色板
          child: const MaterialApp(home: AutoBookPage()),
        ),
      );
      await tester.pumpAndSettle();

      // 分区标题 + 卡片标题各一个
      expect(find.text('后台常驻'), findsNWidgets(2));
      expect(find.textContaining('关：App 不在后台时'), findsOneWidget);

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(bridge.startCount, 1);
      expect(find.textContaining('常驻服务运行中'), findsOneWidget);
      expect(find.text('省电优化'), findsOneWidget);
      expect(find.textContaining('未忽略'), findsOneWidget);
      expect(find.text('自启动'), findsOneWidget);
    });
  });
}
