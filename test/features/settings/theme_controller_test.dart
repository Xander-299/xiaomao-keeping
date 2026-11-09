/// 外观模式的应用状态（F7.17）：默认 / 点选落库 / 冷启动沿用 / 脏数据容错。
///
/// 与 `search_history_test.dart` 同一套路：内存库 + `ProviderContainer` 直读，
/// 不 pump widget（控制器本身与 UI 无关）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/core/theme/theme_mode.dart';
import 'package:yanxin/core/theme/theme_seed.dart';
import 'package:yanxin/data/providers/database.dart';
import 'package:yanxin/data/repositories/app_meta_repository.dart';
import 'package:yanxin/features/settings/application/theme_controller.dart';

import '../../helpers/test_database.dart';

void main() {
  group('ThemeModeController', () {
    test('默认 = 浅色，且**不写库**（老用户覆盖安装不被写死）', () async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);

      expect(await container.read(themeModeProvider.future), ToonThemeMode.light);
      expect(await AppMetaRepository(db).get(kThemeModeKey), isNull);
    });

    test('select 先切 UI 再落库；新 container（= 冷启动）读回同一个值', () async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);

      await container.read(themeModeProvider.future);
      await container.read(themeModeProvider.notifier).select(ToonThemeMode.dark);
      expect(container.read(themeModeProvider).value, ToonThemeMode.dark);
      expect(await AppMetaRepository(db).get(kThemeModeKey), 'dark');

      // 再切一次：覆盖同一行，不新增
      await container.read(themeModeProvider.notifier).select(ToonThemeMode.light);
      expect(await AppMetaRepository(db).get(kThemeModeKey), 'light');

      // 冷启动
      final cold = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(db)],
      );
      addTearDown(cold.dispose);
      expect(await cold.read(themeModeProvider.future), ToonThemeMode.light);
    });

    test('库里是脏值 → 回落跟随系统（不让 App 起不来）', () async {
      final db = openTestDatabase();
      addTearDown(db.close);
      await AppMetaRepository(db).set(kThemeModeKey, 'amoled');

      final container = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      expect(await container.read(themeModeProvider.future), ToonThemeMode.light);
    });

    test('读库失败 → 仍返回 system，不抛（外观是低风险偏好，不能阻断启动）', () async {
      // 库关闭后再读：drift 会抛，控制器必须吞掉
      final db = openTestDatabase();
      await db.close();

      final container = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      expect(await container.read(themeModeProvider.future), ToonThemeMode.light);
    });
  });

  // 2026-10-29：主题色（品牌 seed）
  group('ThemeSeedController', () {
    test('默认 = 琥珀，且不写库（老用户不会被动换色）', () async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);

      expect(await container.read(themeSeedProvider.future), ToonSeed.amber);
      expect(await AppMetaRepository(db).get(kThemeSeedKey), isNull);
    });

    test('select 先切 UI 再落库；冷启动读回同一个值', () async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);

      await container.read(themeSeedProvider.future);
      await container.read(themeSeedProvider.notifier).select(ToonSeed.indigo);
      expect(container.read(themeSeedProvider).value, ToonSeed.indigo);
      expect(await AppMetaRepository(db).get(kThemeSeedKey), 'indigo');

      final cold = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(db)],
      );
      addTearDown(cold.dispose);
      expect(await cold.read(themeSeedProvider.future), ToonSeed.indigo);
    });

    test('脏值 / 未知名字 → 回落琥珀', () async {
      final db = openTestDatabase();
      addTearDown(db.close);
      await AppMetaRepository(db).set(kThemeSeedKey, 'neon-pink');

      final container = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      expect(await container.read(themeSeedProvider.future), ToonSeed.amber);
    });
  });
}
