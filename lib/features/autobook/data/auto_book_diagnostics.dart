/// 自动记账的**诊断数据**（F7.15 走查补丁）—— 把「静默失败」变成可归因的状态。
///
/// 这个功能有四个断点，全都不给用户任何反馈：
///   ① 系统有没有把监听服务绑上（`listenerConnected`）
///   ② 服务有没有抓到微信/支付宝的通知（`lastCaptureAtMs` / `capturedTotal` / `skipped*`）
///   ③ Dart 有没有触发消费队列（`lastDrainAtMs` / 队列里的 `pendingCount`）
///   ④ Dart 处理时入账成功还是全被丢/判重复（[AutoBookLastRun]）
///
/// 没有这层信息时，用户与开发者都只能看到「没记上」，无法判断该去开权限、等下次打开、
/// 还是去改解析规则。数据本身不参与记账逻辑。
library;

import 'dart:convert';

/// 「最近一次检查结果」在 `schema_meta` KV 里的键（与 `autobook_batches` / `active_book_id` 同表）。
const String kAutoBookLastRunKey = 'autobook_last_run';

/// 原生侧活性快照（`AutoBookChannel` 的 `diagnostics`）。
class AutoBookDiagnostics {
  const AutoBookDiagnostics({
    required this.listenerConnected,
    required this.lastConnectedAtMs,
    required this.lastCaptureAtMs,
    required this.lastCapturePkg,
    required this.capturedTotal,
    required this.skippedNotWatched,
    required this.skippedEmpty,
    required this.skippedDedup,
    required this.skippedGroupSummary,
    required this.lastDrainAtMs,
    required this.lastDrainCount,
    required this.drainedTotal,
    required this.nowMs,
    this.lastCatchUpAtMs = 0,
    this.lastCatchUpActive = 0,
    this.lastCatchUpAdded = 0,
    this.catchUpTotal = 0,
    this.catchUpAddedTotal = 0,
    this.postedCallbackSeen = false,
    this.lastPostedAtMs = 0,
    this.removedCaptureTotal = 0,
    this.lastRemovedAtMs = 0,
    this.tickCatchUpTotal = 0,
    this.lastTickCatchUpAtMs = 0,
    this.catchUpUnbound = false,
    this.catchUpUnboundTotal = 0,
    this.lastCatchUpUnboundAtMs = 0,
    this.rebindAttempts = 0,
    this.lastRebindAtMs = 0,
    this.lastRebindOk = false,
  });

  /// 系统当前是否绑定着监听服务。
  final bool listenerConnected;

  /// 最近一次被系统绑定的时间（0 = 从未）。
  final int lastConnectedAtMs;

  /// 最近一次成功抓到并入库的通知时间（0 = 从未抓到过）。
  final int lastCaptureAtMs;
  final String lastCapturePkg;

  /// 累计抓到（入队）的条数。
  final int capturedTotal;

  /// 被各层过滤掉的条数 —— 「抓到但没记账」时看这里。
  final int skippedNotWatched;
  final int skippedEmpty;
  final int skippedDedup;

  /// 被丢弃的**组摘要**条目数（`[N条]…`）：聚合通知的汇总条目，丢了才对，
  /// 留着会把同一笔支付记两遍（2026-10-08 真机排查新增）。
  final int skippedGroupSummary;

  /// 最近一次被 Dart 取走队列的时间与条数。
  final int lastDrainAtMs;
  final int lastDrainCount;
  final int drainedTotal;

  /// 最近一次补抓（`getActiveNotifications` 主动拉取）的时间与结果。
  ///
  /// [lastCatchUpActive] = 当时通知栏里的通知总数（0 说明服务没连上）；
  /// [lastCatchUpAdded] = 那一轮补入队的条数。两者用来区分「补抓没跑」与
  /// 「跑了但通知已被撤回、捞不到」。
  final int lastCatchUpAtMs;
  final int lastCatchUpActive;
  final int lastCatchUpAdded;
  final int catchUpTotal;
  final int catchUpAddedTotal;

  // ---------------------------------------------------------------------
  // F7.16 新增：通道可用性（2026-10-09 Redmi K50 实测）
  //
  // 实测结论：`onNotificationPosted` 这个**推送式回调**在部分国产 ROM 上
  // **一条都不投递**，而进程健康、绑定关系仍在 —— 且**重绑也救不了**
  // （disallow→allow 能恢复 onListenerConnected 与补抓，但 posted 仍然 0 条）。
  // 所以实时推送被降级为「可选加速通道」，主防线是补抓守护。
  // ---------------------------------------------------------------------

  /// 本进程内是否**见到过**任何一条 posted 回调（哪怕被过滤/去重掉的）。
  ///
  /// 为 false 且 [lastCaptureAtMs] 也不算太久 → 判定「推送通道不可用，已降级靠补抓」。
  final bool postedCallbackSeen;

  /// 最后一次收到 posted 回调的时刻（0 = 从未收到过）。
  final int lastPostedAtMs;

  /// 撤回通道（`onNotificationRemoved`）累计救回来的条数。
  final int removedCaptureTotal;
  final int lastRemovedAtMs;

  /// 补抓守护（`AlarmManager` 周期任务）已跑过的轮数。
  ///
  /// ⚠️ **长期为 0 = 周期任务被国产 ROM 的后台限制干掉了** ——
  /// 那时主防线也没了，页面必须明确提示用户去关掉后台限制。
  final int tickCatchUpTotal;
  final int lastTickCatchUpAtMs;

  /// 取快照时的设备时间（页面据此算「多久之前」，不依赖端上时钟一致性）。
  final int nowMs;

  // ---------------------------------------------------------------------
  // F7.20 新增：补抓通道的死活（2026-11-19 用户反馈「release 包一条都记不上」）
  //
  // `catchUp` 拿不到服务实例时原生返回 -1。以前 Dart 侧把它折成 0，
  // 「系统没绑定服务」与「通知栏是空的」塌缩成同一个值 —— 页面于是显示
  // 「打开 App 一次就会补记上」，而那条路根本不通。
  // ---------------------------------------------------------------------

  /// 最近一次补抓是否因「系统没绑定监听服务」而失败（原生 `lastCatchUpUnbound`）。
  final bool catchUpUnbound;
  final int catchUpUnboundTotal;
  final int lastCatchUpUnboundAtMs;

  /// 断连后主动 `requestRebind` 的次数与最后一次结果。
  final int rebindAttempts;
  final int lastRebindAtMs;
  final bool lastRebindOk;

  /// 「补抓这条唯一还活着的通道也不通」。
  ///
  /// 判据只有一条：原生侧最近一次 `catchUpNow()` 拿不到实例。
  /// 这比 [listenerLooksDead]（靠历史时间窗推断）直接得多 ——
  /// 系统从未回调过 `onListenerConnected` 时也能判定。
  bool get catchUpChannelDead => catchUpUnbound;

  /// 是否从未抓到过任何通知（判断「服务白开」）。
  bool get neverCaptured => capturedTotal == 0;

  /// 「设置里开着，但系统并未绑定服务」—— 典型的国产 ROM 后台限制表现。
  bool get listenerLooksDead => !listenerConnected && lastConnectedAtMs > 0;

  /// 实时推送通道是否**确定不可用**。
  ///
  /// 判据要保守，三个条件**同时**成立才下结论：
  /// - [lastConnectedAtMs] > 0 —— 得先有观察窗口。从未被绑定过时说什么都是空话，
  ///   那是 [listenerLooksDead] 的职责，混进来会把用户指向错误方向。
  /// - 从绑定起已过 **10 分钟** —— 期间任何一笔支付都足以让 posted 回调出现，
  ///   刚启动的一会儿内不判定，避免误报。
  /// - [postedCallbackSeen] 为 false —— 本进程内一条 posted 回调都没见过。
  bool get postedChannelUnavailable {
    if (postedCallbackSeen || lastConnectedAtMs <= 0) return false;
    return nowMs - lastConnectedAtMs > _kObserveWindowMs;
  }

  /// 「后台唤醒有没有真的生效过」。
  ///
  /// ⚠️ 实测（Redmi K50 / MIUI，2026-10-09）：本机**恒为 false** ——
  /// 闹钟被系统吞、`BroadcastReceiver` 投递被吞（`am broadcast` 还回报 `result=0` 假成功）。
  /// 页面据此如实提示「后台被限制，请打开本 App 一次」，而不是让用户误以为后台在记。
  bool get backgroundWakeWorks => tickCatchUpTotal > 0;

  /// 「有没有足够观测时间」的门槛：10 分钟（[postedChannelUnavailable] 用）。
  static const int _kObserveWindowMs = 10 * 60 * 1000;

  /// 补抓守护是否**疑似被系统限制**（跑过至少一轮，但最近 5 分钟没转过）。
  static AutoBookDiagnostics? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final Map<String, Object?> m = decoded.cast<String, Object?>();
      return AutoBookDiagnostics(
        listenerConnected: m['listenerConnected'] == true,
        lastConnectedAtMs: _asInt(m['lastConnectedAtMs']),
        lastCaptureAtMs: _asInt(m['lastCaptureAtMs']),
        lastCapturePkg: (m['lastCapturePkg'] as String?) ?? '',
        capturedTotal: _asInt(m['capturedTotal']),
        skippedNotWatched: _asInt(m['skippedNotWatched']),
        skippedEmpty: _asInt(m['skippedEmpty']),
        skippedDedup: _asInt(m['skippedDedup']),
        skippedGroupSummary: _asInt(m['skippedGroupSummary']),
        lastDrainAtMs: _asInt(m['lastDrainAtMs']),
        lastDrainCount: _asInt(m['lastDrainCount']),
        drainedTotal: _asInt(m['drainedTotal']),
        nowMs: _asInt(m['nowMs']),
        // ⚠️ 新字段必须有默认值 —— 原生侧比 Dart 旧时不能解析失败
        lastCatchUpAtMs: _asInt(m['lastCatchUpAtMs']),
        lastCatchUpActive: _asInt(m['lastCatchUpActive']),
        lastCatchUpAdded: _asInt(m['lastCatchUpAdded']),
        catchUpTotal: _asInt(m['catchUpTotal']),
        catchUpAddedTotal: _asInt(m['catchUpAddedTotal']),
        postedCallbackSeen: m['postedCallbackSeen'] == true,
        lastPostedAtMs: _asInt(m['lastPostedAtMs']),
        removedCaptureTotal: _asInt(m['removedCaptureTotal']),
        lastRemovedAtMs: _asInt(m['lastRemovedAtMs']),
        tickCatchUpTotal: _asInt(m['tickCatchUpTotal']),
        lastTickCatchUpAtMs: _asInt(m['lastTickCatchUpAtMs']),
        catchUpUnbound: m['lastCatchUpUnbound'] == true,
        catchUpUnboundTotal: _asInt(m['catchUpUnboundTotal']),
        lastCatchUpUnboundAtMs: _asInt(m['lastCatchUpUnboundAtMs']),
        rebindAttempts: _asInt(m['rebindAttempts']),
        lastRebindAtMs: _asInt(m['lastRebindAtMs']),
        lastRebindOk: m['lastRebindOk'] == true,
      );
    } catch (_) {
      return null;
    }
  }
}

/// 「最近一次检查」的结果（落 `schema_meta` KV，跨启动可见）。
///
/// 用户点「检查一次」或 App 自动 drain 后都会写一条 —— 下一次进来能看到上次干了什么，
/// 而不是永远只显示「没有新的支付通知」。
class AutoBookLastRun {
  const AutoBookLastRun({
    required this.atMs,
    this.imported = 0,
    this.duplicates = 0,
    this.dropped = 0,
    this.undone = 0,
    this.restored = false,
    this.error = '',
  });

  const AutoBookLastRun.initial()
    : atMs = 0,
      imported = 0,
      duplicates = 0,
      dropped = 0,
      undone = 0,
      restored = false,
      error = '';

  final int atMs;
  final int imported;
  final int duplicates;

  /// 解析不出而丢弃的条数（非消费通知 / 坏数据 / 命中忽略规则）。
  final int dropped;
  final int undone;

  /// 本次因临时性失败（账本未就绪 / 写库异常）把队列**回写**了，等下次重试。
  final bool restored;

  /// 失败原因（空 = 正常）。
  final String error;

  bool get hasRun => atMs > 0;

  Map<String, Object?> toJson() => <String, Object?>{
    'atMs': atMs,
    'imported': imported,
    'duplicates': duplicates,
    'dropped': dropped,
    'undone': undone,
    'restored': restored,
    'error': error,
  };

  /// 一行摘要（页面直接用）。
  String get summary {
    if (error.isNotEmpty) return '上次检查出错：$error';
    if (!hasRun) return '还没有检查过';
    if (imported > 0) return '上次检查：新入账 $imported 笔';
    if (undone > 0) return '上次检查：撤销 $undone 笔';
    if (restored) return '上次检查：暂时无法入账，已保留待下次重试';
    if (duplicates > 0) return '上次检查：$duplicates 笔已存在（未重复入账）';
    if (dropped > 0) return '上次检查：$dropped 条通知不符合记账条件';
    return '上次检查：没有新的支付通知';
  }

  static AutoBookLastRun? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final Map<String, Object?> m = raw.cast<String, Object?>();
    return AutoBookLastRun(
      atMs: _asInt(m['atMs']),
      imported: _asInt(m['imported']),
      duplicates: _asInt(m['duplicates']),
      dropped: _asInt(m['dropped']),
      undone: _asInt(m['undone']),
      restored: m['restored'] == true,
      error: (m['error'] as String?) ?? '',
    );
  }

  static AutoBookLastRun? parse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return tryFromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }
}

int _asInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}
