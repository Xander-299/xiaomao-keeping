/// 「后台常驻」开关（F7.22）。
///
/// 状态落 `schema_meta`（键 [kAutoBookKeepAliveKey]），默认**关**：
/// 打开后系统会常驻一条低优先级通知，让监听服务尽量不被回收 ——
/// 这是用户的选择，不是默认行为。
///
/// 开关本身不判断「能不能跑」（系统可能因为后台限制不让我们起前台服务），
/// 页面上另起一行显示原生侧的真实状态（`keepAliveRunning`）。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:yanxin/data/providers/database.dart';

import '../data/auto_book_bridge.dart';

/// `schema_meta` 键：用户是否打开了后台常驻。
const String kAutoBookKeepAliveKey = 'autobook_keepalive';

final autoBookKeepAliveProvider =
    AsyncNotifierProvider<AutoBookKeepAlive, bool>(AutoBookKeepAlive.new);

class AutoBookKeepAlive extends AsyncNotifier<bool> {
  @override
  Future<bool> build() async {
    try {
      final String? raw = await ref
          .read(appMetaRepositoryProvider)
          .get(kAutoBookKeepAliveKey);
      return raw == '1';
    } catch (_) {
      return false;
    }
  }

  /// 切换开关：先写库再动原生服务（写失败也要让本次会话生效，与主题控制器同口径）。
  Future<void> setEnabled(bool value) async {
    state = AsyncData<bool>(value);
    try {
      await ref
          .read(appMetaRepositoryProvider)
          .set(kAutoBookKeepAliveKey, value ? '1' : '0');
    } catch (e) {
      debugPrint('[keepalive] 落库失败（本次会话仍生效）：$e');
    }
    await _apply(value);
  }

  /// 冷启动 / 回前台：开关为开时**幂等**确保服务在跑（不会叠通知）。
  Future<void> ensureRunning() async {
    final bool enabled = state.value ?? await future;
    if (!enabled) return;
    await _apply(true);
  }

  Future<void> _apply(bool enabled) async {
    final AutoBookBridge bridge = ref.read(autoBookBridgeProvider);
    try {
      if (enabled) {
        await bridge.startKeepAlive();
      } else {
        await bridge.stopKeepAlive();
      }
    } catch (e) {
      // 非 Android / 系统拒绝：常驻只是加强项，不阻断任何流程
      debugPrint('[keepalive] 原生调用失败：$e');
    }
  }
}
