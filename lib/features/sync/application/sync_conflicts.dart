/// 同步冲突存档（P6.4b D2）：本机改动被云端覆盖时留一份，可看、可恢复。
///
/// 为什么要有它：默认策略是 LWW「云端更新就覆盖本地」（用户 2026-11-14 裁定
/// 不做「暂停覆盖等用户选」的流程），但那意味着本机那份值**当场消失**。
/// 存档让「被覆盖」从「静默丢失」变成「可查、可恢复」。
///
/// 三条边界：
/// 1. **只在本机**：这张表不上云（失败的那份值本身就不该再同步出去）；
/// 2. **只记「有未同步改动」的行**（`dirty=1`）：覆盖一份本来就干净的行是正常同步，不算冲突；
/// 3. **有上限**：FIFO 保留最近 50 条，用户「恢复 / 忽略」后立即删该行 —— 单机场景下
///    这些行几乎不会被处理，不设上限就会一直躺着。
library;

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/core/providers/data_epoch.dart';
import 'package:yanxin/core/providers/settings_dirty.dart';
import 'package:yanxin/data/providers/database.dart';
import 'package:yanxin/data/repositories/app_meta_repository.dart';
import 'package:yanxin/features/import/application/backup_settings.dart';

/// 存档上限（条）。
const int kSyncConflictLimit = 50;

/// 存档最长保留时间。
const Duration kSyncConflictMaxAge = Duration(days: 30);

/// 写一条冲突存档，并顺手清理过期 / 超量的行。
///
/// 调用点：`SyncEngine._apply*` 在「本机这一行 dirty=1 且即将被云端覆盖」之前。
Future<void> archiveConflict(
  AppDatabase db, {
  required String entity,
  required String bookId,
  required String entityId,
  required int localUpdatedAt,
  required Map<String, Object?> localPayload,
  required int serverUpdatedAt,
  required Map<String, Object?> serverPayload,
}) async {
  final int now = DateTime.now().millisecondsSinceEpoch;
  await db
      .into(db.syncConflicts)
      .insert(
        SyncConflictsCompanion.insert(
          entity: entity,
          entityId: entityId,
          bookId: bookId,
          localUpdatedAt: localUpdatedAt,
          serverUpdatedAt: serverUpdatedAt,
          localPayload: jsonEncode(localPayload),
          serverPayload: jsonEncode(serverPayload),
          createdAt: now,
        ),
      );
  await pruneConflicts(db, now: now);
}

/// 清理：删 30 天前的，再按时间倒序只留最近 [kSyncConflictLimit] 条。
Future<void> pruneConflicts(AppDatabase db, {int? now}) async {
  final int ts = now ?? DateTime.now().millisecondsSinceEpoch;
  await (db.delete(db.syncConflicts)..where(
        (t) => t.createdAt.isSmallerThanValue(
          ts - kSyncConflictMaxAge.inMilliseconds,
        ),
      ))
      .go();
  // 同一毫秒内连写多条时 createdAt 相同，再按 id 兜底保证「留下的一定是更新的」。
  final List<SyncConflictEntry> keep =
      await (db.select(db.syncConflicts)
            ..orderBy(<OrderClauseGenerator<$SyncConflictsTable>>[
              (t) => OrderingTerm.desc(t.createdAt),
              (t) => OrderingTerm.desc(t.id),
            ])
            ..limit(kSyncConflictLimit))
          .get();
  if (keep.length < kSyncConflictLimit) return;
  final int oldestKept = keep.last.id;
  await (db.delete(db.syncConflicts)..where((t) => t.id.isSmallerThanValue(oldestKept)))
      .go();
}

/// 删一条（恢复 / 忽略之后）。
Future<void> deleteConflict(AppDatabase db, int id) async {
  await (db.delete(db.syncConflicts)..where((t) => t.id.equals(id))).go();
}

/// 界面用：「忽略」= 删掉这条存档 + 刷新列表与计数。
Future<void> deleteConflictOnRef(WidgetRef ref, int id) async {
  await deleteConflict(ref.read(appDatabaseProvider), id);
  ref.invalidate(syncConflictCountProvider);
  ref.invalidate(syncConflictsProvider);
}

/// 冲突条数（`/cloud-sync` 页那一行「N 条被云端覆盖」）。
final syncConflictCountProvider = FutureProvider<int>((Ref ref) async {
  final db = ref.watch(appDatabaseProvider);
  final int count = await db.syncConflicts.count().getSingle();
  return count;
});

/// 冲突存档列表（新的在前）。
final syncConflictsProvider = FutureProvider<List<SyncConflictEntry>>((
  Ref ref,
) async {
  final db = ref.watch(appDatabaseProvider);
  return (db.select(db.syncConflicts)
        ..orderBy(<OrderClauseGenerator<$SyncConflictsTable>>[
          (t) => OrderingTerm.desc(t.createdAt),
        ]))
      .get();
});

/// 把某条存档里的**本机版本**写回业务表，并标记为待同步。
///
/// 口径：`updatedAt = now`、`dirty = 1` —— 这样下一轮同步会把它推上去，
/// 而不是当场发请求（用户要的是「记账当下不联网」）。
/// 写回后删掉这条存档；返回是否成功（`setting` 走 KV，同样算成功）。
Future<bool> restoreConflict(WidgetRef ref, SyncConflictEntry entry) async {
  final bool ok = await restoreConflictRows(
    ref.read(appDatabaseProvider),
    ref.read(appMetaRepositoryProvider),
    entry,
  );
  if (!ok) return false;
  ref.invalidate(syncConflictCountProvider);
  ref.invalidate(syncConflictsProvider);
  ref.read(dataEpochProvider.notifier).bump();
  return true;
}

/// 与 [restoreConflict] 同逻辑，但不碰 provider（单测直接用）。
Future<bool> restoreConflictRows(
  AppDatabase db,
  AppMetaRepository meta,
  SyncConflictEntry entry,
) async {
  final Object? decoded = jsonDecode(entry.localPayload);
  if (decoded is! Map) return false;
  final Map<String, Object?> payload = Map<String, Object?>.from(decoded);
  final int now = DateTime.now().millisecondsSinceEpoch;

  try {
    switch (entry.entity) {
      case 'book':
        final Book row = Book.fromJson(payload);
        await db.into(db.books).insertOnConflictUpdate(
              row.toCompanion(false).copyWith(
                    updatedAt: Value(now),
                    dirty: const Value(1),
                  ),
            );
      case 'account':
        final Account row = Account.fromJson(payload);
        await db.into(db.accounts).insertOnConflictUpdate(
              row.toCompanion(false).copyWith(
                    updatedAt: Value(now),
                    dirty: const Value(1),
                  ),
            );
      case 'category':
        final Category row = Category.fromJson(payload);
        await db.into(db.categories).insertOnConflictUpdate(
              row.toCompanion(false).copyWith(
                    updatedAt: Value(now),
                    dirty: const Value(1),
                  ),
            );
      case 'transaction':
        final TxRow row = TxRow.fromJson(payload);
        await db.into(db.transactions).insertOnConflictUpdate(
              row.toCompanion(false).copyWith(
                    updatedAt: Value(now),
                    dirty: const Value(1),
                  ),
            );
      case 'budget':
        final BudgetRow row = BudgetRow.fromJson(payload);
        await db.into(db.budgets).insertOnConflictUpdate(
              row.toCompanion(false).copyWith(
                    updatedAt: Value(now),
                    dirty: const Value(1),
                  ),
            );
      case 'setting':
        await applyBackupSettings(meta, payload);
        await markSettingsDirty(meta);
      default:
        return false;
    }
  } catch (_) {
    // 存档里的 payload 坏了（旧版本 / 手改过）：不写坏数据，让用户自己决定忽略
    return false;
  }

  await deleteConflict(db, entry.id);
  return true;
}
