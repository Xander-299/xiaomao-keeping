/// 外观模式的应用状态：读 `schema_meta` 的 `theme_mode`，点选即写。
///
/// 与 `onboarding_done`（F7.14）/ `search_history`（F7.7 D 批）同表 —— 一行键值，
/// **不值得为它动 schema**（DB 仍 schemaVersion 3）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:yanxin/core/providers/settings_dirty.dart';
import 'package:yanxin/core/theme/theme_mode.dart';
import 'package:yanxin/core/theme/theme_seed.dart';
import 'package:yanxin/data/providers/database.dart';

/// `schema_meta` 里存主题色的键。**不存在 = 森绿**（老用户不会被动换色）。
const String kThemeSeedKey = 'theme_seed';

/// 当前外观模式。**默认 `light`**：键不存在 / 读库失败 / 脏数据都回落浅色。
final themeModeProvider =
    AsyncNotifierProvider<ThemeModeController, ToonThemeMode>(
      ThemeModeController.new,
    );

/// 当前主题色。**默认 [ToonSeed.amber]**（与启动图标橙底对齐）。
final themeSeedProvider =
    AsyncNotifierProvider<ThemeSeedController, ToonSeed>(
      ThemeSeedController.new,
    );

class ThemeSeedController extends AsyncNotifier<ToonSeed> {
  @override
  Future<ToonSeed> build() async {
    try {
      final String? raw = await ref
          .watch(appMetaRepositoryProvider)
          .get(kThemeSeedKey);
      return ToonSeed.parse(raw);
    } catch (_) {
      return ToonSeed.amber;
    }
  }

  /// 切换主题色并落库（先切 UI 再写库，写失败本次会话仍生效）。
  Future<void> select(ToonSeed seed) async {
    state = AsyncData<ToonSeed>(seed);
    try {
      final meta = ref.read(appMetaRepositoryProvider);
      await meta.set(kThemeSeedKey, seed.storageValue);
      // 让云同步知道「设置有改动」（P6.4b D4）；失败静默。
      await markSettingsDirty(meta);
    } catch (_) {
      // 静默：外观是低风险偏好，别打断用户
    }
  }
}

class ThemeModeController extends AsyncNotifier<ToonThemeMode> {
  @override
  Future<ToonThemeMode> build() async {
    try {
      final String? raw = await ref
          .watch(appMetaRepositoryProvider)
          .get(kThemeModeKey);
      return ToonThemeMode.parse(raw);
    } catch (_) {
      // 读库失败不能阻断启动：按默认「浅色」走
      return ToonThemeMode.light;
    }
  }

  /// 切换并落库。
  ///
  /// 先切 UI 再写库：写失败时**本次会话仍然生效**（下次冷启动回落旧值），
  /// 不弹错误、不把界面回滚 —— 外观是低风险偏好，打断用户更糟。
  Future<void> select(ToonThemeMode mode) async {
    state = AsyncData<ToonThemeMode>(mode);
    try {
      final meta = ref.read(appMetaRepositoryProvider);
      await meta.set(kThemeModeKey, mode.storageValue);
      // 让云同步知道「设置有改动」（P6.4b D4）；失败静默。
      await markSettingsDirty(meta);
    } catch (_) {
      // 静默：见方法注释
    }
  }
}
