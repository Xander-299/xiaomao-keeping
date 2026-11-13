/// P6.4 · 同步引擎：dirty → push → 置 0；pull → LWW 应用；墓碑；cursor。
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/core/network/sync_api.dart';
import 'package:yanxin/core/security/token_store.dart';
import 'package:yanxin/data/providers/database.dart';
import 'package:yanxin/data/repositories/account_repository.dart';
import 'package:yanxin/data/repositories/app_meta_repository.dart';
import 'package:yanxin/data/repositories/book_repository.dart';
import 'package:yanxin/features/sync/application/auth_controller.dart';
import 'package:yanxin/features/sync/application/sync_engine.dart';

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

SyncResponse _json(int status, Object body) =>
    SyncResponse(statusCode: status, body: jsonEncode(body));

Future<
  ({
    ProviderContainer container,
    AppDatabase db,
    _QueueTransport transport,
    MemoryTokenStore store,
  })
>
_harness(List<SyncResponse> responses) async {
  final AppDatabase db = openTestDatabase();
  final MemoryTokenStore store = MemoryTokenStore();
  await store.write(
    kSyncSessionKey,
    AuthSession(
      accessToken: 'access-1',
      refreshToken: 'refresh-1',
      expiresAt: DateTime.now().add(const Duration(minutes: 10)),
    ).toStorageJson(),
  );
  await store.write(kSyncEmailKey, 'me@example.com');
  await AppMetaRepository(db).set(kCloudSyncEnabledKey, '1');

  final _QueueTransport transport = _QueueTransport(responses);
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
  await container.read(authControllerProvider.future);
  await container.read(cloudSyncEnabledProvider.future);
  return (container: container, db: db, transport: transport, store: store);
}

Map<String, Object?> _accountPayload(Account account, {String? name, int? updatedAt}) =>
    <String, Object?>{
      ...account.toJson(),
      'name': name ?? account.name,
      'updatedAt': updatedAt ?? account.updatedAt,
    };

void main() {
  test('dirty 行 push 后置 0，cursor 落库', () async {
    final h = await _harness(<SyncResponse>[
      _json(200, <String, Object?>{
        'applied': 1,
        'conflicts': <Object?>[],
        'cursor': 1,
      }),
      _json(200, <String, Object?>{
        'changes': <Object?>[],
        'cursor': 1,
        'hasMore': false,
      }),
    ]);
    final Book book = await BookRepository(h.db).ensureDefaultBook();
    final Account account = await AccountRepository(
      h.db,
    ).create(bookId: book.id, name: '现金');

    final SyncResult result = await h.container.read(syncEngineProvider).syncNow();

    final Account? after = await (h.db.select(
      h.db.accounts,
    )..where((t) => t.id.equals(account.id))).getSingleOrNull();
    expect(after?.dirty, 0);
    expect(result.pushed, greaterThanOrEqualTo(1));
    expect(
      await AppMetaRepository(h.db).get('sync_cursor:me@example.com'),
      '1',
    );
    expect(h.transport.requests.first.uri.path, '/v1/sync/push');
  });

  test('pull 到服务端较新的行 → 覆盖本地并置 dirty=0', () async {
    final h = await _harness(<SyncResponse>[
      _json(200, <String, Object?>{
        'changes': <Object?>[
          <String, Object?>{
            'bookId': 'b1',
            'entity': 'account',
            'id': 'a-remote',
            'updatedAt': 5000,
            'deleted': false,
            'payload': <String, Object?>{
              'id': 'a-remote',
              'bookId': 'b1',
              'name': '云端账户',
              'type': 'cash',
              'initialBalanceCents': 0,
              'sortOrder': 0,
              'ownerId': null,
              'icon': '',
              'color': '',
              'createdAt': 1000,
              'updatedAt': 5000,
              'deletedAt': null,
              'dirty': 1,
            },
          },
        ],
        'cursor': 5,
        'hasMore': false,
      }),
    ]);

    await h.container.read(syncEngineProvider).syncNow();

    final Account? row = await (h.db.select(
      h.db.accounts,
    )..where((t) => t.id.equals('a-remote'))).getSingleOrNull();
    expect(row?.name, '云端账户');
    expect(row?.dirty, 0);
  });

  test('本地较新 → pull 到的旧行被跳过', () async {
    final h = await _harness(<SyncResponse>[
      _json(200, <String, Object?>{
        'applied': 1,
        'conflicts': <Object?>[],
        'cursor': 1,
      }),
    ]);
    final Book book = await BookRepository(h.db).ensureDefaultBook();
    final Account account = await AccountRepository(
      h.db,
    ).create(bookId: book.id, name: '本地现金');
    final int localUpdatedAt = account.updatedAt;

    // push 之后 pull 返回一条更旧的同 id 行（应被跳过）
    h.transport.responses.add(
      _json(200, <String, Object?>{
        'changes': <Object?>[
          <String, Object?>{
            'bookId': book.id,
            'entity': 'account',
            'id': account.id,
            'updatedAt': localUpdatedAt - 1000,
            'deleted': false,
            'payload': _accountPayload(
              account,
              name: '旧名字',
              updatedAt: localUpdatedAt - 1000,
            ),
          },
        ],
        'cursor': 9,
        'hasMore': false,
      }),
    );

    await h.container.read(syncEngineProvider).syncNow();

    final Account? after = await (h.db.select(
      h.db.accounts,
    )..where((t) => t.id.equals(account.id))).getSingleOrNull();
    expect(after?.name, '本地现金');
    expect(after?.updatedAt, localUpdatedAt);
  });

  test('墓碑：pull 到 deleted 行 → 写 deletedAt 且 dirty=0', () async {
    final h = await _harness(<SyncResponse>[
      _json(200, <String, Object?>{
        'changes': <Object?>[
          <String, Object?>{
            'bookId': 'b1',
            'entity': 'account',
            'id': 'a-del',
            'updatedAt': 9000,
            'deleted': false,
            'payload': <String, Object?>{
              'id': 'a-del',
              'bookId': 'b1',
              'name': '将被删',
              'type': 'cash',
              'initialBalanceCents': 0,
              'sortOrder': 0,
              'ownerId': null,
              'icon': '',
              'color': '',
              'createdAt': 1000,
              'updatedAt': 1000,
              'deletedAt': null,
              'dirty': 1,
            },
          },
        ],
        'cursor': 3,
        'hasMore': false,
      }),
      _json(200, <String, Object?>{
        'changes': <Object?>[
          <String, Object?>{
            'bookId': 'b1',
            'entity': 'account',
            'id': 'a-del',
            'updatedAt': 9000,
            'deleted': true,
            'payload': <String, Object?>{},
          },
        ],
        'cursor': 10,
        'hasMore': false,
      }),
    ]);

    // 第一次 pull 建行；第二次 pull 收到墓碑
    await h.container.read(syncEngineProvider).syncNow();
    await h.container.read(syncEngineProvider).syncNow();

    final Account? row = await (h.db.select(
      h.db.accounts,
    )..where((t) => t.id.equals('a-del'))).getSingleOrNull();
    expect(row?.deletedAt, 9000);
    expect(row?.dirty, 0);
  });
}
