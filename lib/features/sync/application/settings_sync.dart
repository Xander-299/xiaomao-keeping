/// 设置同步（P6.4b D4）：白名单三键走 `sync_changes` 的 `entity=setting`。
///
/// 为什么复用 `/v1/sync/push` 而不是另开端点：LWW、游标、墓碑、分批都已经在那里，
/// 另开一套等于再写一遍同样的逻辑、多一套错误码与游标（用户 2026-11-14 裁定）。
///
/// **只有「用户偏好」能进来**，白名单与备份共用同一份 `kBackupSettingsKeys`：
/// 两份清单必然漂移，而漂移的后果是把 `active_book_id` 这种**换机即错**的键带过去。
/// 加键前先看 [`kBackupSettingsKeys`] 上面的三条自问。
///
/// 时间戳为什么不在 `schema_meta` 里加列：那张表是 KV，加列要动 schema；
/// 用两个键（`settings_updated_at` / `settings_synced_at`）就能表达
/// 「本机改过 / 已经推上去过」，且 `settings_updated_at > settings_synced_at` 天然就是 dirty 判定。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:yanxin/core/network/sync_api.dart';
import 'package:yanxin/core/providers/settings_dirty.dart';
import 'package:yanxin/data/repositories/app_meta_repository.dart';
import 'package:yanxin/features/import/application/backup_settings.dart';
import 'package:yanxin/features/ledger/presentation/dashboard/dashboard_config_controller.dart';
import 'package:yanxin/features/settings/application/theme_controller.dart';

/// 同步协议里的 entity 名与哨兵 id（服务端 `SYNC_ENTITIES` 里也叫 `setting`）。
const String kSettingsEntity = 'setting';
const String kSettingsGlobalId = 'global';

/// 读本机设置 → 生成一条待推送的 `SyncChange`；没有改动返回 null。
Future<SyncChange?> buildSettingsChange(AppMetaRepository meta) async {
  final int? updated = int.tryParse(
    (await meta.get(kSettingsUpdatedAtKey)) ?? '',
  );
  if (updated == null) return null;
  final int? synced = int.tryParse(
    (await meta.get(kSettingsSyncedAtKey)) ?? '',
  );
  if (synced != null && synced >= updated) return null;
  final Map<String, Object?> values = await collectBackupSettings(meta);
  if (values.isEmpty) return null;
  return SyncChange(
    bookId: kSettingsGlobalId,
    entity: kSettingsEntity,
    id: kSettingsGlobalId,
    updatedAt: updated,
    deleted: false,
    payload: values,
  );
}

/// 应用服务端下行的设置（LWW：本机更新就跳过），返回是否真的写回。
///
/// ⚠️ 写回后**必须**把 `settings_updated_at` 也设成服务端那个值：
/// 否则下一轮 `buildSettingsChange` 会把「刚收到的远端值」当成新的本地改动再推回去，
/// 两台设备之间会来回弹。
Future<bool> applySettingsChange(
  AppMetaRepository meta,
  SyncChange change,
) async {
  final int localUpdated =
      int.tryParse((await meta.get(kSettingsUpdatedAtKey)) ?? '') ?? 0;
  if (localUpdated > change.updatedAt) return false;
  final int applied = await applyBackupSettings(meta, change.payload);
  await meta.set(kSettingsUpdatedAtKey, '${change.updatedAt}');
  await meta.set(kSettingsSyncedAtKey, '${change.updatedAt}');
  return applied > 0;
}

/// 标记设置已推送成功。
///
/// 取**较大值**：如果这一轮先应用了服务端更新的设置（`updated_at` 已被改成服务端那个），
/// 再用本轮被推上去的旧时间戳覆盖 `synced`，会留下一段「看起来还没同步」的窗口，
/// 下一轮白白再推一次。
Future<void> markSettingsSynced(
  AppMetaRepository meta,
  int updatedAt,
) async {
  try {
    final int current =
        int.tryParse((await meta.get(kSettingsSyncedAtKey)) ?? '') ?? 0;
    final int next = updatedAt > current ? updatedAt : current;
    await meta.set(kSettingsSyncedAtKey, '$next');
  } catch (_) {
    // 静默：下次同步会再推一遍（服务端幂等）
  }
}

/// 下行写回设置后刷新三个 AsyncNotifier。
///
/// 不刷新的话界面「看着还是旧主题」—— P5 备份恢复时踩过同一个坑。
void invalidateSettingsProviders(Ref ref) {
  ref.invalidate(themeModeProvider);
  ref.invalidate(themeSeedProvider);
  ref.invalidate(dashboardConfigProvider);
}
