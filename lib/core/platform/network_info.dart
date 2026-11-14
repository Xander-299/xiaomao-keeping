/// 网络类型查询（P6.4b D6）：自动同步只在 WiFi 下跑。
///
/// 判定在原生侧（`android/.../network/NetworkChannel.kt`，通道 `yanxin/network`）——
/// Dart 没有读网络类型的 API，而本项目依赖锁死、不引 `connectivity_plus`。
///
/// 三条口径：
/// 1. **通道失败一律当作「不是 WiFi」**：宁可这次不同步，也不要偷偷走蜂窝流量；
/// 2. **以太网也算 WiFi**（模拟器 `adb reverse`、部分平板走 ETHERNET）；
/// 3. debug 可用 `--dart-define=SYNC_NET_OVERRIDE=any` 绕过判定 —— 模拟器经常报不出
///    WiFi，没有这个开关双端冒烟的「自动同步」根本触发不了。**release 恒为真实判定**。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 构建期覆盖（仅 debug 生效）：`any` = 忽略网络类型。
const String kSyncNetOverride = String.fromEnvironment('SYNC_NET_OVERRIDE');

class NetworkInfo {
  const NetworkInfo();

  static const MethodChannel _channel = MethodChannel('yanxin/network');

  Future<bool> isWifi() async {
    if (kDebugMode && kSyncNetOverride == 'any') return true;
    try {
      final bool? value = await _channel.invokeMethod<bool>('isWifi');
      return value ?? false;
    } catch (_) {
      // 通道不可用（测试环境 / 老系统）→ 按「不是 WiFi」处理
      return false;
    }
  }
}

final networkInfoProvider = Provider<NetworkInfo>((Ref _) => const NetworkInfo());
