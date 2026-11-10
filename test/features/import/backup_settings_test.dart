/// P5-A · 设置随备份走（换机恢复外观与首页布局）。
///
/// 三条硬要求：
/// 1. **白名单**：只有外观 / 布局能跟着走，运行态键（`active_book_id` 等）绝不能被备份写回；
/// 2. **可拒绝**：用户选择「只恢复账本」时设置一动不动；
/// 3. **旧备份兼容**：没有 `settings` 段的旧备份导入照常成功，设置保持本机现状。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/core/theme/theme_mode.dart';
import 'package:yanxin/data/repositories/account_repository.dart';
import 'package:yanxin/data/repositories/app_meta_repository.dart';
import 'package:yanxin/data/repositories/book_repository.dart';
import 'package:yanxin/data/repositories/category_repository.dart';
import 'package:yanxin/data/repositories/transaction_repository.dart';
import 'package:yanxin/features/export/application/csv_export.dart';
import 'package:yanxin/features/import/application/backup_restore.dart';
import 'package:yanxin/features/import/application/backup_settings.dart';
import 'package:yanxin/features/ledger/presentation/dashboard/dashboard_config_controller.dart';
import 'package:yanxin/features/settings/application/theme_controller.dart';

import '../../helpers/test_database.dart';

const String _dashConfig = '{"enabled":["month_hero","tx_list"],"order":["tx_list"]}';

Future<String> _backupJson(
  AppDatabase db, {
  Map<String, Object?>? settings,
}) async {
  final BookRepository bookRepo = BookRepository(db);
  final Book book = await bookRepo.ensureDefaultBook();
  return buildBackupJson(
    book: book,
    accounts: await AccountRepository(db).listByBook(book.id),
    categories: await CategoryRepository(db).listByBook(book.id),
    transactions: await TransactionRepository(db).listByBook(book.id),
    budgets: const <BudgetRow>[],
    exportedAtMs: 1_800_000_000_000,
    settings: settings,
  );
}

void main() {
  late AppDatabase db;
  late AppMetaRepository meta;

  setUp(() async {
    db = openTestDatabase();
    addTearDown(db.close);
    meta = AppMetaRepository(db);
  });

  test('导出→导入：外观与布局原样落地，报告计入项数', () async {
    final String json = await _backupJson(
      db,
      settings: <String, Object?>{
        kDashboardConfigKey: _dashConfig,
        kThemeSeedKey: 'forest',
        kThemeModeKey: 'dark',
      },
    );
    // 换一台"新机"：干净的库
    final AppDatabase fresh = openTestDatabase();
    addTearDown(fresh.close);

    expect(backupHasSettings(utf8.encode(json)), isTrue);
    final BackupRestoreReport report = await restoreBackupJson(
      fresh,
      bytes: utf8.encode(json),
      createBook: false,
      restoreSettings: true,
    );

    expect(report.settingsRestored, 3);
    final AppMetaRepository freshMeta = AppMetaRepository(fresh);
    expect(await freshMeta.get(kDashboardConfigKey), _dashConfig);
    expect(await freshMeta.get(kThemeSeedKey), 'forest');
    expect(await freshMeta.get(kThemeModeKey), 'dark');
  });

  test('白名单：运行态键写不进去（备份被手改也不怕）', () async {
    final String json = await _backupJson(
      db,
      settings: <String, Object?>{
        'active_book_id': 'stolen-book-id',
        'autobook_last_run': '{"imported":99}',
        'onboarding_done': '1',
        kThemeModeKey: 'dark',
      },
    );
    final AppDatabase fresh = openTestDatabase();
    addTearDown(fresh.close);

    final BackupRestoreReport report = await restoreBackupJson(
      fresh,
      bytes: utf8.encode(json),
      createBook: false,
      restoreSettings: true,
    );

    expect(report.settingsRestored, 1, reason: '只有 theme_mode 在白名单里');
    final AppMetaRepository freshMeta = AppMetaRepository(fresh);
    expect(await freshMeta.get('active_book_id'), isNull);
    expect(await freshMeta.get('onboarding_done'), isNull);
    expect(await freshMeta.get(kThemeModeKey), 'dark');
  });

  test('用户选「只恢复账本」：设置一动不动', () async {
    final String json = await _backupJson(
      db,
      settings: <String, Object?>{kThemeModeKey: 'dark'},
    );
    final AppDatabase fresh = openTestDatabase();
    addTearDown(fresh.close);
    final AppMetaRepository freshMeta = AppMetaRepository(fresh);
    // 新机原本是浅色
    await freshMeta.set(kThemeModeKey, 'light');

    final BackupRestoreReport report = await restoreBackupJson(
      fresh,
      bytes: utf8.encode(json),
      createBook: false,
      restoreSettings: false,
    );

    expect(report.settingsRestored, 0);
    expect(await freshMeta.get(kThemeModeKey), 'light');
  });

  test('旧备份（没有 settings 段）：导入照常成功，设置不动', () async {
    final String json = await _backupJson(db);
    final AppDatabase fresh = openTestDatabase();
    addTearDown(fresh.close);
    final AppMetaRepository freshMeta = AppMetaRepository(fresh);
    await freshMeta.set(kThemeSeedKey, 'amber');

    expect(backupHasSettings(utf8.encode(json)), isFalse);
    final BackupRestoreReport report = await restoreBackupJson(
      fresh,
      bytes: utf8.encode(json),
      createBook: false,
      restoreSettings: true,
    );

    expect(report.imported, 0, reason: '空账本备份没有流水');
    expect(report.settingsRestored, 0);
    expect(await freshMeta.get(kThemeSeedKey), 'amber');
  });

  test('导出设置：缺键不写空串，值保持原样', () async {
    await meta.set(kThemeModeKey, 'system');
    final Map<String, Object?> collected = await collectBackupSettings(meta);
    expect(collected[kThemeModeKey], 'system');
    expect(collected.containsKey(kThemeSeedKey), isFalse, reason: '没设过就不该出现');
  });

  test('写在备份里的 dashboard_config 能被 DashboardConfig 解析', () async {
    // 防止「备份里存了布局、恢复后读不出来」这种半截兼容
    final String json = await _backupJson(
      db,
      settings: <String, Object?>{kDashboardConfigKey: _dashConfig},
    );
    final Map<String, Object?> payload =
        jsonDecode(json) as Map<String, Object?>;
    expect(payload['settings'], isA<Map<String, Object?>>());
    final String raw =
        (payload['settings'] as Map<String, Object?>)[kDashboardConfigKey]!
            as String;
    final Map<String, Object?> decoded =
        jsonDecode(raw) as Map<String, Object?>;
    expect(decoded['order'], <String>['tx_list']);
  });
}
