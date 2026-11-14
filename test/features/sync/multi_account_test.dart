/// P6.5 · 多账号：迁移 / 分槽 / 移除 / 切号回滚。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/core/network/sync_api.dart';
import 'package:yanxin/core/providers/account_scope.dart';
import 'package:yanxin/core/security/token_store.dart';
import 'package:yanxin/data/providers/database.dart';
import 'package:yanxin/data/repositories/app_meta_repository.dart';
import 'package:yanxin/data/repositories/book_repository.dart';
import 'package:yanxin/features/sync/application/account_switch.dart';
import 'package:yanxin/features/sync/application/auth_controller.dart';
import 'package:yanxin/features/sync/application/sync_engine.dart';

import '../../helpers/test_database.dart';

class _Transport implements SyncTransport {
  _Transport({this.fail = false});

  final bool fail;
  final List<SyncRequest> requests = <SyncRequest>[];

  @override
  Future<SyncResponse> send(SyncRequest request) async {
    requests.add(request);
    if (fail) throw const SocketException('offline');
    if (request.uri.path == '/v1/backups/latest') {
      return const SyncResponse(statusCode: 404, body: '{"error":"not_found"}');
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

AuthSession _session(String tag) => AuthSession(
  accessToken: 'access-$tag',
  refreshToken: 'refresh-$tag',
  expiresAt: DateTime.now().add(const Duration(minutes: 30)),
);

Future<
  ({ProviderContainer container, AppDatabase db, MemoryTokenStore store, _Transport transport})
>
_harness({bool failNetwork = false}) async {
  final AppDatabase db = openTestDatabase();
  final MemoryTokenStore store = MemoryTokenStore();
  final _Transport transport = _Transport(fail: failNetwork);
  final ProviderContainer container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      tokenStoreProvider.overrideWithValue(store),
      syncTransportProvider.overrideWithValue(transport),
      syncEndpointConfiguredProvider.overrideWithValue(true),
    ],
  );
  addTearDown(container.dispose);
  addTearDown(db.close);
  return (container: container, db: db, store: store, transport: transport);
}

/// 造一个「已登录 A、A 名下有一个账本」的状态。
Future<Book> _seedAccountA(
  AppDatabase db,
  MemoryTokenStore store, {
  String email = 'a@example.com',
}) async {
  await store.write(sessionKeyFor(email), _session('a').toStorageJson());
  final AppMetaRepository meta = AppMetaRepository(db);
  await meta.set(kSyncEmailKey, email);
  await meta.set(kActiveAccountKey, email);
  await meta.set(
    kSyncAccountsKey,
    encodeSavedAccounts(<SavedAccount>[
      SavedAccount(email: email, lastUsedAt: 1000),
    ]),
  );
  final Book book = await BookRepository(db).create(name: 'A 的账本', ownerId: email);
  await BookRepository(db).setActiveBookIdFor(email, book.id);
  return book;
}

void main() {
  test('迁移：旧单槽 session + 旧邮箱 → 转成该账号的槽并写进账号列表', () async {
    final h = await _harness();
    // 老版本写法：token 与邮箱都在安全存储里
    await h.store.write(kSyncSessionKey, _session('old').toStorageJson());
    await h.store.write(kSyncEmailKey, 'old@example.com');

    final AuthState state = await h.container.read(authControllerProvider.future);

    expect(state.signedIn, isTrue);
    expect(state.email, 'old@example.com');
    expect(state.accounts.map((SavedAccount a) => a.email), <String>[
      'old@example.com',
    ]);
    expect(await h.store.read(sessionKeyFor('old@example.com')), isNotNull);
    expect(await h.store.read(kSyncSessionKey), isNull, reason: '旧键迁移后要删掉');
  });

  test('两个账号各一份 token：退出不清、切回不用重新登录', () async {
    final h = await _harness();
    await _seedAccountA(h.db, h.store);
    await h.store.write(
      sessionKeyFor('b@example.com'),
      _session('b').toStorageJson(),
    );
    final meta = AppMetaRepository(h.db);
    await meta.set(
      kSyncAccountsKey,
      encodeSavedAccounts(const <SavedAccount>[
        SavedAccount(email: 'a@example.com', lastUsedAt: 1000),
        SavedAccount(email: 'b@example.com', lastUsedAt: 2000),
      ]),
    );
    final AuthController auth = h.container.read(authControllerProvider.notifier);
    await h.container.read(authControllerProvider.future);

    // 退出：token 保留
    await auth.signOut();
    expect(h.container.read(authControllerProvider).value?.signedIn, isFalse);
    expect(await h.store.read(sessionKeyFor('a@example.com')), isNotNull);

    // 切回：不发网络、直接可用
    await auth.switchTo('b@example.com');
    final AuthState state = h.container.read(authControllerProvider).value!;
    expect(state.email, 'b@example.com');
    expect(state.session?.accessToken, 'access-b');
    expect(h.transport.requests, isEmpty);
  });

  test('移除账号：删 token、从列表移除，但账本保留', () async {
    final h = await _harness();
    final Book book = await _seedAccountA(h.db, h.store);
    final AuthController auth = h.container.read(authControllerProvider.notifier);
    await h.container.read(authControllerProvider.future);

    await auth.removeAccount('a@example.com');

    expect(await h.store.read(sessionKeyFor('a@example.com')), isNull);
    expect(
      h.container.read(authControllerProvider).value?.accounts,
      isEmpty,
    );
    final Book? kept = await BookRepository(h.db).getById(book.id);
    expect(kept?.ownerId, 'a@example.com', reason: '账本不删，只隐藏');
    // 隐藏 = 当前范围里看不见（此时既未登录也无保存账号 → 退回本机账本口径，也没有它）
    expect(await BookRepository(h.db).listVisible(), isEmpty);
  });

  test('切号在「备份旧账号」就失败 → 停在原账号，不回滚出乱子', () async {
    final h = await _harness(failNetwork: true);
    await _seedAccountA(h.db, h.store);
    await h.store.write(
      sessionKeyFor('b@example.com'),
      _session('b').toStorageJson(),
    );
    await AppMetaRepository(h.db).set(
      kSyncAccountsKey,
      encodeSavedAccounts(const <SavedAccount>[
        SavedAccount(email: 'a@example.com', lastUsedAt: 1000),
        SavedAccount(email: 'b@example.com', lastUsedAt: 2000),
      ]),
    );
    await h.container.read(authControllerProvider.future);

    await expectLater(
      h.container.read(accountSwitcherProvider).switchTo('b@example.com'),
      throwsA(anything),
    );

    final AuthState state = h.container.read(authControllerProvider).value!;
    expect(state.email, 'a@example.com', reason: '备份失败不能切走');
    expect(state.signedIn, isTrue);
  });

  test('同步只推当前账号的账本（不把 A 的账推到 B 的云）', () async {
    final h = await _harness();
    final repo = BookRepository(h.db);
    final Book aBook = await repo.create(name: 'A 的账本', ownerId: 'a@example.com');
    final Book bBook = await repo.create(name: 'B 的账本', ownerId: 'b@example.com');
    await h.store.write(sessionKeyFor('a@example.com'), _session('a').toStorageJson());
    final meta = AppMetaRepository(h.db);
    await meta.set(kActiveAccountKey, 'a@example.com');
    await meta.set(kSyncEmailKey, 'a@example.com');
    await meta.set(
      kSyncAccountsKey,
      encodeSavedAccounts(const <SavedAccount>[
        SavedAccount(email: 'a@example.com', lastUsedAt: 1),
      ]),
    );
    await meta.set(kCloudSyncEnabledKey, '1');
    await repo.setActiveBookIdFor('a@example.com', aBook.id);
    await h.container.read(authControllerProvider.future);
    await h.container.read(cloudSyncEnabledProvider.future);

    await h.container.read(syncEngineProvider).syncNow();

    final String pushBody = h.transport.requests
        .firstWhere((SyncRequest r) => r.uri.path == '/v1/sync/push')
        .body!;
    expect(pushBody, contains(aBook.id));
    expect(pushBody, isNot(contains(bBook.id)), reason: 'B 的账本不能推到 A 的云');
  });
}
