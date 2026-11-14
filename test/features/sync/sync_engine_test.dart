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

  // ── B1：冲突且应用失败的行不得被清 dirty（SPEC-P6.4b D3）──────────────

  test('冲突行应用失败 → 保持 dirty（否则本机与云端永久分叉）', () async {
    final h = await _harness(<SyncResponse>[
      _json(200, <String, Object?>{
        'applied': 0,
        'conflicts': <Object?>[],
        'cursor': 1,
      }),
    ]);
    final Book book = await BookRepository(h.db).ensureDefaultBook();
    final Account account = await AccountRepository(
      h.db,
    ).create(bookId: book.id, name: '本机现金');

    // 把 push 的响应换成「这一行被服务端判为冲突，且 payload 坏到应用不了」
    // （_apply 会抛异常 → skipped）—— 这一行并没有真正上云。
    h.transport.responses.clear();
    h.transport.responses.addAll(<SyncResponse>[
      _json(200, <String, Object?>{
        'applied': 0,
        'conflicts': <Object?>[
          <String, Object?>{
            'bookId': book.id,
            'entity': 'account',
            'id': account.id,
            'updatedAt': account.updatedAt + 1000,
            'deleted': false,
            'payload': <String, Object?>{}, // 缺 name 等必填 → fromJson 抛错
          },
        ],
        'cursor': 2,
      }),
      _json(200, <String, Object?>{
        'changes': <Object?>[],
        'cursor': 2,
        'hasMore': false,
      }),
    ]);

    final SyncResult result = await h.container.read(syncEngineProvider).syncNow();

    final Account? after = await (h.db.select(
      h.db.accounts,
    )..where((t) => t.id.equals(account.id))).getSingleOrNull();
    expect(result.skipped, greaterThanOrEqualTo(1));
    expect(after?.dirty, 1, reason: '没上云就不能清 dirty');
    expect(after?.name, '本机现金', reason: '应用失败时本地值不能被改掉');
  });

  test('保持 dirty 的行下一轮仍会重推', () async {
    final h = await _harness(<SyncResponse>[
      _json(200, <String, Object?>{
        'applied': 0,
        'conflicts': <Object?>[
          // 占位，下面替换
        ],
        'cursor': 1,
      }),
    ]);
    final Book book = await BookRepository(h.db).ensureDefaultBook();
    final Account account = await AccountRepository(
      h.db,
    ).create(bookId: book.id, name: '本机现金');

    h.transport.responses.clear();
    h.transport.responses.addAll(<SyncResponse>[
      _json(200, <String, Object?>{
        'applied': 0,
        'conflicts': <Object?>[
          <String, Object?>{
            'bookId': book.id,
            'entity': 'account',
            'id': account.id,
            'updatedAt': account.updatedAt + 1000,
            'deleted': false,
            'payload': <String, Object?>{},
          },
        ],
        'cursor': 2,
      }),
      _json(200, <String, Object?>{
        'changes': <Object?>[],
        'cursor': 2,
        'hasMore': false,
      }),
      // 第二轮：这次服务端收下
      _json(200, <String, Object?>{
        'applied': 1,
        'conflicts': <Object?>[],
        'cursor': 3,
      }),
      _json(200, <String, Object?>{
        'changes': <Object?>[],
        'cursor': 3,
        'hasMore': false,
      }),
    ]);

    await h.container.read(syncEngineProvider).syncNow();
    await h.container.read(syncEngineProvider).syncNow();

    // 第二个 push 请求体里必须还有这条账本行
    final List<SyncRequest> pushes = h.transport.requests
        .where((SyncRequest r) => r.uri.path == '/v1/sync/push')
        .toList();
    expect(pushes.length, 2);
    expect(pushes[1].body, contains(account.id));

    final Account? after = await (h.db.select(
      h.db.accounts,
    )..where((t) => t.id.equals(account.id))).getSingleOrNull();
    expect(after?.dirty, 0, reason: '第二轮被接收后才清 dirty');
  });

  test('对照组：能正常应用的冲突行 → dirty=0', () async {
    final h = await _harness(<SyncResponse>[
      _json(200, <String, Object?>{
        'applied': 0,
        'conflicts': <Object?>[],
        'cursor': 1,
      }),
    ]);
    final Book book = await BookRepository(h.db).ensureDefaultBook();
    final Account account = await AccountRepository(
      h.db,
    ).create(bookId: book.id, name: '本机现金');

    h.transport.responses.clear();
    h.transport.responses.addAll(<SyncResponse>[
      _json(200, <String, Object?>{
        'applied': 0,
        'conflicts': <Object?>[
          <String, Object?>{
            'bookId': book.id,
            'entity': 'account',
            'id': account.id,
            'updatedAt': account.updatedAt + 1000,
            'deleted': false,
            'payload': _accountPayload(
              account,
              name: '云端改名',
              updatedAt: account.updatedAt + 1000,
            ),
          },
        ],
        'cursor': 2,
      }),
      _json(200, <String, Object?>{
        'changes': <Object?>[],
        'cursor': 2,
        'hasMore': false,
      }),
    ]);

    await h.container.read(syncEngineProvider).syncNow();

    final Account? after = await (h.db.select(
      h.db.accounts,
    )..where((t) => t.id.equals(account.id))).getSingleOrNull();
    expect(after?.name, '云端改名');
    expect(after?.dirty, 0);
  });
}
