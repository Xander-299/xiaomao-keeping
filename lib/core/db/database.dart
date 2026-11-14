/// drift 数据库入口（schema **v5**）。
///
/// 版本号由 drift 托管（写进 `PRAGMA user_version`）；`schema_meta` 表保留
/// 用于 KV 持久化（如 active_book_id），与旧栈 DDL 一致（ADR-8）。
///
/// v1 → v2 只做**加表**：新增 `budgets`（月度预算）+ 一条部分唯一索引。
/// v2 → v3 只做**加列**：`accounts.icon` / `accounts.color`。
/// v3 → v4 只做**加列**：`categories.parent_id` / `categories.is_archived`。
/// v4 → v5 只**替换索引**：流水指纹唯一性从全局收紧为 `(book_id, fingerprint)`，
/// 不重建表、不改任何既有行（Batch A / A1）。
library;

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../constants/preset.dart';
import 'schema_v1.dart';
import 'schema_v2.dart';
import 'schema_v4.dart';
import 'schema_v5.dart';
import 'schema_v6.dart';
import 'tables.dart';

part 'database.g.dart';

@DriftDatabase(
  tables: [
    SchemaMeta,
    Books,
    Accounts,
    Categories,
    Transactions,
    Budgets,
    SyncConflicts,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 6;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          // drift 声明式建表表达不了 DESC / 部分索引 → 索引走原始 SQL，
          // 保证与旧库 v1 完全一致（ADR-8）。
          for (final sql in kSchemaV1Indexes) {
            await customStatement(sql);
          }
          for (final sql in kSchemaV2Indexes) {
            await customStatement(sql);
          }
          for (final sql in kSchemaV4Indexes) {
            await customStatement(sql);
          }
          // v5 替换 v1 的全局指纹索引；新库也走同一份 DDL，保证「新建 = 升级后」。
          for (final sql in kSchemaV5Indexes) {
            await customStatement(sql);
          }
          // v6：冲突存档表由 createAll 建好，只差索引。
          for (final sql in kSchemaV6Indexes) {
            await customStatement(sql);
          }
        },
        onUpgrade: (m, int from, int to) async {
          if (from < 2) {
            // 只加表：不动 v1 五张表，老库数据零风险。
            await m.createTable(budgets);
            for (final sql in kSchemaV2Indexes) {
              await customStatement(sql);
            }
          }
          if (from < 3) {
            // 只加列：带 DEFAULT ''，不改任何既有行（零数据风险）。
            // 防御半迁移态（如 v1→v2 升级中断后重试）：列已存在则跳过。
            if (!await _columnExists('accounts', 'icon')) {
              await m.addColumn(accounts, accounts.icon);
            }
            if (!await _columnExists('accounts', 'color')) {
              await m.addColumn(accounts, accounts.color);
            }
          }
          if (from < 4) {
            // 分类两级 + 归档：同样**只加列**（parent_id 可空、is_archived 默认 0），
            // 既有行一个字节都不改；随后按分类名回填图标 key（只写 icon 为空的行）。
            if (!await _columnExists('categories', 'parent_id')) {
              await m.addColumn(categories, categories.parentId);
            }
            if (!await _columnExists('categories', 'is_archived')) {
              await m.addColumn(categories, categories.isArchived);
            }
            for (final sql in kSchemaV4Indexes) {
              await customStatement(sql);
            }
            await _backfillCategoryIcons();
          }
          if (from < 5) {
            // v5：只替换索引，不重建表、不改既有行。
            // 旧库的 idx_tx_fingerprint 是全局唯一；先 DROP 再按 (book_id, fingerprint) 建。
            for (final sql in kSchemaV5Indexes) {
              await customStatement(sql);
            }
          }
          if (from < 6) {
            // v6：只加表 + 索引（P6.4b D2）。历史冲突无法回溯，新表从空开始。
            await m.createTable(syncConflicts);
            for (final sql in kSchemaV6Indexes) {
              await customStatement(sql);
            }
          }
        },
      );

  /// 查某表是否已有某列（PRAGMA table_info）。
  Future<bool> _columnExists(String table, String column) async {
    final rows = await customSelect('PRAGMA table_info($table)').get();
    return rows.any((row) => row.read<String>('name') == column);
  }

  /// v3 → v4：按**分类名**回填稳定 icon key（只写 icon 为空的行）。
  ///
  /// 老库的 `categories.icon` 一直是空串（v3 之前没人用），所以这里可以放心写；
  /// 名字对不上（用户改过名 / 自定义分类）就保持空串 —— 界面会按收支方向给默认图标。
  /// 老名字（理财 / 红包 / 人情）也一并映射，避免升级后图标全空。
  Future<void> _backfillCategoryIcons() async {
    const Map<String, String> oldNames = <String, String>{
      '理财': 'invest',
      '红包': 'redpacket',
      '人情': 'social',
    };
    final List<(String name, String icon, String kind)> pairs =
        <(String, String, String)>[
          for (final PresetCategory c in presetExpense) (c.name, c.iconKey, 'expense'),
          for (final PresetCategory c in presetIncome) (c.name, c.iconKey, 'income'),
          for (final MapEntry<String, String> e in oldNames.entries)
            (e.key, e.value, e.key == '人情' ? 'expense' : 'income'),
        ];
    for (final (String name, String icon, String kind) in pairs) {
      await customStatement(
        'UPDATE categories SET icon = ? WHERE name = ? AND kind = ? '
        "AND (icon IS NULL OR icon = '')",
        <Object?>[icon, name, kind],
      );
    }
  }
}

/// App 侧默认打开方式：数据落在应用数据目录 `yanxin.sqlite`。
///
/// drift_flutter 负责在 Android 上带上 sqlite3 native 库。
AppDatabase openAppDatabase() => AppDatabase(driftDatabase(name: 'yanxin'));
