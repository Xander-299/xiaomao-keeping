/// 自动同步触发（P6.4b D1 / D5）。
///
/// 只回答两个问题：**现在该不该跑**、**跑完要不要上传备份**。真正干活的是
/// [`SyncEngine`](sync_engine.dart)（单飞锁就在那边，自动与手动撞车只会跑一次）。
///
/// 为什么触发逻辑不放进 AppShell：壳里已经有引导、自动记账 drain 两件事，
/// 再加三段 if 就没人看得懂了；放这里也便于单测（不依赖 widget）。
///
/// 口径（用户 2026-11-14 裁定）：
/// - 触发点 = **冷启动 + 回前台**，记账当下**不联网**；
/// - **5 分钟节流**：节流键是「上次**尝试**」而不是「上次成功」——
///   用成功后写的 `sync_last_at` 节流，会让「失败 → 每次回前台都重试」变成噪音；
/// - **仅 WiFi**（见 `core/platform/network_info.dart`）；
/// - **失败静默**：只更新状态行，不弹提示、不打断用户。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:yanxin/core/network/sync_api.dart';
import 'package:yanxin/core/network/sync_endpoints.dart';
import 'package:yanxin/core/platform/network_info.dart';
import 'package:yanxin/data/providers/database.dart';
import 'package:yanxin/data/repositories/app_meta_repository.dart';
import 'package:yanxin/features/sync/application/auth_controller.dart';
import 'package:yanxin/features/sync/application/sync_engine.dart';

/// 「上次尝试同步」的 KV 前缀（与 `sync_last_at:` 的区别见文件头）。
const String kSyncLastAttemptKeyPrefix = 'sync_last_attempt:';

final syncTriggerProvider = Provider<SyncTrigger>(SyncTrigger.new);

class SyncTrigger {
  SyncTrigger(this._ref);

  final Ref _ref;

  /// 自动同步的最小间隔。
  static const Duration minInterval = Duration(minutes: 5);

  /// 自动备份的最小间隔。
  static const Duration backupInterval = Duration(hours: 24);

  /// 冷启动 / 回前台调用；不满足条件直接返回 null（**不抛异常**）。
  Future<SyncResult?> maybeSync({required String reason}) async {
    final AuthState? auth = _ref.read(authControllerProvider).value;
    if (auth?.signedIn != true) return null;
    if (_ref.read(cloudSyncEnabledProvider).value != true) return null;
    final SyncStatusState? status = _ref.read(syncStatusProvider).value;
    if (status?.syncing == true) return null;

    // 闸门先过一遍：没登录 / 没开开关 / 占位域名时，别写节流键（否则 5 分钟内都不再试）
    if (!_ref.read(cloudSyncGateProvider).allows(_syncProbe())) return null;

    final AppMetaRepository meta = _ref.read(appMetaRepositoryProvider);
    final String email = auth?.email ?? 'local';
    final String key = '$kSyncLastAttemptKeyPrefix$email';
    final int now = DateTime.now().millisecondsSinceEpoch;
    final int? lastAttempt = int.tryParse((await meta.get(key)) ?? '');
    if (lastAttempt != null && now - lastAttempt < minInterval.inMilliseconds) {
      _log('跳过：距上次尝试不足 ${minInterval.inMinutes} 分钟（$reason）');
      return null;
    }

    if (!await _ref.read(networkInfoProvider).isWifi()) {
      _log('跳过：当前不是 WiFi（$reason）');
      return null;
    }

    await meta.set(key, '$now');
    await _ref.read(syncStatusProvider.notifier).syncNow();
    final SyncStatusState? after = _ref.read(syncStatusProvider).value;
    if (after?.error != null) {
      // 静默：只记日志，状态行自己会显示「同步失败」
      _log('失败（$reason）：${after?.error}');
      return null;
    }
    _log(
      '完成（$reason）：↑${after?.last?.pushed ?? 0} ↓${after?.last?.pulled ?? 0}'
      ' 冲突 ${after?.last?.conflicts ?? 0} 跳过 ${after?.last?.skipped ?? 0}',
    );
    return after?.last;
  }

  /// 冷启动时调用：距上次云端备份 > 24 小时**且**本机有未同步改动 → 静默上传。
  ///
  /// 为什么要有这一步：增量同步≠备份。同步只保证「每行都是最新的」，一旦某笔被误删
  /// 并随同步传播出去，云端也一起没了；真正的保险是全量备份（P6.3）。
  Future<void> maybeAutoBackup() async {
    final AuthState? auth = _ref.read(authControllerProvider).value;
    if (auth?.signedIn != true) return;
    if (_ref.read(cloudSyncEnabledProvider).value != true) return;
    if (!_ref.read(cloudSyncGateProvider).allows(_backupProbe())) return;

    try {
      final BackupInfo? latest = await _ref
          .read(authControllerProvider.notifier)
          .latestBackup();
      if (latest != null &&
          DateTime.now().difference(latest.createdAt) < backupInterval) {
        return;
      }
      if (!await _hasDirtyRows()) return;
      await _ref.read(authControllerProvider.notifier).uploadCurrentBackup();
      _log('已静默上传全量备份');
    } catch (e) {
      // 静默：备份是保险，失败不该打扰用户；下次冷启动再试
      _log('自动备份失败：$e');
    }
  }

  /// 五张业务表里是否还有 `dirty=1` 的行（一有就够）。
  Future<bool> _hasDirtyRows() async {
    final db = _ref.read(appDatabaseProvider);
    final List<Future<List<Object?>>> checks = <Future<List<Object?>>>[
      (db.select(db.books)..where((t) => t.dirty.equals(1))..limit(1)).get(),
      (db.select(db.accounts)..where((t) => t.dirty.equals(1))..limit(1)).get(),
      (db.select(db.categories)..where((t) => t.dirty.equals(1))..limit(1))
          .get(),
      (db.select(db.transactions)..where((t) => t.dirty.equals(1))..limit(1))
          .get(),
      (db.select(db.budgets)..where((t) => t.dirty.equals(1))..limit(1)).get(),
    ];
    for (final Future<List<Object?>> check in checks) {
      if ((await check).isNotEmpty) return true;
    }
    return false;
  }

  Uri _syncProbe() => SyncEndpoints.resolve('/v1/sync/push');

  Uri _backupProbe() => SyncEndpoints.resolve('/v1/backups/latest');

  void _log(String message) {
    if (kDebugMode) debugPrint('[auto-sync] $message');
  }
}
