/// 登录态的**安全存储**抽象（P6.2）。
///
/// 为什么自写通道而不是 `flutter_secure_storage`：本项目的依赖是锁死的
///（`pubspec.yaml` 顶部有明确注释），加插件要连带真机验证插件注册与卸载行为；
/// 而 `yanxin/ocr` / `yanxin/autobook` 已经证明「自建 MethodChannel」这条路在本仓库可控。
///
/// 约束：
/// - **token 不落明文**：原生侧用 Android Keystore 的 AES/GCM 加密，密文进
///   `SharedPreferences`；密钥不出 Keystore；
/// - **不放 drift**：备份 JSON 不含 token，`schema_meta` 也不存 token；
/// - 读失败按「没有」处理（= 未登录），写失败必须让调用方知道（登录不能假装成功）。
library;

import 'package:flutter/services.dart';

/// 原生安全存储的通道名（`android/.../secure/SecureStoreChannel.kt`）。
const String kSecureStoreChannelName = 'yanxin/secure';

/// 安全存储不可用 / 原生报错。
class SecureStoreException implements Exception {
  const SecureStoreException(this.message);

  final String message;

  @override
  String toString() => 'SecureStoreException($message)';
}

/// 键值型安全存储（值是小段 JSON / 邮箱，不是大文件）。
abstract class TokenStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);

  Future<void> clear();
}

/// 生产实现：走 `yanxin/secure` 通道。
class KeystoreTokenStore implements TokenStore {
  KeystoreTokenStore({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(kSecureStoreChannelName);

  final MethodChannel _channel;

  @override
  Future<String?> read(String key) async {
    try {
      return await _channel.invokeMethod<String>('read', <String, Object>{
        'key': key,
      });
    } on PlatformException catch (e) {
      // 读失败 = 当作没登录：不要让一个坏 key 把 App 拦在启动页
      throw SecureStoreException(e.message ?? '安全存储读取失败');
    } on MissingPluginException {
      // 单元测试 / 非 Android 平台
      throw const SecureStoreException('当前环境没有安全存储通道');
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _channel.invokeMethod<void>('write', <String, Object>{
        'key': key,
        'value': value,
      });
    } on PlatformException catch (e) {
      throw SecureStoreException(e.message ?? '安全存储写入失败');
    } on MissingPluginException {
      throw const SecureStoreException('当前环境没有安全存储通道');
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      await _channel.invokeMethod<void>('delete', <String, Object>{
        'key': key,
      });
    } on PlatformException catch (e) {
      throw SecureStoreException(e.message ?? '安全存储删除失败');
    } on MissingPluginException {
      throw const SecureStoreException('当前环境没有安全存储通道');
    }
  }

  @override
  Future<void> clear() async {
    try {
      await _channel.invokeMethod<void>('clear');
    } on PlatformException catch (e) {
      throw SecureStoreException(e.message ?? '安全存储清空失败');
    } on MissingPluginException {
      throw const SecureStoreException('当前环境没有安全存储通道');
    }
  }
}

/// 内存实现：单测 / 降级用。**不要**在 App 里当生产实现。
class MemoryTokenStore implements TokenStore {
  final Map<String, String> _data = <String, String>{};

  /// 当前存了哪些键（测试断言用）。
  Iterable<String> get keys => _data.keys;

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async {
    _data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _data.remove(key);
  }

  @override
  Future<void> clear() async {
    _data.clear();
  }
}
