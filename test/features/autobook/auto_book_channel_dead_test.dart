/// F7.20 回归：「设置里开着、系统其实没绑定服务」必须被点名。
///
/// 事故（2026-11-19，v0.8.12 release）：用户 `/autobook` 页「通知使用权 = 已开启」，
/// 但一条支付通知都记不上，「最近捕获」恒为「从未收到过」。根因是国产 ROM 保留了
/// 「通知使用权」的条目却不再绑定服务 —— 此时 `catchUpNow()` 返回 `-1`，
/// 而 Dart 侧把它折成 `0`，于是「通道不通」与「今天没支付」看起来一模一样。
///
/// 本组用例钉住三件事：
/// 1. 诊断模型能认出 `lastCatchUpUnbound`（**不依赖** `listenerConnected` 撒谎与否）；
/// 2. 诊断块单列「补抓通道」，把「试过重绑也没救回来」摆给用户；
/// 3. 提示语不再承诺「打开 App 一次就会补记上」—— 那条路此时根本不存在。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/data/providers/database.dart';
import 'package:yanxin/features/autobook/data/auto_book_bridge.dart';
import 'package:yanxin/features/autobook/data/auto_book_diagnostics.dart';
import 'package:yanxin/features/autobook/presentation/auto_book_page.dart';

import '../../helpers/test_database.dart';

/// 原生链路全部短路，只回放一份固定的诊断快照。
class _DeadChannelBridge extends AutoBookBridge {
  _DeadChannelBridge(this.snapshot);

  final AutoBookDiagnostics snapshot;

  @override
  bool get supported => true;

  @override
  Future<bool> listenerEnabled() async => true;

  @override
  Future<bool> notificationsAllowed() async => true;

  @override
  Future<AutoBookDiagnostics?> diagnostics() async => snapshot;

  @override
  Future<int> pendingCount() async => 0;
}

/// 「系统没绑定」的典型快照：权限页显示已开启，但从未连接成功、补抓返回 -1。
AutoBookDiagnostics _deadSnapshot({
  bool listenerConnected = false,
  int lastConnectedAtMs = 0,
  int rebindAttempts = 2,
  bool catchUpUnbound = true,
}) {
  return AutoBookDiagnostics.tryParse(
    '{"listenerConnected":$listenerConnected,'
    '"lastConnectedAtMs":$lastConnectedAtMs,'
    '"lastCaptureAtMs":0,'
    '"lastCapturePkg":"",'
    '"capturedTotal":0,'
    '"skippedNotWatched":0,'
    '"skippedEmpty":0,'
    '"skippedDedup":0,'
    '"skippedGroupSummary":0,'
    '"lastDrainAtMs":0,'
    '"lastDrainCount":0,'
    '"drainedTotal":0,'
    '"lastCatchUpUnbound":$catchUpUnbound,'
    '"catchUpUnboundTotal":${catchUpUnbound ? 1 : 0},'
    '"rebindAttempts":$rebindAttempts,'
    '"lastRebindOk":false,'
    '"nowMs":1000000}',
  )!;
}

Future<void> _pumpPage(WidgetTester tester, AppDatabase db, AutoBookBridge b) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        autoBookBridgeProvider.overrideWithValue(b),
      ],
      child: const MaterialApp(home: AutoBookPage()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('诊断模型：catchUpChannelDead', () {
    test('原生报补抓拿不到实例 → 判定通道不通', () {
      final AutoBookDiagnostics d = _deadSnapshot();
      expect(d.catchUpChannelDead, isTrue);
      expect(d.catchUpUnboundTotal, 1);
      expect(d.rebindAttempts, 2);
    });

    test('⚠️ 即使 listenerConnected 仍是 true 也要判死（旧连接状态会撒谎）', () {
      final AutoBookDiagnostics d = _deadSnapshot(listenerConnected: true);
      expect(d.listenerConnected, isTrue);
      expect(d.catchUpChannelDead, isTrue);
    });

    test('补抓跑起来过（未报未绑定）→ 通道正常', () {
      final AutoBookDiagnostics d = _deadSnapshot(catchUpUnbound: false);
      expect(d.catchUpChannelDead, isFalse);
    });

    test('旧版原生快照缺字段 → 默认 false（不能因此误报）', () {
      final AutoBookDiagnostics d = AutoBookDiagnostics.tryParse(
        '{"listenerConnected":true,"nowMs":1}',
      )!;
      expect(d.catchUpChannelDead, isFalse);
      expect(d.rebindAttempts, 0);
    });
  });

  group('页面：补抓通道不通时要说清楚', () {
    testWidgets('诊断块单列「补抓通道」并说明重绑也没救回来', (WidgetTester tester) async {
      final AppDatabase db = openTestDatabase();
      addTearDown(db.close);
      await _pumpPage(tester, db, _DeadChannelBridge(_deadSnapshot()));

      expect(find.text('补抓通道'), findsOneWidget);
      expect(
        find.textContaining('不通（系统未绑定监听服务）'),
        findsOneWidget,
      );
      expect(find.textContaining('已尝试重绑 2 次未成功'), findsOneWidget);
    });

    testWidgets('提示语指向「关掉再打开通知使用权」，不再承诺打开 App 就能补记', (
      WidgetTester tester,
    ) async {
      final AppDatabase db = openTestDatabase();
      addTearDown(db.close);
      await _pumpPage(tester, db, _DeadChannelBridge(_deadSnapshot()));

      expect(
        find.textContaining('系统当前没有真正绑定监听服务'),
        findsOneWidget,
      );
      expect(
        find.textContaining('把「通知使用权」关掉再打开一次'),
        findsOneWidget,
      );
      expect(
        find.textContaining('会立刻把通知里的账单补记上'),
        findsNothing,
      );
    });

    testWidgets('通道正常时不显示「不通」', (WidgetTester tester) async {
      final AppDatabase db = openTestDatabase();
      addTearDown(db.close);
      await _pumpPage(
        tester,
        db,
        _DeadChannelBridge(_deadSnapshot(catchUpUnbound: false)),
      );

      expect(find.textContaining('不通（系统未绑定监听服务）'), findsNothing);
      expect(find.text('正常'), findsWidgets);
    });
  });
}
