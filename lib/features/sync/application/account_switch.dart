/// 切号编排（P6.5 D5）：走前备份旧账号 → 切 session → 装回新账号数据。
///
/// 为什么要有这一层而不是塞进页面：切号是「多步、可失败、要回滚」的动作，
/// 放进 widget 里就没法单测；这里只依赖 provider，页面只负责画进度。
///
/// 三条硬约束（用户 2026-11-14 裁定）：
/// 1. **无视「云同步」开关**：切号是明确意图 —— 临时打开开关，结束后恢复原值；
/// 2. **失败必须回滚**：备份失败 / 切后拉取失败，都要退回原账号，不能停在半路；
/// 3. **不限 WiFi**：明确动作，网络错就报错回滚，不要静默跳过。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:yanxin/core/network/sync_api.dart';
import 'package:yanxin/core/providers/data_epoch.dart';
import 'package:yanxin/core/providers/settings_dirty.dart';
import 'package:yanxin/data/providers/book_providers.dart';
import 'package:yanxin/data/providers/database.dart';
import 'package:yanxin/features/import/application/backup_restore.dart';
import 'package:yanxin/features/ledger/application/ledger_controller.dart';
import 'package:yanxin/features/settings/application/theme_controller.dart';
import 'package:yanxin/features/stats/application/stats_controller.dart';
import 'package:yanxin/features/sync/application/auth_controller.dart';
import 'package:yanxin/features/sync/application/sync_engine.dart';

/// 切号进度阶段（页面据此显示文案）。
enum AccountSwitchStage { backingUp, switching, restoring, pulling }

final accountSwitcherProvider = Provider<AccountSwitcher>(AccountSwitcher.new);

class AccountSwitcher {
  AccountSwitcher(this._ref);

  final Ref _ref;

  /// 切到 [email]；失败回滚到原账号并抛出原始异常。
  Future<void> switchTo(
    String email, {
    void Function(AccountSwitchStage stage)? onStage,
  }) async {
    final AuthController auth = _ref.read(authControllerProvider.notifier);
    final AuthState? before = _ref.read(authControllerProvider).value;
    final String? oldEmail = before?.signedIn == true ? before?.email : null;
    final bool wasEnabled =
        _ref.read(cloudSyncEnabledProvider).value ?? false;

    // 切号统一无视开关：临时打开，结束后恢复（否则闸门会在建连前拒掉）。
    if (!wasEnabled) {
      await _ref.read(cloudSyncEnabledProvider.notifier).setEnabled(true);
    }

    try {
      if (oldEmail != null) {
        onStage?.call(AccountSwitchStage.backingUp);
        // ① 走前备份旧账号（P6.3 全量备份同一套）—— 失败就停在原账号
        await auth.uploadCurrentBackup();
      }

      onStage?.call(AccountSwitchStage.switching);
      await auth.switchTo(email);

      onStage?.call(AccountSwitchStage.restoring);
      await _restoreIfAny();

      onStage?.call(AccountSwitchStage.pulling);
      await _ref.read(syncEngineProvider).bootstrapPull();

      _refreshAfterSwitch();
    } catch (e) {
      await _rollback(auth, oldEmail);
      rethrow;
    } finally {
      if (!wasEnabled) {
        await _ref.read(cloudSyncEnabledProvider.notifier).setEnabled(false);
      }
    }
  }

  /// 新账号若在云端有备份，先整份恢复（快、且不受增量 2000 条上限影响）。
  Future<void> _restoreIfAny() async {
    final auth = _ref.read(authControllerProvider.notifier);
    try {
      final BackupInfo? latest = await auth.latestBackup();
      if (latest == null) return;
      final bytes = await auth.downloadLatestBackup();
      if (bytes.isEmpty) return;
      await restoreBackupJson(
        _ref.read(appDatabaseProvider),
        bytes: bytes,
        createBook: false,
        restoreSettings: true,
      );
      // 下行恢复会写设置键：别让它们看起来像「本地改动」被再推回去。
      await _ref
          .read(appMetaRepositoryProvider)
          .set(kSettingsSyncedAtKey, '${DateTime.now().millisecondsSinceEpoch}');
      _ref.invalidate(themeModeProvider);
      _ref.invalidate(themeSeedProvider);
    } on SyncApiException catch (e) {
      if (e.code == 'notFound') return; // 云端没备份：正常情况
      rethrow;
    }
  }

  Future<void> _rollback(AuthController auth, String? oldEmail) async {
    try {
      if (oldEmail != null) {
        await auth.switchTo(oldEmail);
      } else {
        await auth.signOut();
      }
      _refreshAfterSwitch();
    } catch (_) {
      // 回滚也失败：至少把内存态切成未登录，不要挂着半个账号
      try {
        await auth.signOut();
      } catch (_) {}
    }
  }

  void _refreshAfterSwitch() {
    _ref.invalidate(activeBookIdProvider);
    _ref.invalidate(bookListProvider);
    _ref.invalidate(currentBookProvider);
    _ref.invalidate(ledgerProvider);
    _ref.invalidate(statsProvider);
    _ref.invalidate(syncStatusProvider);
    _ref.read(dataEpochProvider.notifier).bump();
  }
}
