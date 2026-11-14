/// P6.4b · 网络类型通道：真/假/异常三条口径（异常一律当「不是 WiFi」）。
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/core/platform/network_info.dart';

const MethodChannel _channel = MethodChannel('yanxin/network');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  void mock(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, handler);
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  test('原生说 WiFi → true', () async {
    mock((MethodCall call) async => call.method == 'isWifi' ? true : null);
    expect(await const NetworkInfo().isWifi(), isTrue);
  });

  test('原生说不是 WiFi → false', () async {
    mock((MethodCall call) async => call.method == 'isWifi' ? false : null);
    expect(await const NetworkInfo().isWifi(), isFalse);
  });

  test('原生返回 null（老系统 / 未实现）→ false', () async {
    mock((MethodCall call) async => null);
    expect(await const NetworkInfo().isWifi(), isFalse);
  });

  test('通道抛异常 → false（宁可不同步，也不偷跑流量）', () async {
    mock((MethodCall call) async => throw PlatformException(code: 'boom'));
    expect(await const NetworkInfo().isWifi(), isFalse);
  });
}
