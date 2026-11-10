/// P6.1 · 网络闸门与端点白名单。
///
/// 这一层存在的意义：加了 `INTERNET` 权限之后，「不偷偷联网」不能靠清单文件保证，
/// 只能靠「所有请求都必须先过 [CloudSyncGate]」这条代码约定。所以这里把每一种拒绝原因
/// 都钉死 —— 将来谁改闸门，先得让这些用例过。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/core/network/cloud_sync_gate.dart';
import 'package:yanxin/core/network/sync_endpoints.dart';

CloudSyncGate _gate({bool signedIn = true, bool enabled = true}) =>
    CloudSyncGate(signedIn: signedIn, userEnabled: enabled);

void main() {
  group('默认闸门（未登录 / 未开启）', () {
    test('常量闸门拒绝一切请求', () {
      expect(kClosedCloudSyncGate.signedIn, isFalse);
      expect(kClosedCloudSyncGate.allows(SyncEndpoints.resolve('/')), isFalse);
      expect(
        kClosedCloudSyncGate.denialFor(SyncEndpoints.resolve('/')),
        CloudSyncDenial.signedOut,
      );
    });

    test('登录了但没开开关 → disabledByUser', () {
      expect(
        _gate(enabled: false).denialFor(SyncEndpoints.resolve('/')),
        CloudSyncDenial.disabledByUser,
      );
    });
  });

  group('地址校验', () {
    test('非 https 一律拒绝（不提供「仅本次允许」）', () {
      expect(
        _gate().denialFor(Uri.parse('http://sync.xiaomao.app/v1/backups')),
        CloudSyncDenial.insecureEndpoint,
      );
    });

    test('主机不在白名单 → 拒绝（防止配置被改后把账本导去别处）', () {
      expect(
        _gate().denialFor(Uri.parse('https://evil.example.com/v1/backups')),
        CloudSyncDenial.hostNotAllowlisted,
      );
    });

    test('子域不会自动放行', () {
      expect(
        _gate().denialFor(Uri.parse('https://a.sync.xiaomao.app/v1/backups')),
        CloudSyncDenial.hostNotAllowlisted,
      );
    });

    test('白名单内的 https 地址放行', () {
      final Uri uri = SyncEndpoints.resolve('/v1/backups');
      expect(_gate().denialFor(uri), isNull);
      expect(_gate().isOpen, isTrue);
    });
  });

  group('端点拼接', () {
    test('相对路径补齐前导斜杠，且不重复拼根路径', () {
      expect(SyncEndpoints.resolve('v1/backups').path, '/v1/backups');
      expect(SyncEndpoints.resolve('/v1/backups').path, '/v1/backups');
      expect(SyncEndpoints.baseUrl.endsWith('/'), isFalse);
    });

    test('默认地址是 https 且始终在白名单里', () {
      expect(Uri.parse(SyncEndpoints.baseUrl).scheme, 'https');
      expect(
        SyncEndpoints.allowlistedHosts.contains(
          Uri.parse(SyncEndpoints.baseUrl).host,
        ),
        isTrue,
      );
    });
  });

  group('拒绝原因文案', () {
    test('每种原因都有一句给用户看的话', () {
      for (final CloudSyncDenial d in CloudSyncDenial.values) {
        expect(d.label, isNotEmpty);
      }
    });
  });
}
