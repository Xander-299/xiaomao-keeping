/// P6.4 双向同步引擎（第一版：手动增量同步）。
///
/// 数据流：
/// 1. 扫所有本机账本里 `dirty=1` 的行 → 分批 push；
/// 2. 服务端按 LWW 决定收不收；返回的 `conflicts`（服务端较新）立即应用；
/// 3. 从本机 cursor 起循环 pull，直到 `hasMore=false`；
/// 4. 应用下行时 `dirty=0`（不制造第二条写库路径），本地较新的行跳过、等下次 push 赢。
///
/// 明确不做（第一阶段）：自动触发、settings 同步、字段级合并。
library;

import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/core/network/cloud_sync_gate.dart';
import 'package:yanxin/core/network/sync_api.dart';
import 'package:yanxin/core/providers/data_epoch.dart';
import 'package:yanxin/data/providers/database.dart';
import 'package:yanxin/features/sync/application/auth_controller.dart';

/// 一次同步的结果（页面展示用）。
class SyncResult {
  const SyncResult({
    required this.at,
    required this.pushed,
    required this.pulled,
    required this.conflicts,
    required this.skipped,
  });

  final DateTime at;
  final int pushed;
  final int pulled;
  final int conflicts;
  final int skipped;
}

/// 同步状态。
class SyncStatusState {
  const SyncStatusState({
    this.lastSyncAt,
    this.last,
    this.syncing = false,
    this.error,
  });

  final DateTime? lastSyncAt;
  final SyncResult? last;
  final bool syncing;
  final String? error;

  SyncStatusState copyWith({
    DateTime? lastSyncAt,
    SyncResult? last,
    bool? syncing,
    String? error,
  }) => SyncStatusState(
    lastSyncAt: lastSyncAt ?? this.lastSyncAt,
    last: last ?? this.last,
    syncing: syncing ?? this.syncing,
    error: error,
  );
}

final syncEngineProvider = Provider<SyncEngine>(SyncEngine.new);

/// 同步状态 + 手动触发。
final syncStatusProvider =
    AsyncNotifierProvider<SyncStatusController, SyncStatusState>(
      SyncStatusController.new,
    );

class SyncStatusController extends AsyncNotifier<SyncStatusState> {
  @override
  Future<SyncStatusState> build() async {
    final String? email = ref.watch(authControllerProvider).value?.email;
    if (email == null) return const SyncStatusState();
    final String? raw = await ref
        .read(appMetaRepositoryProvider)
        .get(_syncLastAtKey(email));
    final int? ms = int.tryParse(raw ?? '');
    return SyncStatusState(
      lastSyncAt: ms == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(ms),
    );
  }

  /// 手动同步；错误写进 state（页面显示），不抛给 UI 层。
  Future<void> syncNow() async {
    if (state.value?.syncing == true) return;
    final SyncStatusState prev = state.value ?? const SyncStatusState();
    state = AsyncData<SyncStatusState>(prev.copyWith(syncing: true, error: null));
    try {
      final SyncResult result = await ref.read(syncEngineProvider).syncNow();
      state = AsyncData<SyncStatusState>(
        SyncStatusState(
          lastSyncAt: result.at,
          last: result,
          syncing: false,
        ),
      );
    } on Object catch (e) {
      state = AsyncData<SyncStatusState>(
        prev.copyWith(syncing: false, error: _describe(e)),
      );
    }
  }

  String _describe(Object error) => switch (error) {
    SyncDeniedException(:final CloudSyncDenial denial) => denial.label,
    SyncApiException(:final String userMessage) => userMessage,
    _ => '同步失败，请稍后重试',
  };
}

const String kSyncCursorKeyPrefix = 'sync_cursor:';
const String kSyncLastAtKeyPrefix = 'sync_last_at:';

String _cursorKey(String email) => '$kSyncCursorKeyPrefix$email';
String _syncLastAtKey(String email) => '$kSyncLastAtKeyPrefix$email';

class SyncEngine {
  SyncEngine(this._ref);

  final Ref _ref;

  /// 推本机 dirty 行 → 应用 conflicts → 从 cursor 拉取并应用。
  Future<SyncResult> syncNow() async {
    final AuthState? auth = _ref.read(authControllerProvider).value;
    if (auth?.signedIn != true) {
      throw const SyncApiException('unauthorized', statusCode: 401);
    }
    final String email = auth?.email ?? 'local';
    final AppDatabase db = _ref.read(appDatabaseProvider);
    final meta = _ref.read(appMetaRepositoryProvider);
    final SyncApi api = _ref.read(syncApiProvider);

    int cursor = int.tryParse(await meta.get(_cursorKey(email)) ?? '') ?? 0;
    int pushed = 0;
    int pulled = 0;
    int skipped = 0;
    int conflicts = 0;

    await _ref
        .read(authControllerProvider.notifier)
        .authorized((String token) async {
          final List<SyncChange> dirty = await _collectDirty(db);
          for (int i = 0; i < dirty.length; i += 200) {
            final List<SyncChange> chunk = dirty.sublist(
              i,
              math.min(i + 200, dirty.length),
            );
            final SyncPushResult res = await api.pushChanges(
              accessToken: token,
              changes: chunk,
            );
            pushed += res.applied;
            for (final SyncChange serverRow in res.conflicts) {
              conflicts++;
              if (await _apply(db, serverRow)) {
                pulled++;
              } else {
                skipped++;
              }
            }
            for (final SyncChange change in chunk) {
              await _markClean(db, change);
            }
          }

          bool hasMore = true;
          int guard = 0;
          while (hasMore && guard++ < 10) {
            final SyncPullResult page = await api.pullChanges(
              accessToken: token,
              since: cursor,
            );
            for (final SyncChange change in page.changes) {
              if (await _apply(db, change)) {
                pulled++;
              } else {
                skipped++;
              }
            }
            cursor = page.cursor;
            hasMore = page.hasMore;
            await meta.set(_cursorKey(email), '$cursor');
          }
        });

    final DateTime now = DateTime.now();
    await meta.set(_syncLastAtKey(email), '${now.millisecondsSinceEpoch}');
    _ref.read(dataEpochProvider.notifier).bump();
    return SyncResult(
      at: now,
      pushed: pushed,
      pulled: pulled,
      conflicts: conflicts,
      skipped: skipped,
    );
  }

  // ── 上行：收集 dirty 行 ─────────────────────────────────────────────

  Future<List<SyncChange>> _collectDirty(AppDatabase db) async {
    final List<SyncChange> out = <SyncChange>[];

    final books = await (db.select(
      db.books,
    )..where((t) => t.dirty.equals(1))).get();
    for (final Book row in books) {
      out.add(
        SyncChange(
          bookId: row.id,
          entity: 'book',
          id: row.id,
          updatedAt: row.updatedAt,
          deleted: row.deletedAt != null,
          payload: row.toJson(),
        ),
      );
    }

    final accounts = await (db.select(
      db.accounts,
    )..where((t) => t.dirty.equals(1))).get();
    for (final Account row in accounts) {
      out.add(
        SyncChange(
          bookId: row.bookId,
          entity: 'account',
          id: row.id,
          updatedAt: row.updatedAt,
          deleted: row.deletedAt != null,
          payload: row.toJson(),
        ),
      );
    }

    final categories = await (db.select(
      db.categories,
    )..where((t) => t.dirty.equals(1))).get();
    for (final Category row in categories) {
      out.add(
        SyncChange(
          bookId: row.bookId,
          entity: 'category',
          id: row.id,
          updatedAt: row.updatedAt,
          deleted: row.deletedAt != null,
          payload: row.toJson(),
        ),
      );
    }

    final transactions = await (db.select(
      db.transactions,
    )..where((t) => t.dirty.equals(1))).get();
    for (final TxRow row in transactions) {
      out.add(
        SyncChange(
          bookId: row.bookId,
          entity: 'transaction',
          id: row.id,
          updatedAt: row.updatedAt,
          deleted: row.deletedAt != null,
          payload: row.toJson(),
        ),
      );
    }

    final budgets = await (db.select(
      db.budgets,
    )..where((t) => t.dirty.equals(1))).get();
    for (final BudgetRow row in budgets) {
      out.add(
        SyncChange(
          bookId: row.bookId,
          entity: 'budget',
          id: row.id,
          updatedAt: row.updatedAt,
          deleted: row.deletedAt != null,
          payload: row.toJson(),
        ),
      );
    }
    return out;
  }

  // ── 上行：推送成功把 dirty 置 0（updatedAt 变了就保持 dirty）─────────

  Future<void> _markClean(AppDatabase db, SyncChange change) async {
    switch (change.entity) {
      case 'book':
        await (db.update(db.books)..where(
              (t) => t.id.equals(change.id) & t.updatedAt.equals(change.updatedAt),
            ))
            .write(const BooksCompanion(dirty: Value(0)));
        break;
      case 'account':
        await (db.update(db.accounts)..where(
              (t) => t.id.equals(change.id) & t.updatedAt.equals(change.updatedAt),
            ))
            .write(const AccountsCompanion(dirty: Value(0)));
        break;
      case 'category':
        await (db.update(db.categories)..where(
              (t) => t.id.equals(change.id) & t.updatedAt.equals(change.updatedAt),
            ))
            .write(const CategoriesCompanion(dirty: Value(0)));
        break;
      case 'transaction':
        await (db.update(db.transactions)..where(
              (t) => t.id.equals(change.id) & t.updatedAt.equals(change.updatedAt),
            ))
            .write(const TransactionsCompanion(dirty: Value(0)));
        break;
      case 'budget':
        await (db.update(db.budgets)..where(
              (t) => t.id.equals(change.id) & t.updatedAt.equals(change.updatedAt),
            ))
            .write(const BudgetsCompanion(dirty: Value(0)));
        break;
    }
  }

  // ── 下行：应用服务端一行（LWW；唯一索引冲突跳过）────────────────────

  Future<bool> _apply(AppDatabase db, SyncChange change) async {
    try {
      switch (change.entity) {
        case 'book':
          return await _applyBook(db, change);
        case 'account':
          return await _applyAccount(db, change);
        case 'category':
          return await _applyCategory(db, change);
        case 'transaction':
          return await _applyTransaction(db, change);
        case 'budget':
          return await _applyBudget(db, change);
        default:
          return false;
      }
    } on Object {
      // 唯一索引（流水指纹 / 预算 period）冲突等：跳过这一行，不让整次同步失败
      return false;
    }
  }

  Future<bool> _applyBook(AppDatabase db, SyncChange change) async {
    final Book? existing = await (db.select(
      db.books,
    )..where((t) => t.id.equals(change.id))).getSingleOrNull();
    if (existing != null && existing.updatedAt > change.updatedAt) return false;
    if (change.deleted) {
      if (existing == null) return false;
      await (db.update(
        db.books,
      )..where((t) => t.id.equals(change.id))).write(
        BooksCompanion(
          deletedAt: Value(change.updatedAt),
          updatedAt: Value(change.updatedAt),
          dirty: const Value(0),
        ),
      );
      return true;
    }
    final Book row = Book.fromJson(change.payload);
    await db
        .into(db.books)
        .insertOnConflictUpdate(
          row.toCompanion(false).copyWith(dirty: const Value(0)),
        );
    return true;
  }

  Future<bool> _applyAccount(AppDatabase db, SyncChange change) async {
    final Account? existing = await (db.select(
      db.accounts,
    )..where((t) => t.id.equals(change.id))).getSingleOrNull();
    if (existing != null && existing.updatedAt > change.updatedAt) return false;
    if (change.deleted) {
      if (existing == null) return false;
      await (db.update(
        db.accounts,
      )..where((t) => t.id.equals(change.id))).write(
        AccountsCompanion(
          deletedAt: Value(change.updatedAt),
          updatedAt: Value(change.updatedAt),
          dirty: const Value(0),
        ),
      );
      return true;
    }
    final Account row = Account.fromJson(change.payload);
    await db
        .into(db.accounts)
        .insertOnConflictUpdate(
          row.toCompanion(false).copyWith(dirty: const Value(0)),
        );
    return true;
  }

  Future<bool> _applyCategory(AppDatabase db, SyncChange change) async {
    final Category? existing = await (db.select(
      db.categories,
    )..where((t) => t.id.equals(change.id))).getSingleOrNull();
    if (existing != null && existing.updatedAt > change.updatedAt) return false;
    if (change.deleted) {
      if (existing == null) return false;
      await (db.update(
        db.categories,
      )..where((t) => t.id.equals(change.id))).write(
        CategoriesCompanion(
          deletedAt: Value(change.updatedAt),
          updatedAt: Value(change.updatedAt),
          dirty: const Value(0),
        ),
      );
      return true;
    }
    final Category row = Category.fromJson(change.payload);
    await db
        .into(db.categories)
        .insertOnConflictUpdate(
          row.toCompanion(false).copyWith(dirty: const Value(0)),
        );
    return true;
  }

  Future<bool> _applyTransaction(AppDatabase db, SyncChange change) async {
    final TxRow? existing = await (db.select(
      db.transactions,
    )..where((t) => t.id.equals(change.id))).getSingleOrNull();
    if (existing != null && existing.updatedAt > change.updatedAt) return false;
    if (change.deleted) {
      if (existing == null) return false;
      await (db.update(
        db.transactions,
      )..where((t) => t.id.equals(change.id))).write(
        TransactionsCompanion(
          deletedAt: Value(change.updatedAt),
          updatedAt: Value(change.updatedAt),
          dirty: const Value(0),
        ),
      );
      return true;
    }
    final TxRow row = TxRow.fromJson(change.payload);
    await db
        .into(db.transactions)
        .insertOnConflictUpdate(
          row.toCompanion(false).copyWith(dirty: const Value(0)),
        );
    return true;
  }

  Future<bool> _applyBudget(AppDatabase db, SyncChange change) async {
    final BudgetRow? existing = await (db.select(
      db.budgets,
    )..where((t) => t.id.equals(change.id))).getSingleOrNull();
    if (existing != null && existing.updatedAt > change.updatedAt) return false;
    if (change.deleted) {
      if (existing == null) return false;
      await (db.update(
        db.budgets,
      )..where((t) => t.id.equals(change.id))).write(
        BudgetsCompanion(
          deletedAt: Value(change.updatedAt),
          updatedAt: Value(change.updatedAt),
          dirty: const Value(0),
        ),
      );
      return true;
    }
    final BudgetRow row = BudgetRow.fromJson(change.payload);
    await db
        .into(db.budgets)
        .insertOnConflictUpdate(
          row.toCompanion(false).copyWith(dirty: const Value(0)),
        );
    return true;
  }
}
