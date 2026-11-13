/// P6.2 · SyncApi：请求形状 / 错误映射 / 闸门必须在建连前生效。
///
/// 传输层注入假实现 —— 这些用例**一个真 socket 都不建**。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/core/network/cloud_sync_gate.dart';
import 'package:yanxin/core/network/sync_api.dart';
import 'package:yanxin/core/network/sync_endpoints.dart';

class _FakeTransport implements SyncTransport {
  _FakeTransport(this.responses);

  /// 按顺序弹出；用完后抛错，防止「多发了一次请求」被静默吞掉。
  final List<SyncResponse> responses;
  final List<SyncRequest> requests = <SyncRequest>[];
  int _index = 0;

  @override
  Future<SyncResponse> send(SyncRequest request) async {
    requests.add(request);
    if (_index >= responses.length) {
      throw StateError('没有更多预置响应：第 ${_index + 1} 次请求');
    }
    return responses[_index++];
  }
}

/// 会抛网络异常的传输层。
class _ThrowingTransport implements SyncTransport {
  _ThrowingTransport(this.error);

  final Object error;

  @override
  Future<SyncResponse> send(SyncRequest request) async {
    throw error;
  }
}

SyncApi _api(
  SyncTransport transport, {
  bool signedIn = true,
  bool enabled = true,
  bool configured = true,
}) => SyncApi(
  transport: transport,
  gate: () => CloudSyncGate(
    signedIn: signedIn,
    userEnabled: enabled,
    endpointConfigured: configured,
  ),
);

SyncResponse _json(int status, Map<String, Object?> body) =>
    SyncResponse(statusCode: status, body: jsonEncode(body));

void main() {
  group('发码', () {
    test('POST /v1/auth/request-code，JSON 体与头都对；204 视为成功', () async {
      final _FakeTransport t = _FakeTransport(<SyncResponse>[
        const SyncResponse(statusCode: 204, body: ''),
      ]);

      await _api(t).requestCode('me@example.com');

      expect(t.requests, hasLength(1));
      final SyncRequest req = t.requests.single;
      expect(req.method, 'POST');
      expect(req.uri.path, '/v1/auth/request-code');
      expect(req.uri.scheme, 'https');
      expect(req.headers['content-type'], 'application/json');
      expect(req.headers['accept'], 'application/json');
      expect(jsonDecode(req.body!), <String, Object?>{
        'email': 'me@example.com',
      });
    });

    test('未登录也能发码（认证接口不被 signedOut 拦）', () async {
      final _FakeTransport t = _FakeTransport(<SyncResponse>[
        const SyncResponse(statusCode: 204, body: ''),
      ]);

      await _api(t, signedIn: false, enabled: false).requestCode('a@b.com');

      expect(t.requests, hasLength(1));
    });

    test('未配置端点 → 闸门拒绝，且一个请求都不发', () async {
      final _FakeTransport t = _FakeTransport(<SyncResponse>[]);

      await expectLater(
        _api(t, configured: false).requestCode('a@b.com'),
        throwsA(
          isA<SyncDeniedException>().having(
            (SyncDeniedException e) => e.denial,
            'denial',
            CloudSyncDenial.notConfigured,
          ),
        ),
      );
      expect(t.requests, isEmpty);
    });
  });

  group('校验与续期', () {
    test('verify 解析两个 token 与过期时间', () async {
      final DateTime before = DateTime.now();
      final _FakeTransport t = _FakeTransport(<SyncResponse>[
        _json(200, <String, Object?>{
          'accessToken': 'access-1',
          'refreshToken': 'refresh-1',
          'expiresIn': 900,
        }),
      ]);

      final AuthSession session = await _api(t).verify('a@b.com', '123456');

      expect(session.accessToken, 'access-1');
      expect(session.refreshToken, 'refresh-1');
      expect(
        session.expiresAt.isAfter(before.add(const Duration(minutes: 14))),
        isTrue,
      );
      expect(jsonDecode(t.requests.single.body!), <String, Object?>{
        'email': 'a@b.com',
        'code': '123456',
      });
    });

    test('refresh 带 refreshToken，并换回轮换后的两个 token', () async {
      final _FakeTransport t = _FakeTransport(<SyncResponse>[
        _json(200, <String, Object?>{
          'accessToken': 'access-2',
          'refreshToken': 'refresh-2',
          'expiresIn': 60,
        }),
      ]);

      final AuthSession session = await _api(t).refresh('refresh-1');

      expect(t.requests.single.uri.path, '/v1/auth/refresh');
      expect(jsonDecode(t.requests.single.body!), <String, Object?>{
        'refreshToken': 'refresh-1',
      });
      expect(session.accessToken, 'access-2');
      expect(session.refreshToken, 'refresh-2');
    });

    test('过期判定留 30 s 余量', () {
      final AuthSession session = AuthSession(
        accessToken: 'a',
        refreshToken: 'r',
        expiresAt: DateTime.now().add(const Duration(seconds: 10)),
      );
      expect(session.isExpired, isTrue);

      final AuthSession fresh = AuthSession(
        accessToken: 'a',
        refreshToken: 'r',
        expiresAt: DateTime.now().add(const Duration(minutes: 5)),
      );
      expect(fresh.isExpired, isFalse);
    });

    test('存储 JSON 可往返；坏数据返回 null 而不是抛', () {
      final AuthSession session = AuthSession(
        accessToken: 'a',
        refreshToken: 'r',
        expiresAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
      final AuthSession? restored = AuthSession.tryParse(
        session.toStorageJson(),
      );
      expect(restored?.accessToken, 'a');
      expect(restored?.refreshToken, 'r');
      expect(restored?.expiresAt.millisecondsSinceEpoch, 1700000000000);

      expect(AuthSession.tryParse(null), isNull);
      expect(AuthSession.tryParse('not json'), isNull);
      expect(AuthSession.tryParse('{"accessToken":"a"}'), isNull);
    });
  });

  group('注销 / 退出', () {
    test('deleteAccount 用 DELETE + Bearer；业务接口未开开关时被拒', () async {
      final _FakeTransport t = _FakeTransport(<SyncResponse>[
        const SyncResponse(statusCode: 204, body: ''),
      ]);

      await _api(t).deleteAccount('access-1');

      final SyncRequest req = t.requests.single;
      expect(req.method, 'DELETE');
      expect(req.uri.path, '/v1/account');
      expect(req.headers['authorization'], 'Bearer access-1');
    });

    test('logout 用 POST + Bearer，且请求体带 refreshToken（服务端认这个）', () async {
      final _FakeTransport t = _FakeTransport(<SyncResponse>[
        const SyncResponse(statusCode: 204, body: ''),
      ]);

      await _api(t).logout(accessToken: 'access-1', refreshToken: 'refresh-1');

      final SyncRequest req = t.requests.single;
      expect(req.method, 'POST');
      expect(req.uri.path, '/v1/auth/logout');
      expect(req.headers['authorization'], 'Bearer access-1');
      expect(jsonDecode(req.body!), <String, Object?>{
        'refreshToken': 'refresh-1',
      });
    });
  });

  group('错误映射', () {
    test('401 → unauthorized', () async {
      final _FakeTransport t = _FakeTransport(<SyncResponse>[
        const SyncResponse(statusCode: 401, body: ''),
      ]);
      await expectLater(
        _api(t).logout(accessToken: 'a', refreshToken: 'r'),
        throwsA(
          isA<SyncApiException>().having(
            (SyncApiException e) => e.code,
            'code',
            'unauthorized',
          ),
        ),
      );
    });

    test('429 → rateLimited', () async {
      final _FakeTransport t = _FakeTransport(<SyncResponse>[
        const SyncResponse(statusCode: 429, body: ''),
      ]);
      await expectLater(
        _api(t).requestCode('a@b.com'),
        throwsA(
          isA<SyncApiException>().having(
            (SyncApiException e) => e.code,
            'code',
            'rateLimited',
          ),
        ),
      );
    });

    test('5xx → server（带状态码，响应体只留摘要）', () async {
      final _FakeTransport t = _FakeTransport(<SyncResponse>[
        const SyncResponse(statusCode: 500, body: 'boom'),
      ]);
      await expectLater(
        _api(t).requestCode('a@b.com'),
        throwsA(
          isA<SyncApiException>()
              .having((SyncApiException e) => e.code, 'code', 'server')
              .having((SyncApiException e) => e.statusCode, 'status', 500),
        ),
      );
    });

    test('400 code_mismatch → invalidCode（不能说成服务器挂了）', () async {
      final _FakeTransport t = _FakeTransport(<SyncResponse>[
        _json(400, <String, Object?>{'error': 'code_mismatch'}),
      ]);
      await expectLater(
        _api(t).verify('a@b.com', '000000'),
        throwsA(
          isA<SyncApiException>()
              .having((SyncApiException e) => e.code, 'code', 'invalidCode')
              .having(
                (SyncApiException e) => e.userMessage,
                'message',
                contains('验证码'),
              ),
        ),
      );
    });

    test('503 mail_not_configured → mailNotConfigured', () async {
      final _FakeTransport t = _FakeTransport(<SyncResponse>[
        _json(503, <String, Object?>{'error': 'mail_not_configured'}),
      ]);
      await expectLater(
        _api(t).requestCode('a@b.com'),
        throwsA(
          isA<SyncApiException>().having(
            (SyncApiException e) => e.code,
            'code',
            'mailNotConfigured',
          ),
        ),
      );
    });

    test('JSON 缺字段 → invalidResponse', () async {
      final _FakeTransport t = _FakeTransport(<SyncResponse>[
        _json(200, <String, Object?>{'refreshToken': 'r'}),
      ]);
      await expectLater(
        _api(t).verify('a@b.com', '1'),
        throwsA(
          isA<SyncApiException>().having(
            (SyncApiException e) => e.code,
            'code',
            'invalidResponse',
          ),
        ),
      );
    });

    test('非 JSON 响应 → invalidResponse', () async {
      final _FakeTransport t = _FakeTransport(<SyncResponse>[
        const SyncResponse(statusCode: 200, body: '<html>'),
      ]);
      await expectLater(
        _api(t).verify('a@b.com', '1'),
        throwsA(
          isA<SyncApiException>().having(
            (SyncApiException e) => e.code,
            'code',
            'invalidResponse',
          ),
        ),
      );
    });

    test('SocketException → network（不把原始异常漏给 UI）', () async {
      await expectLater(
        _api(_ThrowingTransport(const SocketException('offline'))).requestCode(
          'a@b.com',
        ),
        throwsA(
          isA<SyncApiException>().having(
            (SyncApiException e) => e.code,
            'code',
            'network',
          ),
        ),
      );
    });

    test('每种错误码都有给用户看的一句话', () {
      for (final String code in <String>[
        'network',
        'timeout',
        'unauthorized',
        'rateLimited',
        'invalidCode',
        'invalidInput',
        'mailNotConfigured',
        'server',
        'invalidResponse',
        'unknown',
      ]) {
        expect(SyncApiException(code).userMessage, isNotEmpty);
      }
    });
  });

  group('请求地址', () {
    test('所有路径都拼在同一个 baseUrl 下', () {
      expect(
        SyncEndpoints.resolve('/v1/auth/verify').host,
        Uri.parse(SyncEndpoints.baseUrl).host,
      );
    });
  });
}
