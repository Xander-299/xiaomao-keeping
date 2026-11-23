/// 自动记账的平台通道封装（F7.15 SPEC §3.2 / §3.7）。
///
/// Kotlin 侧实现见 `android/app/src/main/kotlin/com/teacodeman/yanxin/autobook/AutoBookChannel.kt`。
///
/// **降级铁律**：非 Android（含本机 widget 测试）或任何通道异常（`MissingPluginException`
/// / `PlatformException`）→ 全部返回安全默认值，**绝不抛给调用方**，绝不阻断冷启动。
/// 因此 `drain()` 在桌面测试环境里就是「空队列」，什么都不发生。
///
/// 方法都可被子类覆写 —— 测试里用假实现（`FakeAutoBookBridge`）替换整条 Native 链路。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auto_book_diagnostics.dart';

/// 通道名（与 Kotlin 侧 `AutoBookChannel.NAME` 必须一致）。
const String kAutoBookChannelName = 'yanxin/autobook';

/// 回执通知里「撤销」按钮的动作值（与 Kotlin `AutoBookNotifier.ACTION_UNDO` 一致）。
const String kAutoBookActionUndo = 'undo';

class AutoBookBridge {
  AutoBookBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(kAutoBookChannelName);

  final MethodChannel _channel;

  /// 是否在受支持的平台（只有 Android 有这条原生链路）。
  bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 「通知使用权」是否已开启。
  Future<bool> listenerEnabled() async =>
      (await _invoke<bool>('permissionStatus')) ?? false;

  /// 通知是否允许（Android 13+ 还要求 POST_NOTIFICATIONS 运行时权限）。
  Future<bool> notificationsAllowed() async =>
      (await _invoke<bool>('notificationPermissionStatus')) ?? false;

  /// 申请通知权限（Android 13+；低版本是空操作）。
  Future<void> requestNotificationPermission() async {
    await _invoke<Object?>('requestNotificationPermission');
  }

  /// 跳到系统「通知使用权」设置页。
  Future<void> openListenerSettings() async {
    await _invoke<Object?>('openNotificationSettings');
  }

  /// 跳到本 App 的通知设置页（通知权限被拒后的兜底入口）。
  Future<void> openAppNotificationSettings() async {
    await _invoke<Object?>('openAppNotificationSettings');
  }

  /// 取走落盘队列（原始 JSONL 行，Dart 侧自行解析/丢弃坏行）。
  Future<List<String>> drainQueue() async {
    final Object? res = await _invoke<Object?>('drainQueue');
    if (res is List) {
      return res
          .map((Object? e) => e?.toString() ?? '')
          .where((String s) => s.isNotEmpty)
          .toList();
    }
    return const <String>[];
  }

  /// **补抓**：把通知栏里仍存在、但原生侧当时没接到的通知补入队。
  ///
  /// 为什么必须有：`onNotificationPosted` 是推送式回调，**通知在服务未连接期间发布时
  /// 系统不会补发** —— 真机实测支付宝付款通知发布早于服务连接 1 分 51 秒，那笔支付
  /// 永久丢失，且界面上完全看不出来。
  ///
  /// ⚠️ **必须在 [drainQueue] 之前调用**（补抓是往队列里写，取队列在后面）。
  ///
  /// @return 补入队条数；**`-1` = 补抓通道不通**（系统没有把监听服务绑上）；
  ///   非 Android / 通道异常 → 0（那才是「没有可补的」）。
  ///
  /// ⚠️ **不要把 `-1` 折成 0**（F7.20，2026-11-19）：「服务没绑定」与「通知栏是空的」
  /// 是两件事，折起来以后页面只能看到 0，于是把「一条都记不上」解释成「今天没支付」。
  /// 诊断侧另有 `lastCatchUpUnbound` 落盘，这里保留原始值只是为了让调用方可断言。
  Future<int> catchUp() async {
    final Object? res = await _invoke<Object?>('catchUp');
    if (res is int) return res;
    return 0;
  }

  /// 临时性失败时把原始行**放回原生队列**（等下次重试）。
  ///
  /// 不这么做的话「取走即清空」会让这批通知永久消失 —— 冷启动首帧账本未就绪、
  /// 写库抛异常等场景都会命中。
  Future<void> restoreQueue(List<String> lines) async {
    if (lines.isEmpty) return;
    await _invoke<Object?>('restoreQueue', <String, Object?>{'lines': lines});
  }

  /// 补抓守护（`AlarmManager` 周期任务）的排期。
  ///
  /// 为什么需要 App 侧也调一次：守护闹钟是**一次性 + 每次醒来续期**的
  /// （不用 `setRepeating` —— 它在 doze 里被静默丢弃后会永久停摆，实测踩过）。
  /// 而进程被杀后没人续期 → 每次 App 启动 / 每次进前台都补一次排期，
  /// 让「进程活着期间守护一定在转」成为不变量。
  Future<void> ensureGuardScheduled() async {
    await _invoke<Object?>('ensureGuard');
  }

  /// 打开「后台常驻」前台服务（幂等）。
  ///
  /// 为什么需要：支付通知来的时候 App 可能不在后台 —— 监听服务与 UI 同进程，
  /// 系统一回收进程，通知就进不了落盘队列，重开也补不回来（公开 SDK 没有历史通知接口）。
  Future<void> startKeepAlive() async {
    await _invoke<Object?>('keepAliveStart');
  }

  Future<void> stopKeepAlive() async {
    await _invoke<Object?>('keepAliveStop');
  }

  /// 常驻服务当前是否在跑（用于页面状态行）。
  Future<bool> keepAliveRunning() async =>
      (await _invoke<bool>('keepAliveStatus')) ?? false;

  /// 系统是否已对本 App 忽略省电优化（false = 随时可能被回收）。
  Future<bool> batteryOptimizationIgnored() async =>
      (await _invoke<bool>('batteryOptimizationIgnored')) ?? false;

  /// 跳到系统的「省电优化」页；返回是否成功打开。
  Future<bool> openBatterySettings() async =>
      (await _invoke<bool>('openBatterySettings')) ?? false;

  /// 跳到「自启动」设置（MIUI 专属页，其它 ROM 退应用详情页）。
  Future<bool> openAutoStartSettings() async =>
      (await _invoke<bool>('openAutoStartSettings')) ?? false;

  /// 原生侧活性快照（服务是否被绑定 / 抓到过几条 / 上次 drain 情况）。
  /// 非 Android 或通道异常 → null（页面按「不可用」展示）。
  Future<AutoBookDiagnostics?> diagnostics() async {
    final Object? res = await _invoke<Object?>('diagnostics');
    if (res is String) return AutoBookDiagnostics.tryParse(res);
    return null;
  }

  /// 未处理条数（「识别到 N 笔」）。
  Future<int> pendingCount() async =>
      (await _invoke<int>('pendingCount')) ?? 0;

  /// 取走通知按钮落下的命令（读后即删）；无命令返回 null。
  Future<String?> takeCommand() => _invoke<String>('takeCommand');

  /// 更新为「已自动记账 N 笔」回执（含 `撤销` / `查看` 两个按钮）。
  Future<void> showReceipt({
    required int count,
    required String amountText,
    required String batchId,
    List<String> lines = const <String>[],
  }) async {
    await _invoke<Object?>('showReceipt', <String, Object?>{
      'count': count,
      'amountText': amountText,
      'batchId': batchId,
      'lines': lines,
    });
  }

  /// 收起当前那条自动记账通知（无新增入账时也用它清掉「识别到 N 笔」）。
  Future<void> cancelReceipt() async {
    await _invoke<Object?>('cancelReceipt');
  }

  Future<T?> _invoke<T>(String method, [Object? args]) async {
    if (!supported) return null;
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    } catch (_) {
      // 原生侧任何意外都不得影响记账主流程
      return null;
    }
  }
}

/// 平台通道（测试里 override 成假实现）。
final autoBookBridgeProvider = Provider<AutoBookBridge>(
  (Ref ref) => AutoBookBridge(),
);
