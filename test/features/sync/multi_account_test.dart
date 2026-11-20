/// P6.5 · 多账号：迁移 / 分槽 / 移除 / 切号回滚。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/core/models/email.dart';
import 'package:yanxin/core/models/saved_account.dart';
import 'package:yanxin/core/network/sync_api.dart';
import 'package:yanxin/core/providers/account_keys.dart';
import 'package:yanxin/core/security/token_store.dart';
import 'package:yanxin/data/providers/book_providers.dart';
import 'package:yanxin/data/providers/database.dart';
import 'package:yanxin/data/repositories/app_meta_repository.dart';
import 'package:yanxin/data/repositories/book_repository.dart';
import 'package:yanxin/features/sync/application/account_switch.dart';
import 'package:yanxin/features/sync/application/auth_controller.dart';
import 'package:yanxin/features/sync/application/sync_engine.dart';

import '../../helpers/test_database.dart';

class _Transport implements SyncTransport {
  _Transport({this.fail = false, this.failPull = false});

  final bool fail;
  final bool failPull;
  final List<SyncRequest> requests = <SyncRequest>[];

  @override
  Future<SyncResponse> send(SyncRequest request) async {
    requests.add(request);
    if (fail) throw const SocketException('offline');
    if (failPull && request.uri.path == '/v1/sync/pull') {
      throw const SocketException('offline');
    }
    // 备份接口按方法区分：GET 最新备份 = 没有（404），PUT = 上传成功，GET 列表 = 空
    if (request.uri.path == '/v1/backups/latest' && request.method == 'GET') {
      return const SyncResponse(statusCode: 404, body: '{"error":"not_found"}');
    }
    if (request.uri.path == '/v1/backups' && request.method == 'GET') {
      return const SyncResponse(statusCode: 200, body: '[]');
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

typedef _Harness = ({
  ProviderContainer container,
  AppDatabase db,
  MemoryTokenStore store,
  _Transport transport,
});

Future<_Harness> _harness({bool failNetwork = false, bool failPull = false}) async {
  final AppDatabase db = openTestDatabase();
  final MemoryTokenStore store = MemoryTokenStore();
  final _Transport transport = _Transport(
    fail: failNetwork,
    failPull: failPull,
  );
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

/// 在 A 的基础上再放一个 b 的 token + 两个账号的列表（切号用）。
Future<void> _seedAccountBAndBoth(_Harness h) async {
  await _seedAccountA(h.db, h.store);
  await h.store.write(
    sessionKeyFor(_email('b@example.com')),
    _session('b').toStorageJson(),
  );
  await AppMetaRepository(h.db).set(
    kSyncAccountsKey,
    encodeSavedAccounts(<SavedAccount>[
      SavedAccount(
        email: _email('a@example.com'),
        lastUsedAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ),
      SavedAccount(
        email: _email('b@example.com'),
        lastUsedAt: DateTime.fromMillisecondsSinceEpoch(2000),
      ),
    ]),
  );
  await h.container.read(authControllerProvider.future);
}

/// 造一个「已登录 A、A 名下有一个账本」的状态。
Future<Book> _seedAccountA(
  AppDatabase db,
  MemoryTokenStore store, {
  String email = 'a@example.com',
}) async {
  await store.write(sessionKeyFor(_email(email)), _session('a').toStorageJson());
  final AppMetaRepository meta = AppMetaRepository(db);
  await meta.set(kSyncEmailKey, email);
  await meta.set(kActiveAccountKey, email);
  // 闸门要求「用户开关开」才放行业务请求
  await meta.set(kCloudSyncEnabledKey, '1');
  await meta.set(
    kSyncAccountsKey,
    encodeSavedAccounts(<SavedAccount>[
      SavedAccount(email: _email(email), lastUsedAt: DateTime.fromMillisecondsSinceEpoch(1000)),
    ]),
  );
  final Book book = await BookRepository(db).create(name: 'A 的账本', ownerId: email);
  await BookRepository(db).setActiveBookIdFor(email, book.id);
  return book;
}

Email _email(String raw) => Email.tryParse(raw)!;

void main() {
  test('迁移：旧单槽 session + 旧邮箱 → 转成该账号的槽并写进账号列表', () async {
    final h = await _harness();
    // 老版本写法：token 与邮箱都在安全存储里
    await h.store.write(kSyncSessionKey, _session('old').toStorageJson());
    await h.store.write(kSyncEmailKey, 'old@example.com');

    final AuthState state = await h.container.read(authControllerProvider.future);

    expect(state.signedIn, isTrue);
    expect(state.email?.value, 'old@example.com');
    expect(state.accounts.map((SavedAccount a) => a.email.value), <String>[
      'old@example.com',
    ]);
    expect(await h.store.read(sessionKeyFor(_email('old@example.com'))), isNotNull);
    expect(await h.store.read(kSyncSessionKey), isNull, reason: '旧键迁移后要删掉');
  });

  test('两个账号各一份 token：退出不清、切回不用重新登录', () async {
    final h = await _harness();
    await _seedAccountA(h.db, h.store);
    await h.store.write(
      sessionKeyFor(_email('b@example.com')),
      _session('b').toStorageJson(),
    );
    final meta = AppMetaRepository(h.db);
    await meta.set(
      kSyncAccountsKey,
      encodeSavedAccounts(<SavedAccount>[
        SavedAccount(email: _email('a@example.com'), lastUsedAt: DateTime.fromMillisecondsSinceEpoch(1000)),
        SavedAccount(email: _email('b@example.com'), lastUsedAt: DateTime.fromMillisecondsSinceEpoch(2000)),
      ]),
    );
    final AuthController auth = h.container.read(authControllerProvider.notifier);
    await h.container.read(authControllerProvider.future);

    // 退出：token 保留
    await auth.signOut();
    expect(h.container.read(authControllerProvider).value?.signedIn, isFalse);
    expect(await h.store.read(sessionKeyFor(_email('a@example.com'))), isNotNull);

    // 切回：不发网络、直接可用
    await auth.switchTo('b@example.com');
    final AuthState state = h.container.read(authControllerProvider).value!;
    expect(state.email?.value, 'b@example.com');
    expect(state.session?.accessToken, 'access-b');
    expect(h.transport.requests, isEmpty);
  });

  test('移除账号：删 token、从列表移除，但账本保留', () async {
    final h = await _harness();
    final Book book = await _seedAccountA(h.db, h.store);
    final AuthController auth = h.container.read(authControllerProvider.notifier);
    await h.container.read(authControllerProvider.future);

    await auth.removeAccount('a@example.com');

    expect(await h.store.read(sessionKeyFor(_email('a@example.com'))), isNull);
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
      sessionKeyFor(_email('b@example.com')),
      _session('b').toStorageJson(),
    );
    await AppMetaRepository(h.db).set(
      kSyncAccountsKey,
      encodeSavedAccounts(<SavedAccount>[
        SavedAccount(email: _email('a@example.com'), lastUsedAt: DateTime.fromMillisecondsSinceEpoch(1000)),
        SavedAccount(email: _email('b@example.com'), lastUsedAt: DateTime.fromMillisecondsSinceEpoch(2000)),
      ]),
    );
    await h.container.read(authControllerProvider.future);

    await expectLater(
      h.container.read(accountSwitcherProvider).switchTo('b@example.com'),
      throwsA(anything),
    );

    final AuthState state = h.container.read(authControllerProvider).value!;
    expect(state.email?.value, 'a@example.com', reason: '备份失败不能切走');
    expect(state.signedIn, isTrue);
  });

  test('同步只推当前账号的账本（不把 A 的账推到 B 的云）', () async {
    final h = await _harness();
    final repo = BookRepository(h.db);
    final Book aBook = await repo.create(name: 'A 的账本', ownerId: 'a@example.com');
    final Book bBook = await repo.create(name: 'B 的账本', ownerId: 'b@example.com');
    await h.store.write(sessionKeyFor(_email('a@example.com')), _session('a').toStorageJson());
    final meta = AppMetaRepository(h.db);
    await meta.set(kActiveAccountKey, 'a@example.com');
    await meta.set(kSyncEmailKey, 'a@example.com');
    await meta.set(
      kSyncAccountsKey,
      encodeSavedAccounts(<SavedAccount>[
        SavedAccount(email: _email('a@example.com'), lastUsedAt: DateTime.fromMillisecondsSinceEpoch(1)),
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

  test('迁移时把本机账本绑给该账号（否则升级后账本列表会空）', () async {
    final h = await _harness();
    final Book local = await BookRepository(h.db).create(name: '本机账本');
    await h.store.write(kSyncSessionKey, _session('old').toStorageJson());
    await h.store.write(kSyncEmailKey, 'a@example.com');

    await h.container.read(authControllerProvider.future);

    final Book? after = await BookRepository(h.db).getById(local.id);
    expect(after?.ownerId, 'a@example.com');
    expect(
      (await BookRepository(h.db).listVisible()).map((Book b) => b.id),
      <String>[local.id],
    );
  });

  test('邮箱归一：大写登录也能看见同一账号的账本', () async {
    final h = await _harness();
    await h.store.write(
      sessionKeyFor(_email('a@example.com')),
      _session('a').toStorageJson(),
    );
    await h.store.write(sessionKeyFor(_email('a@example.com')), _session('a').toStorageJson());
    await AppMetaRepository(h.db).set(
      kSyncAccountsKey,
      encodeSavedAccounts(<SavedAccount>[
        SavedAccount(email: _email('a@example.com'), lastUsedAt: DateTime.fromMillisecondsSinceEpoch(1)),
      ]),
    );
    final Book book = await BookRepository(h.db).create(name: 'A 账本', ownerId: 'a@example.com');
    await h.container.read(authControllerProvider.future);

    await h.container.read(authControllerProvider.notifier).switchTo('A@Example.COM');

    final state = h.container.read(authControllerProvider).value!;
    expect(state.email?.value, 'a@example.com', reason: '归一化后应是小写');
    expect(
      (await BookRepository(h.db).listVisible()).map((Book b) => b.id),
      <String>[book.id],
    );
  });

  test('退出登录会刷新账本范围（空态生效）', () async {
    final h = await _harness();
    await _seedAccountA(h.db, h.store);
    await h.container.read(authControllerProvider.future);
    expect(await BookRepository(h.db).listVisible(), isNotEmpty);

    await h.container.read(authControllerProvider.notifier).signOut();

    expect(await BookRepository(h.db).listVisible(), isEmpty);
    expect(h.container.read(activeBookIdProvider).value, isNull,
        reason: '退出后账本 provider 必须重建为空，不能还挂着上个账号');
  });

  test('迁移重复启动幂等：账号列表不会重复追加', () async {
    // 冷启动两次 = 两个容器共用同一个库与安全存储（第一次容器 dispose 不影响库）
    final AppDatabase db = openTestDatabase();
    addTearDown(db.close);
    final MemoryTokenStore store = MemoryTokenStore();
    await store.write(kSyncSessionKey, _session('old').toStorageJson());
    await store.write(kSyncEmailKey, 'old@example.com');

    ProviderContainer boot() => ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        tokenStoreProvider.overrideWithValue(store),
        syncTransportProvider.overrideWithValue(_Transport()),
        syncEndpointConfiguredProvider.overrideWithValue(true),
      ],
    );

    final ProviderContainer first = boot();
    await first.read(authControllerProvider.future);
    first.dispose();

    final ProviderContainer second = boot();
    addTearDown(second.dispose);
    final AuthState again = await second.read(authControllerProvider.future);

    expect(again.accounts.map((SavedAccount a) => a.email.value), <String>['old@example.com']);
  });

  test('bootstrapPull 拉完 11 页（不吃 10 页上限）', () async {
    final AppDatabase db = openTestDatabase();
    addTearDown(db.close);
    final MemoryTokenStore store = MemoryTokenStore();
    await _seedAccountA(db, store);
    final SyncTransport transport = _PagedTransport(totalPages: 11);
    final ProviderContainer container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        tokenStoreProvider.overrideWithValue(store),
        syncTransportProvider.overrideWithValue(transport),
        syncEndpointConfiguredProvider.overrideWithValue(true),
      ],
    );
    addTearDown(container.dispose);
    await container.read(authControllerProvider.future);
    await container.read(cloudSyncEnabledProvider.future);

    final SyncResult result = await container
        .read(syncEngineProvider)
        .bootstrapPull();

    expect(result.pulled, 11, reason: '11 页全部拉到');
    expect(
      await AppMetaRepository(db).get('sync_cursor:a@example.com'),
      '11',
    );
  });

  test('下行 book 行 ownerId 为空 → 落地时补成当前账号', () async {
    final AppDatabase db = openTestDatabase();
    addTearDown(db.close);
    final MemoryTokenStore store = MemoryTokenStore();
    await _seedAccountA(db, store);
    final SyncTransport transport = _RemoteBookTransport();
    final ProviderContainer container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        tokenStoreProvider.overrideWithValue(store),
        syncTransportProvider.overrideWithValue(transport),
        syncEndpointConfiguredProvider.overrideWithValue(true),
      ],
    );
    addTearDown(container.dispose);
    await container.read(authControllerProvider.future);
    await container.read(cloudSyncEnabledProvider.future);

    await container.read(syncEngineProvider).bootstrapPull();

    final Book? remote = await (db.select(db.books)
          ..where((t) => t.id.equals('b-remote')))
        .getSingleOrNull();
    expect(remote?.ownerId, 'a@example.com');
  });

  test('切号在「拉取补齐」阶段失败 → 回滚到原账号', () async {
    final h = await _harness(failPull: true);
    await _seedAccountA(h.db, h.store);
    await h.store.write(
      sessionKeyFor(_email('b@example.com')),
      _session('b').toStorageJson(),
    );
    await AppMetaRepository(h.db).set(
      kSyncAccountsKey,
      encodeSavedAccounts(<SavedAccount>[
        SavedAccount(email: _email('a@example.com'), lastUsedAt: DateTime.fromMillisecondsSinceEpoch(1000)),
        SavedAccount(email: _email('b@example.com'), lastUsedAt: DateTime.fromMillisecondsSinceEpoch(2000)),
      ]),
    );
    await h.container.read(authControllerProvider.future);

    await expectLater(
      h.container.read(accountSwitcherProvider).switchTo('b@example.com'),
      throwsA(anything),
    );

    final AuthState state = h.container.read(authControllerProvider).value!;
    expect(state.email?.value, 'a@example.com', reason: '拉取失败要退回原账号');
    expect(state.signedIn, isTrue);
  });

  group('切号步骤表（顺序 = 执行顺序）', () {
    test('已登录切号：备份 → 切 session → 恢复备份 → 拉增量', () async {
      final h = await _harness();
      await _seedAccountBAndBoth(h);

      final List<AccountSwitchStage> stages = <AccountSwitchStage>[];
      await h.container
          .read(accountSwitcherProvider)
          .switchTo('b@example.com', onStage: stages.add);

      expect(stages, <AccountSwitchStage>[
        AccountSwitchStage.backingUp,
        AccountSwitchStage.switching,
        AccountSwitchStage.restoring,
        AccountSwitchStage.pulling,
      ]);
    });

    test('本来没登录：不备份（没有旧账号可备），只剩三步', () async {
      final h = await _harness();
      // 只有 b 的 token，尚未登录任何账号
      await h.store.write(
        sessionKeyFor(_email('b@example.com')),
        _session('b').toStorageJson(),
      );
      await h.container.read(authControllerProvider.future);

      final List<AccountSwitchStage> stages = <AccountSwitchStage>[];
      await h.container
          .read(accountSwitcherProvider)
          .switchTo('b@example.com', onStage: stages.add);

      expect(stages, <AccountSwitchStage>[
        AccountSwitchStage.switching,
        AccountSwitchStage.restoring,
        AccountSwitchStage.pulling,
      ]);
      expect(stages, isNot(contains(AccountSwitchStage.backingUp)));
    });
  });
}

/// 11 页、每页一条 account 变更（第 11 页 hasMore=false）。
class _PagedTransport implements SyncTransport {
  _PagedTransport({required this.totalPages});

  final int totalPages;
  int _served = 0;

  @override
  Future<SyncResponse> send(SyncRequest request) async {
    if (request.uri.path != '/v1/sync/pull') {
      return SyncResponse(
        statusCode: 200,
        body: jsonEncode(<String, Object?>{
          'applied': 0,
          'conflicts': <Object?>[],
          'cursor': 0,
        }),
      );
    }
    _served++;
    return SyncResponse(
      statusCode: 200,
      body: jsonEncode(<String, Object?>{
        'changes': <Object?>[
          <String, Object?>{
            'bookId': 'b1',
            'entity': 'account',
            'id': 'acc-p$_served',
            'updatedAt': 1000 + _served,
            'deleted': false,
            'payload': <String, Object?>{
              'id': 'acc-p$_served',
              'bookId': 'b1',
              'name': '账户$_served',
              'type': 'cash',
              'initialBalanceCents': 0,
              'sortOrder': 0,
              'ownerId': null,
              'icon': '',
              'color': '',
              'createdAt': 1000,
              'updatedAt': 1000 + _served,
              'deletedAt': null,
              'dirty': 0,
            },
          },
        ],
        'cursor': _served,
        'hasMore': _served < totalPages,
      }),
    );
  }
}

/// 只回一条 ownerId 为空的 book（用于验「落地归一」）。
class _RemoteBookTransport implements SyncTransport {
  int _served = 0;

  @override
  Future<SyncResponse> send(SyncRequest request) async {
    if (request.uri.path != '/v1/sync/pull') {
      return SyncResponse(
        statusCode: 200,
        body: jsonEncode(<String, Object?>{
          'applied': 0,
          'conflicts': <Object?>[],
          'cursor': 0,
        }),
      );
    }
    _served++;
    return SyncResponse(
      statusCode: 200,
      body: jsonEncode(<String, Object?>{
        'changes': _served == 1
            ? <Object?>[
                <String, Object?>{
                  'bookId': 'b-remote',
                  'entity': 'book',
                  'id': 'b-remote',
                  'updatedAt': 5000,
                  'deleted': false,
                  'payload': <String, Object?>{
                    'id': 'b-remote',
                    'name': '云端账本',
                    'type': 'personal',
                    'currency': 'CNY',
                    'icon': '',
                    'color': '',
                    'sortOrder': 0,
                    'ownerId': null,
                    'createdAt': 1000,
                    'updatedAt': 5000,
                    'deletedAt': null,
                    'dirty': 0,
                  },
                },
              ]
            : <Object?>[],
        'cursor': _served,
        'hasMore': false,
      }),
    );
  }
}
