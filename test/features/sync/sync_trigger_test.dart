/// P6.4b · 自动触发：仅 WiFi / 5 分钟节流 / 闸门关闭时不写节流键。
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/core/network/sync_api.dart';
import 'package:yanxin/core/platform/network_info.dart';
import 'package:yanxin/core/security/token_store.dart';
import 'package:yanxin/data/providers/database.dart';
import 'package:yanxin/data/repositories/app_meta_repository.dart';
import 'package:yanxin/data/repositories/book_repository.dart';
import 'package:yanxin/features/sync/application/auth_controller.dart';
import 'package:yanxin/features/sync/application/sync_engine.dart';
import 'package:yanxin/features/sync/application/sync_trigger.dart';

import '../../helpers/test_database.dart';

class _FakeNet extends NetworkInfo {
  const _FakeNet(this.wifi);

  final bool wifi;

  @override
  Future<bool> isWifi() async => wifi;
}

class _Transport implements SyncTransport {
  _Transport();

  final List<SyncRequest> requests = <SyncRequest>[];

  @override
  Future<SyncResponse> send(SyncRequest request) async {
    requests.add(request);
    if (request.uri.path == '/v1/sync/push') {
      return SyncResponse(
        statusCode: 200,
        body: jsonEncode(<String, Object?>{
          'applied': 0,
          'conflicts': <Object?>[],
          'cursor': 1,
        }),
      );
    }
    return SyncResponse(
      statusCode: 200,
      body: jsonEncode(<String, Object?>{
        'changes': <Object?>[],
        'cursor': 1,
        'hasMore': false,
      }),
    );
  }
}

Future<
  ({ProviderContainer container, AppDatabase db, _Transport transport, AppMetaRepository meta})
>
_harness({required bool wifi, bool signedIn = true}) async {
  final AppDatabase db = openTestDatabase();
  final MemoryTokenStore store = MemoryTokenStore();
  if (signedIn) {
    await store.write(
      kSyncSessionKey,
      AuthSession(
        accessToken: 'access-1',
        refreshToken: 'refresh-1',
        expiresAt: DateTime.now().add(const Duration(minutes: 10)),
      ).toStorageJson(),
    );
    await store.write(kSyncEmailKey, 'me@example.com');
  }
  final AppMetaRepository meta = AppMetaRepository(db);
  await meta.set(kCloudSyncEnabledKey, '1');

  final _Transport transport = _Transport();
  final ProviderContainer container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      tokenStoreProvider.overrideWithValue(store),
      syncTransportProvider.overrideWithValue(transport),
      syncEndpointConfiguredProvider.overrideWithValue(true),
      networkInfoProvider.overrideWithValue(_FakeNet(wifi)),
    ],
  );
  addTearDown(container.dispose);
  addTearDown(db.close);
  await container.read(authControllerProvider.future);
  await container.read(cloudSyncEnabledProvider.future);
  await BookRepository(db).ensureDefaultBook();
  return (container: container, db: db, transport: transport, meta: meta);
}

void main() {
  test('不是 WiFi → 不跑、也不写节流键（换到 WiFi 立刻能跑）', () async {
    final h = await _harness(wifi: false);

    final SyncResult? result = await h.container
        .read(syncTriggerProvider)
        .maybeSync(reason: '测试');

    expect(result, isNull);
    expect(h.transport.requests, isEmpty);
    expect(
      await h.meta.get('${kSyncLastAttemptKeyPrefix}me@example.com'),
      isNull,
    );
  });

  test('是 WiFi → 跑一次并写节流键；紧接着再叫一次被节流', () async {
    final h = await _harness(wifi: true);
    final SyncTrigger trigger = h.container.read(syncTriggerProvider);

    final SyncResult? first = await trigger.maybeSync(reason: '冷启动');
    expect(first, isNotNull);
    expect(
      h.transport.requests.where((SyncRequest r) => r.uri.path == '/v1/sync/push'),
      isNotEmpty,
    );
    expect(
      await h.meta.get('${kSyncLastAttemptKeyPrefix}me@example.com'),
      isNotNull,
    );

    final int requestsAfterFirst = h.transport.requests.length;
    final SyncResult? second = await trigger.maybeSync(reason: '回前台');
    expect(second, isNull, reason: '5 分钟内不该再发请求');
    expect(h.transport.requests.length, requestsAfterFirst);
  });

  test('未登录 → 直接跳过，不写节流键', () async {
    final h = await _harness(wifi: true, signedIn: false);

    final SyncResult? result = await h.container
        .read(syncTriggerProvider)
        .maybeSync(reason: '冷启动');

    expect(result, isNull);
    expect(h.transport.requests, isEmpty);
    expect(
      await h.meta.get('${kSyncLastAttemptKeyPrefix}me@example.com'),
      isNull,
    );
  });
}
