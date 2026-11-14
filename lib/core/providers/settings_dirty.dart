/// 「设置有本地改动」的记账本（P6.4b D4）。
///
/// 为什么放在 core：写设置的三个控制器（主题模式 / 主题色 / 首页布局）都要在写完后
/// 打一个时间戳，而它们不该反过来依赖 `features/sync`；同步侧只读这两个键即可。
///
/// 两个键的分工：
/// - `settings_updated_at`：本机最后一次**修改**白名单设置的毫秒时间戳；
/// - `settings_synced_at`：最后一次**成功推上去**的那个值。
///
/// 于是「有未同步的设置改动」= `settings_updated_at > settings_synced_at`，
/// 不用给 `schema_meta` 加列（那张表是纯 KV，加列要动 schema 版本）。
library;

import 'package:yanxin/data/repositories/app_meta_repository.dart';

/// 本机最后一次修改白名单设置的毫秒时间戳。
const String kSettingsUpdatedAtKey = 'settings_updated_at';

/// 最后一次成功推上去的 `settings_updated_at` 值。
const String kSettingsSyncedAtKey = 'settings_synced_at';

/// 标记「设置有本地改动」。
///
/// **失败静默**：设置本身已经落库了，最坏情况只是这次改动不上云。
/// 注意这里只写 `settings_updated_at`，**不碰** `settings_synced_at` ——
/// 后者只由同步成功或下行写回时更新。
Future<void> markSettingsDirty(AppMetaRepository meta, {DateTime? at}) async {
  try {
    final int ms = (at ?? DateTime.now()).millisecondsSinceEpoch;
    await meta.set(kSettingsUpdatedAtKey, '$ms');
  } catch (_) {
    // 静默：同步是锦上添花，不能因为一个 KV 写失败而让用户改不了主题
  }
}
