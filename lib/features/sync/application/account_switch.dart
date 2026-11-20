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

import 'package:yanxin/core/models/email.dart';
import 'package:yanxin/core/network/sync_api.dart';
import 'package:yanxin/core/providers/after_write.dart';
import 'package:yanxin/core/providers/settings_dirty.dart';
import 'package:yanxin/data/providers/database.dart';
import 'package:yanxin/features/import/application/backup_restore.dart';
import 'package:yanxin/features/settings/application/theme_controller.dart';
import 'package:yanxin/features/sync/application/auth_controller.dart';
import 'package:yanxin/features/sync/application/sync_engine.dart';

/// 切号进度阶段（页面据此显示文案）。
enum AccountSwitchStage { backingUp, switching, restoring, pulling }

final accountSwitcherProvider = Provider<AccountSwitcher>(AccountSwitcher.new);

/// 一个切号步骤：进度阶段 + 要做的事。
///
/// 抽出来是为了让「有几步、先后顺序、哪步可能不存在（首次登录没有备份）」一眼看全，
/// 而不是埋在一串 `onStage?..; await ...;` 里。
class _SwitchStep {
  const _SwitchStep(this.stage, this.run);

  final AccountSwitchStage stage;
  final Future<void> Function() run;
}

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
    final Email? oldEmail = before?.signedIn == true ? before?.email : null;
    // ⚠️ 必须 await：刚启动时开关还是 AsyncLoading，读 `.value` 会得到 null；
    // 这时临时 setEnabled(true)，随后 build() 完成又会把状态覆盖回落库值 →
    // 闸门在「恢复备份」那一步判 disabledByUser（真机上表现为切号偶发失败）。
    final bool wasEnabled = await _ref.read(cloudSyncEnabledProvider.future);

    // 切号统一无视开关：临时打开，结束后恢复（否则闸门会在建连前拒掉）。
    if (!wasEnabled) {
      await _ref.read(cloudSyncEnabledProvider.notifier).setEnabled(true);
    }

    // 步骤表：**顺序 = 执行顺序**，每步自带进度阶段。增删一步只改这里，
    // 不用再在 try/catch 里挪代码（回滚仍是统一的：任一步抛都退回原账号）。
    final List<_SwitchStep> steps = <_SwitchStep>[
      // ① 走前备份旧账号（P6.3 全量备份同一套）—— 失败就停在原账号。
      //    没有旧账号（首次登录）时这一步不存在，所以用条件列表而不是 if 包一层。
      if (oldEmail != null)
        _SwitchStep(AccountSwitchStage.backingUp, auth.uploadCurrentBackup),
      // ② 切 session（换 token + 账号列表 + 账本范围）
      _SwitchStep(AccountSwitchStage.switching, () => auth.switchTo(email)),
      // ③ 新账号若在云端有备份，先整份恢复（不受增量 2000 条上限影响）
      _SwitchStep(AccountSwitchStage.restoring, _restoreIfAny),
      // ④ 再拉增量，补齐备份之后的改动
      _SwitchStep(
        AccountSwitchStage.pulling,
        () => _ref.read(syncEngineProvider).bootstrapPull(),
      ),
    ];

    try {
      for (final _SwitchStep step in steps) {
        onStage?.call(step.stage);
        await step.run();
      }
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

  Future<void> _rollback(AuthController auth, Email? oldEmail) async {
    try {
      if (oldEmail != null) {
        await auth.switchTo(oldEmail.value);
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
    // 账本范围 + 数据刷新都走唯一实现（HANDOFF #9），切号这里只多刷一个同步状态。
    refreshAfterAccountChange(_ref);
    _ref.invalidate(syncStatusProvider);
  }
}
