/// P6.2 · AuthController：冷启动恢复 / 登录落库 / 401 续期 / 本地优先退出。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/core/network/cloud_sync_gate.dart';
import 'package:yanxin/core/network/sync_api.dart';
import 'package:yanxin/core/security/token_store.dart';
import 'package:yanxin/data/providers/database.dart';
import 'package:yanxin/data/repositories/app_meta_repository.dart';
import 'package:yanxin/features/sync/application/auth_controller.dart';

import '../../helpers/test_database.dart';

/// 按顺序返回预置响应；元素是 [SyncResponse] 或要抛出的异常。
class _QueueTransport implements SyncTransport {
  _QueueTransport(this.responses);

  final List<Object> responses;
  final List<SyncRequest> requests = <SyncRequest>[];

  @override
  Future<SyncResponse> send(SyncRequest request) async {
    requests.add(request);
    if (responses.isEmpty) throw StateError('没有更多预置响应');
    final Object next = responses.removeAt(0);
    if (next is SyncResponse) return next;
    throw next;
  }
}

class _FailingWriteStore extends MemoryTokenStore {
  @override
  Future<void> write(String key, String value) async {
    throw const SecureStoreException('写不进去');
  }
}

class _FailingReadStore extends MemoryTokenStore {
  @override
  Future<String?> read(String key) async {
    throw const SecureStoreException('读不出来');
  }
}

SyncResponse _json(int status, Map<String, Object?> body) =>
    SyncResponse(statusCode: status, body: jsonEncode(body));

Map<String, Object?> _tokenBody(String access, String refresh) =>
    <String, Object?>{
      'accessToken': access,
      'refreshToken': refresh,
      'expiresIn': 900,
    };

({ProviderContainer container, AppDatabase db}) _harness({
  TokenStore? store,
  required SyncTransport transport,
}) {
  final AppDatabase db = openTestDatabase();
  final ProviderContainer container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      tokenStoreProvider.overrideWithValue(store ?? MemoryTokenStore()),
      syncTransportProvider.overrideWithValue(transport),
      // 单测里把「占位域名 = 未配置」这一关打开，否则登录请求发不出去
      syncEndpointConfiguredProvider.overrideWithValue(true),
    ],
  );
  addTearDown(container.dispose);
  addTearDown(db.close);
  return (container: container, db: db);
}

Future<AuthSession> _storedSession(
  MemoryTokenStore store, {
  String access = 'access-old',
  String refresh = 'refresh-old',
}) async {
  final AuthSession session = AuthSession(
    accessToken: access,
    refreshToken: refresh,
    expiresAt: DateTime.now().add(const Duration(minutes: 15)),
  );
  await store.write(kSyncSessionKey, session.toStorageJson());
  await store.write(kSyncEmailKey, 'old@example.com');
  return session;
}

void main() {
  group('冷启动恢复', () {
    test('本机有 session → 已登录，且不发任何网络请求', () async {
      final MemoryTokenStore store = MemoryTokenStore();
      await _storedSession(store);
      final _QueueTransport transport = _QueueTransport(<Object>[]);

      final h = _harness(store: store, transport: transport);
      final AuthState state = await h.container.read(
        authControllerProvider.future,
      );

      expect(state.signedIn, isTrue);
      expect(state.session?.accessToken, 'access-old');
      expect(state.email, 'old@example.com');
      expect(transport.requests, isEmpty);
    });

    test('没有 session / 坏 JSON → 未登录，不抛', () async {
      final MemoryTokenStore bad = MemoryTokenStore();
      await bad.write(kSyncSessionKey, 'not-json');

      final h = _harness(
        store: bad,
        transport: _QueueTransport(<Object>[]),
      );
      expect(
        (await h.container.read(authControllerProvider.future)).signedIn,
        isFalse,
      );
    });

    test('安全存储读失败 → 按未登录处理', () async {
      final h = _harness(
        store: _FailingReadStore(),
        transport: _QueueTransport(<Object>[]),
      );
      expect(
        (await h.container.read(authControllerProvider.future)).signedIn,
        isFalse,
      );
    });
  });

  group('登录', () {
    test('verify 成功后 token 进安全存储、邮箱进 state', () async {
      final MemoryTokenStore store = MemoryTokenStore();
      final _QueueTransport transport = _QueueTransport(<Object>[
        _json(200, _tokenBody('access-1', 'refresh-1')),
      ]);
      final h = _harness(store: store, transport: transport);
      await h.container.read(authControllerProvider.future);

      await h.container
          .read(authControllerProvider.notifier)
          .signIn(email: ' me@example.com ', code: ' 123456 ');

      final AuthState state = h.container.read(authControllerProvider).value!;
      expect(state.signedIn, isTrue);
      expect(state.email, 'me@example.com');
      expect(state.session?.accessToken, 'access-1');

      final AuthSession? saved = AuthSession.tryParse(
        await store.read(kSyncSessionKey),
      );
      expect(saved?.refreshToken, 'refresh-1');
      expect(await store.read(kSyncEmailKey), 'me@example.com');

      // 请求体里的邮箱与验证码都去过空格
      expect(jsonDecode(transport.requests.single.body!), <String, Object?>{
        'email': 'me@example.com',
        'code': '123456',
      });
    });

    test('邮箱格式不对 → 本地直接拒绝，不发请求', () async {
      final _QueueTransport transport = _QueueTransport(<Object>[]);
      final h = _harness(transport: transport);
      await h.container.read(authControllerProvider.future);

      await expectLater(
        h.container
            .read(authControllerProvider.notifier)
            .signIn(email: 'nope', code: '1234'),
        throwsA(isA<SyncApiException>()),
      );
      expect(transport.requests, isEmpty);
    });

    test('token 写不进安全存储 → 登录失败，状态仍未登录', () async {
      final _QueueTransport transport = _QueueTransport(<Object>[
        _json(200, _tokenBody('access-1', 'refresh-1')),
      ]);
      final h = _harness(store: _FailingWriteStore(), transport: transport);
      await h.container.read(authControllerProvider.future);

      await expectLater(
        h.container
            .read(authControllerProvider.notifier)
            .signIn(email: 'a@b.com', code: '1234'),
        throwsA(isA<SecureStoreException>()),
      );
      expect(
        h.container.read(authControllerProvider).value?.signedIn,
        isFalse,
      );
    });

    test('邮箱校验是纯函数：常见形态', () {
      expect(AuthController.isValidEmail('a@b.com'), isTrue);
      expect(AuthController.isValidEmail(' a.b+c@sub.example.cn '), isTrue);
      expect(AuthController.isValidEmail('a@b'), isFalse);
      expect(AuthController.isValidEmail('@b.com'), isFalse);
      expect(AuthController.isValidEmail('a@.com'), isFalse);
      expect(AuthController.isValidEmail('a@b.'), isFalse);
      expect(AuthController.isValidEmail('a@b@c.com'), isFalse);
      expect(AuthController.isValidEmail(''), isFalse);
    });
  });

  group('401 续期', () {
    test('业务请求 401 → refresh → 用新 token 重放一次', () async {
      final MemoryTokenStore store = MemoryTokenStore();
      await _storedSession(store);
      final _QueueTransport transport = _QueueTransport(<Object>[
        const SyncResponse(statusCode: 401, body: ''),
        _json(200, _tokenBody('access-new', 'refresh-new')),
        const SyncResponse(statusCode: 204, body: ''),
      ]);
      final h = _harness(store: store, transport: transport);
      await h.container.read(authControllerProvider.future);

      await h.container
          .read(authControllerProvider.notifier)
          .deleteAccount();

      expect(transport.requests, hasLength(3));
      expect(transport.requests[0].uri.path, '/v1/account');
      expect(transport.requests[1].uri.path, '/v1/auth/refresh');
      expect(
        jsonDecode(transport.requests[1].body!),
        <String, Object?>{'refreshToken': 'refresh-old'},
      );
      expect(transport.requests[2].uri.path, '/v1/account');
      expect(transport.requests[2].headers['authorization'], 'Bearer access-new');

      // 注销成功后本机不再留 session
      expect(await store.read(kSyncSessionKey), isNull);
      expect(
        h.container.read(authControllerProvider).value?.signedIn,
        isFalse,
      );
    });

    test('refresh 也 401 → 清掉登录态并抛 unauthorized，不无限重试', () async {
      final MemoryTokenStore store = MemoryTokenStore();
      await _storedSession(store);
      final _QueueTransport transport = _QueueTransport(<Object>[
        const SyncResponse(statusCode: 401, body: ''),
        const SyncResponse(statusCode: 401, body: ''),
      ]);
      final h = _harness(store: store, transport: transport);
      await h.container.read(authControllerProvider.future);

      await expectLater(
        h.container.read(authControllerProvider.notifier).deleteAccount(),
        throwsA(
          isA<SyncApiException>().having(
            (SyncApiException e) => e.code,
            'code',
            'unauthorized',
          ),
        ),
      );
      expect(transport.requests, hasLength(2));
      expect(await store.read(kSyncSessionKey), isNull);
    });
  });

  group('退出 / 注销', () {
    test('服务端吊销失败也照样退出（本地优先）', () async {
      final MemoryTokenStore store = MemoryTokenStore();
      await _storedSession(store);
      final _QueueTransport transport = _QueueTransport(<Object>[
        const SocketException('offline'),
      ]);
      final h = _harness(store: store, transport: transport);
      await h.container.read(authControllerProvider.future);

      await h.container.read(authControllerProvider.notifier).signOut();

      expect(await store.read(kSyncSessionKey), isNull);
      expect(
        h.container.read(authControllerProvider).value?.signedIn,
        isFalse,
      );
      // 退出请求带的是 refresh token（服务端只认这个）
      expect(jsonDecode(transport.requests.single.body!), <String, Object?>{
        'refreshToken': 'refresh-old',
      });
      // 邮箱保留，方便下次登录预填
      expect(await store.read(kSyncEmailKey), 'old@example.com');
    });

    test('注销成功会顺手关掉同步开关', () async {
      final MemoryTokenStore store = MemoryTokenStore();
      await _storedSession(store);
      final _QueueTransport transport = _QueueTransport(<Object>[
        const SyncResponse(statusCode: 204, body: ''),
      ]);
      final h = _harness(store: store, transport: transport);
      await h.container.read(authControllerProvider.future);
      await h.container
          .read(cloudSyncEnabledProvider.notifier)
          .setEnabled(true);

      await h.container
          .read(authControllerProvider.notifier)
          .deleteAccount();

      expect(
        h.container.read(cloudSyncEnabledProvider).value,
        isFalse,
      );
      expect(
        await AppMetaRepository(h.db).get(kCloudSyncEnabledKey),
        '0',
      );
    });
  });

  group('闸门派生的登录态', () {
    test('未登录 → signedOut；登录但开关关 → disabledByUser', () async {
      final MemoryTokenStore store = MemoryTokenStore();
      final _QueueTransport transport = _QueueTransport(<Object>[
        _json(200, _tokenBody('a', 'r')),
      ]);
      final h = _harness(store: store, transport: transport);
      await h.container.read(authControllerProvider.future);
      await h.container.read(cloudSyncEnabledProvider.future);

      final Uri business = Uri.parse('https://sync.xiaomao.app/v1/backups');
      expect(
        h.container.read(cloudSyncGateProvider).denialFor(business),
        CloudSyncDenial.signedOut,
      );

      await h.container
          .read(authControllerProvider.notifier)
          .signIn(email: 'a@b.com', code: '1234');
      expect(
        h.container.read(cloudSyncGateProvider).denialFor(business),
        CloudSyncDenial.disabledByUser,
      );

      await h.container
          .read(cloudSyncEnabledProvider.notifier)
          .setEnabled(true);
      expect(h.container.read(cloudSyncGateProvider).denialFor(business), isNull);
    });
  });
}
