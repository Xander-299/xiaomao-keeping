/// P6.2 · TokenStore：内存实现 + `yanxin/secure` 通道契约。
///
/// 通道用 `setMockMethodCallHandler` 假实现 —— 不碰真 Android Keystore。
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/core/security/token_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel(kSecureStoreChannelName);

  List<MethodCall> mockChannel(
    Future<Object?> Function(MethodCall call) handler,
  ) {
    final List<MethodCall> calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          return handler(call);
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    return calls;
  }

  group('MemoryTokenStore', () {
    test('读写删清空', () async {
      final MemoryTokenStore store = MemoryTokenStore();
      expect(await store.read('k'), isNull);

      await store.write('k', 'v');
      expect(await store.read('k'), 'v');

      await store.delete('k');
      expect(await store.read('k'), isNull);

      await store.write('a', '1');
      await store.write('b', '2');
      await store.clear();
      expect(await store.read('a'), isNull);
      expect(store.keys, isEmpty);
    });
  });

  group('KeystoreTokenStore（通道契约）', () {
    test('read 用 key 参数，原样返回字符串', () async {
      final List<MethodCall> calls = mockChannel(
        (MethodCall call) async => 'stored-value',
      );

      final String? value = await KeystoreTokenStore().read('sync_session');

      expect(value, 'stored-value');
      expect(calls.single.method, 'read');
      expect(calls.single.arguments, <String, Object>{'key': 'sync_session'});
    });

    test('write 同时带 key 与 value', () async {
      final List<MethodCall> calls = mockChannel(
        (MethodCall call) async => null,
      );

      await KeystoreTokenStore().write('sync_session', '{"a":1}');

      expect(calls.single.method, 'write');
      expect(calls.single.arguments, <String, Object>{
        'key': 'sync_session',
        'value': '{"a":1}',
      });
    });

    test('delete / clear 的方法名与参数', () async {
      final List<MethodCall> calls = mockChannel(
        (MethodCall call) async => null,
      );
      final KeystoreTokenStore store = KeystoreTokenStore();

      await store.delete('sync_email');
      await store.clear();

      expect(calls.map((MethodCall c) => c.method), <String>['delete', 'clear']);
      expect(calls.first.arguments, <String, Object>{'key': 'sync_email'});
    });

    test('原生报错 → SecureStoreException（不把 PlatformException 漏出去）', () async {
      mockChannel(
        (MethodCall call) async => throw PlatformException(
          code: 'secure_store',
          message: 'KeyPermanentlyInvalidatedException',
        ),
      );

      await expectLater(
        KeystoreTokenStore().read('sync_session'),
        throwsA(isA<SecureStoreException>()),
      );
      await expectLater(
        KeystoreTokenStore().write('sync_session', 'v'),
        throwsA(isA<SecureStoreException>()),
      );
    });

    test('没有通道（非 Android / 未注册）也不裸抛 MissingPluginException', () async {
      // 不设 mock handler：默认 binary messenger 会回 null → MissingPluginException
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);

      await expectLater(
        KeystoreTokenStore().read('sync_session'),
        throwsA(isA<SecureStoreException>()),
      );
    });
  });
}
