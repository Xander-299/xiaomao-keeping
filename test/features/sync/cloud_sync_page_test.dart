/// P6.2 · 云同步页：未登录表单 / 发码冷却 / 登录后账号态 / 开关落库。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/core/network/sync_api.dart';
import 'package:yanxin/core/security/token_store.dart';
import 'package:yanxin/core/theme/palette.dart';
import 'package:yanxin/core/theme/tokens.dart';
import 'package:yanxin/data/providers/database.dart';
import 'package:yanxin/data/repositories/app_meta_repository.dart';
import 'package:yanxin/features/sync/application/auth_controller.dart';
import 'package:yanxin/features/sync/presentation/cloud_sync_page.dart';

import '../../helpers/test_database.dart';

class _QueueTransport implements SyncTransport {
  _QueueTransport(this.responses);

  final List<SyncResponse> responses;
  final List<SyncRequest> requests = <SyncRequest>[];

  @override
  Future<SyncResponse> send(SyncRequest request) async {
    requests.add(request);
    if (responses.isEmpty) throw StateError('没有更多预置响应');
    return responses.removeAt(0);
  }
}

Future<AppDatabase> _pumpPage(
  WidgetTester tester, {
  required AppDatabase db,
  required TokenStore store,
  required SyncTransport transport,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        tokenStoreProvider.overrideWithValue(store),
        syncTransportProvider.overrideWithValue(transport),
        syncEndpointConfiguredProvider.overrideWithValue(true),
      ],
      child: MaterialApp(
        theme: buildToonTheme(ToonPalette.light, Brightness.light),
        home: const CloudSyncPage(),
      ),
    ),
  );
  await tester.pump();
  return db;
}

void main() {
  testWidgets('未登录：显示邮箱 / 验证码 / 发送 / 登录，没有同步开关', (WidgetTester tester) async {
    final AppDatabase db = openTestDatabase();
    addTearDown(db.close);

    await _pumpPage(
      tester,
      db: db,
      store: MemoryTokenStore(),
      transport: _QueueTransport(<SyncResponse>[]),
    );

    expect(find.byKey(const ValueKey<String>('cloudSyncEmail')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('cloudSyncCode')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('cloudSyncSendCode')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('cloudSyncSignIn')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey<String>('cloudSyncSwitch')), findsNothing);
    expect(find.text('未登录'), findsOneWidget);
  });

  testWidgets('邮箱不合法：本地拦下，不发请求', (WidgetTester tester) async {
    final AppDatabase db = openTestDatabase();
    addTearDown(db.close);
    final _QueueTransport transport = _QueueTransport(<SyncResponse>[]);

    await _pumpPage(
      tester,
      db: db,
      store: MemoryTokenStore(),
      transport: transport,
    );

    await tester.enterText(
      find.byKey(const ValueKey<String>('cloudSyncEmail')),
      'nope',
    );
    await tester.tap(find.byKey(const ValueKey<String>('cloudSyncSendCode')));
    await tester.pump();

    expect(find.text('请输入正确的邮箱'), findsOneWidget);
    expect(transport.requests, isEmpty);
  });

  testWidgets('发送验证码：请求一次，按钮进入冷却', (WidgetTester tester) async {
    final AppDatabase db = openTestDatabase();
    addTearDown(db.close);
    final _QueueTransport transport = _QueueTransport(<SyncResponse>[
      const SyncResponse(statusCode: 204, body: ''),
    ]);

    await _pumpPage(
      tester,
      db: db,
      store: MemoryTokenStore(),
      transport: transport,
    );

    await tester.enterText(
      find.byKey(const ValueKey<String>('cloudSyncEmail')),
      'me@example.com',
    );
    await tester.tap(find.byKey(const ValueKey<String>('cloudSyncSendCode')));
    await tester.pump();
    await tester.pump();

    expect(transport.requests, hasLength(1));
    expect(find.textContaining('验证码已发送'), findsOneWidget);
    expect(find.textContaining('s 后可重发'), findsOneWidget);

    // 页面 dispose 会取消倒计时，否则测试结束会报 pending timer
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('登录成功：显示邮箱 / 开关 / 退出与注销', (WidgetTester tester) async {
    final AppDatabase db = openTestDatabase();
    addTearDown(db.close);
    final MemoryTokenStore store = MemoryTokenStore();
    final _QueueTransport transport = _QueueTransport(<SyncResponse>[
      SyncResponse(
        statusCode: 200,
        body: jsonEncode(<String, Object?>{
          'accessToken': 'access-1',
          'refreshToken': 'refresh-1',
          'expiresIn': 900,
        }),
      ),
    ]);

    await _pumpPage(tester, db: db, store: store, transport: transport);

    await tester.enterText(
      find.byKey(const ValueKey<String>('cloudSyncEmail')),
      'me@example.com',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('cloudSyncCode')),
      '123456',
    );
    await tester.tap(find.byKey(const ValueKey<String>('cloudSyncSignIn')));
    await tester.pump();
    await tester.pump();

    expect(transport.requests.single.uri.path, '/v1/auth/verify');
    expect(find.text('me@example.com'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('cloudSyncSwitch')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('cloudSyncSignOut')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('cloudSyncDelete')),
      findsOneWidget,
    );
    expect(await store.read(kSyncSessionKey), isNotNull);
  });

  testWidgets('已登录：拨开关落库', (WidgetTester tester) async {
    final AppDatabase db = openTestDatabase();
    addTearDown(db.close);
    final MemoryTokenStore store = MemoryTokenStore();
    await store.write(
      kSyncSessionKey,
      AuthSession(
        accessToken: 'a',
        refreshToken: 'r',
        expiresAt: DateTime.now().add(const Duration(minutes: 5)),
      ).toStorageJson(),
    );
    await store.write(kSyncEmailKey, 'me@example.com');

    await _pumpPage(
      tester,
      db: db,
      store: store,
      transport: _QueueTransport(<SyncResponse>[]),
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey<String>('cloudSyncSwitch')));
    await tester.pump();

    // 写库是真实异步 → 轮询
    String? stored;
    for (int i = 0; i < 20 && stored == null; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      stored = await AppMetaRepository(db).get(kCloudSyncEnabledKey);
    }
    expect(stored, '1');
  });
}
