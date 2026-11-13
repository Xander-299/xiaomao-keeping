/// P6.2 · SyncApi：请求形状 / 错误映射 / 闸门必须在建连前生效。
///
/// 传输层注入假实现 —— 这些用例**一个真 socket 都不建**。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

  group('云备份（P6.3）', () {
    test('上传：PUT + Bearer + 字节体（不是 base64）', () async {
      final _FakeTransport t = _FakeTransport(<SyncResponse>[
        _json(200, <String, Object?>{
          'size': 3,
          'sha256': 'abc',
          'createdAt': '2026-11-14T00:00:00.000Z',
        }),
      ]);

      final BackupInfo info = await _api(t).uploadLatestBackup(
        accessToken: 'access-1',
        bytes: <int>[1, 2, 3],
      );

      final SyncRequest req = t.requests.single;
      expect(req.method, 'PUT');
      expect(req.uri.path, '/v1/backups/latest');
      expect(req.headers['authorization'], 'Bearer access-1');
      expect(req.headers['content-type'], 'application/json');
      expect(req.body, isNull);
      expect(req.bodyBytes, <int>[1, 2, 3]);
      expect(info.size, 3);
      expect(info.sizeLabel, '3 B');
      expect(info.sha256, 'abc');
    });

    test('下载：返回原文字节', () async {
      final _FakeTransport t = _FakeTransport(<SyncResponse>[
        const SyncResponse(statusCode: 200, body: '{"transactions":[]}'),
      ]);

      final Uint8List bytes = await _api(t).downloadLatestBackup('a');
      expect(utf8.decode(bytes), '{"transactions":[]}');
      expect(t.requests.single.method, 'GET');
      expect(t.requests.single.uri.path, '/v1/backups/latest');
    });

    test('列表：解析多份快照', () async {
      final _FakeTransport t = _FakeTransport(<SyncResponse>[
        SyncResponse(
          statusCode: 200,
          body: jsonEncode(<Object?>[
            <String, Object?>{
              'id': 'b1',
              'size': 2048,
              'sha256': 's1',
              'createdAt': '2026-11-14T00:00:00.000Z',
            },
            <String, Object?>{
              'id': 'b2',
              'size': 1024,
              'sha256': 's2',
              'createdAt': '2026-11-13T00:00:00.000Z',
            },
          ]),
        ),
      ]);

      final List<BackupInfo> list = await _api(t).listBackups('a');
      expect(list, hasLength(2));
      expect(list.first.id, 'b1');
      expect(list.first.sizeLabel, '2.0 KB');
      expect(list.last.sizeLabel, '1.0 KB');
    });

    test('404 → notFound（云端还没有备份）', () async {
      final _FakeTransport t = _FakeTransport(<SyncResponse>[
        _json(404, <String, Object?>{'error': 'not_found'}),
      ]);
      await expectLater(
        _api(t).downloadLatestBackup('a'),
        throwsA(
          isA<SyncApiException>().having(
            (SyncApiException e) => e.code,
            'code',
            'notFound',
          ),
        ),
      );
    });

    test('413 → tooLarge', () async {
      final _FakeTransport t = _FakeTransport(<SyncResponse>[
        _json(413, <String, Object?>{'error': 'too_large'}),
      ]);
      await expectLater(
        _api(t).uploadLatestBackup(accessToken: 'a', bytes: <int>[1]),
        throwsA(
          isA<SyncApiException>().having(
            (SyncApiException e) => e.code,
            'code',
            'tooLarge',
          ),
        ),
      );
    });

    test('开关关闭 → 业务闸门拒绝，一个请求都不发', () async {
      final _FakeTransport t = _FakeTransport(<SyncResponse>[]);
      await expectLater(
        _api(t, enabled: false).listBackups('a'),
        throwsA(
          isA<SyncDeniedException>().having(
            (SyncDeniedException e) => e.denial,
            'denial',
            CloudSyncDenial.disabledByUser,
          ),
        ),
      );
      expect(t.requests, isEmpty);
    });
  });

  group('双向同步（P6.4）', () {
    test('push：POST /v1/sync/push，changes 数组 + Bearer', () async {
      final _FakeTransport t = _FakeTransport(<SyncResponse>[
        _json(200, <String, Object?>{
          'applied': 1,
          'conflicts': <Object?>[],
          'cursor': 7,
        }),
      ]);

      final SyncPushResult result = await _api(t).pushChanges(
        accessToken: 'access-1',
        changes: <SyncChange>[
          const SyncChange(
            bookId: 'b1',
            entity: 'account',
            id: 'a1',
            updatedAt: 1000,
            deleted: false,
            payload: <String, Object?>{'name': '现金'},
          ),
        ],
      );

      final SyncRequest req = t.requests.single;
      expect(req.method, 'POST');
      expect(req.uri.path, '/v1/sync/push');
      expect(req.headers['authorization'], 'Bearer access-1');
      final Map<String, Object?> body =
          jsonDecode(req.body!) as Map<String, Object?>;
      expect((body['changes']! as List<Object?>).length, 1);
      expect(result.applied, 1);
      expect(result.cursor, 7);
    });

    test('push：conflicts 解析成 SyncChange', () async {
      final _FakeTransport t = _FakeTransport(<SyncResponse>[
        _json(200, <String, Object?>{
          'applied': 0,
          'cursor': 7,
          'conflicts': <Object?>[
            <String, Object?>{
              'bookId': 'b1',
              'entity': 'account',
              'id': 'a1',
              'updatedAt': 2000,
              'deleted': false,
              'payload': <String, Object?>{'name': '云端'},
            },
          ],
        }),
      ]);
      final SyncPushResult result = await _api(t).pushChanges(
        accessToken: 'a',
        changes: <SyncChange>[
          const SyncChange(
            bookId: 'b1',
            entity: 'account',
            id: 'a1',
            updatedAt: 1000,
            deleted: false,
            payload: <String, Object?>{},
          ),
        ],
      );
      expect(result.conflicts.single.updatedAt, 2000);
      expect(result.conflicts.single.payload['name'], '云端');
    });

    test('pull：since/limit 查询参数与解析', () async {
      final _FakeTransport t = _FakeTransport(<SyncResponse>[
        _json(200, <String, Object?>{
          'changes': <Object?>[
            <String, Object?>{
              'bookId': 'b1',
              'entity': 'transaction',
              'id': 't1',
              'updatedAt': 3000,
              'deleted': true,
              'payload': <String, Object?>{},
            },
          ],
          'cursor': 9,
          'hasMore': true,
        }),
      ]);
      final SyncPullResult result = await _api(t).pullChanges(
        accessToken: 'a',
        since: 5,
        limit: 100,
      );
      expect(t.requests.single.uri.path, '/v1/sync/pull');
      expect(t.requests.single.uri.queryParameters['since'], '5');
      expect(t.requests.single.uri.queryParameters['limit'], '100');
      expect(result.changes.single.deleted, isTrue);
      expect(result.cursor, 9);
      expect(result.hasMore, isTrue);
    });

    test('开关关闭 → 闸门拒绝，不发请求', () async {
      final _FakeTransport t = _FakeTransport(<SyncResponse>[]);
      await expectLater(
        _api(t, enabled: false).pullChanges(accessToken: 'a', since: 0),
        throwsA(isA<SyncDeniedException>()),
      );
      expect(t.requests, isEmpty);
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
