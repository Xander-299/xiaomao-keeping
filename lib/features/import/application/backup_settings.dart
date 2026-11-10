/// 备份里的「设置」段：换机时把外观 / 首页布局一起带走（P5-A）。
///
/// 为什么要单独一个文件：这份**白名单**是安全边界 —— 只允许同步「用户偏好」，
/// 绝不能让备份把运行态写回本机。写错一个键就可能出现「导入一份旧备份后，
/// 当前账本被切走 / 自动记账队列被覆盖」这种事故。
///
/// 传输格式：`{"dashboard_config": "<原样 JSON 字符串>", "theme_seed": "amber", ...}`
/// 存**原始字符串**而不是结构化对象，理由有两个：
/// 1. 这些键的格式归各自 feature 所有（布局有布局的 schema），备份层不该复制一遍解析逻辑；
/// 2. 前向兼容 —— 新版本加了字段，旧版本 App 导入时原样写回也不会有损。
library;

import 'package:yanxin/core/theme/theme_mode.dart';
import 'package:yanxin/data/repositories/app_meta_repository.dart';
import 'package:yanxin/features/ledger/presentation/dashboard/dashboard_config_controller.dart';
import 'package:yanxin/features/settings/application/theme_controller.dart';

/// 允许随备份走的 `schema_meta` 键。
///
/// ⚠️ 加键前先问三句：① 它是用户偏好还是运行态？② 换机后写回本机会不会让当前状态错乱？
/// ③ 旧版本读到它会不会炸？三关都过才加。
const List<String> kBackupSettingsKeys = <String>[
  kDashboardConfigKey, // 首页模块显隐 / 排序 / 参数
  kThemeSeedKey, // 主题色
  kThemeModeKey, // 外观模式（浅色 / 深色 / 跟随系统）
];

/// ⛔ **明确不随备份走**（写在这里是为了下次有人想加时先看到理由）：
/// - `active_book_id` —— 换机后账本 id 全变了，写回旧 id 等于把用户指到一个空账本；
/// - `autobook_last_run` / `autobook_batches` —— 运行态诊断与待撤销批次，跨设备无意义；
/// - `onboarding_done` —— 「这台机器上是否已看过引导」是设备级状态。

/// 从本机收集要写进备份的设置（缺的键不写）。
Future<Map<String, Object?>> collectBackupSettings(AppMetaRepository meta) async {
  final Map<String, Object?> out = <String, Object?>{};
  for (final String key in kBackupSettingsKeys) {
    try {
      final String? value = await meta.get(key);
      if (value != null && value.trim().isNotEmpty) out[key] = value;
    } catch (_) {
      // 读不到就当没有 —— 备份不能因为一个偏好键读失败而整体失败
    }
  }
  return out;
}

/// 把备份里的设置写回本机，返回**实际写入的键数**。
///
/// 只认白名单内的键、只认字符串值；其余一律忽略（旧备份没有这段 → 返回 0）。
Future<int> applyBackupSettings(
  AppMetaRepository meta,
  Object? rawSettings,
) async {
  if (rawSettings is! Map) return 0;
  var applied = 0;
  for (final String key in kBackupSettingsKeys) {
    final Object? value = rawSettings[key];
    if (value is! String || value.trim().isEmpty) continue;
    try {
      await meta.set(key, value);
      applied++;
    } catch (_) {
      // 单个键写失败不影响其余键，更不影响账本数据恢复
    }
  }
  return applied;
}
