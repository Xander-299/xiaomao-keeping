/// P6.4 双向同步引擎（第一版：手动增量同步）。
///
/// 数据流：
/// 1. 扫所有本机账本里 `dirty=1` 的行 → 分批 push；
/// 2. 服务端按 LWW 决定收不收；返回的 `conflicts`（服务端较新）立即应用；
/// 3. 从本机 cursor 起循环 pull，直到 `hasMore=false`；
/// 4. 应用下行时 `dirty=0`（不制造第二条写库路径），本地较新的行跳过、等下次 push 赢。
///
/// 第一阶段不做：自动触发、settings 同步、字段级合并。
/// P6.4b 起：**自动触发**在 `sync_trigger.dart`（本类只管「跑一次」）；
/// **设置同步**按 `entity=setting` 走同一条 push/pull；**字段级合并仍不做**。
///
/// 并发：`syncNow()` 是**单飞**的 —— 自动触发与页面按钮同时来，只会发一次请求。
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
import 'package:yanxin/features/sync/application/settings_sync.dart';
import 'package:yanxin/features/sync/application/sync_conflicts.dart';

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
      // 本轮可能新写了冲突存档（或恢复后变少）→ 让 /cloud-sync 那一行立刻准。
      ref.invalidate(syncConflictCountProvider);
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

  /// 正在跑的那一次（单飞锁）。自动触发与页面按钮共用。
  Future<SyncResult>? _inflight;

  /// 推本机 dirty 行 → 应用 conflicts → 从 cursor 拉取并应用。
  ///
  /// **单飞**：已有一次在跑就直接返回它，不排队、不抛错 —— 自动触发与手动按钮
  /// 撞在一起时，用户看到的应当是「一次同步」而不是两次。
  Future<SyncResult> syncNow() {
    final Future<SyncResult>? running = _inflight;
    if (running != null) return running;
    late final Future<SyncResult> future;
    future = _runSync().whenComplete(() {
      if (identical(_inflight, future)) _inflight = null;
    });
    _inflight = future;
    return future;
  }

  Future<SyncResult> _runSync() async {
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
            // 冲突行里「应用失败」的那几条（唯一索引冲突等）**没有上云**，
            // 绝不能清 dirty，否则本机会显示一个云端永远没有的版本、且不再重试
            // （B1：本机与云端永久分叉，不自愈）。见 SPEC-P6.4b D3。
            final Set<String> keptLocal = <String>{};
            for (final SyncChange serverRow in res.conflicts) {
              conflicts++;
              if (await _apply(db, serverRow)) {
                pulled++;
              } else {
                skipped++;
                keptLocal.add(_changeKey(serverRow));
              }
            }
            for (final SyncChange change in chunk) {
              if (keptLocal.contains(_changeKey(change))) continue;
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

    // 设置项（P6.4b D4）：白名单三键打包成一条 entity=setting 的变更。
    final SyncChange? setting = await buildSettingsChange(
      _ref.read(appMetaRepositoryProvider),
    );
    if (setting != null) out.add(setting);

    return out;
  }

  // ── 上行：推送成功把 dirty 置 0（updatedAt 变了就保持 dirty）─────────

  /// 变更的唯一键：同一实体的同一 id（跨表同名 id 不算同一行）。
  static String _changeKey(SyncChange change) => '${change.entity}/${change.id}';

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
      case kSettingsEntity:
        // 设置没有表行，靠 KV 记「这个时间戳已经推上去过」。
        await markSettingsSynced(
          _ref.read(appMetaRepositoryProvider),
          change.updatedAt,
        );
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
        case kSettingsEntity:
          final bool applied = await applySettingsChange(
            _ref.read(appMetaRepositoryProvider),
            change,
          );
          if (applied) invalidateSettingsProviders(_ref);
          return applied;
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
    // 覆盖一份「本机有未同步改动」的行 = 用户会丢失一份编辑：留档（P6.4b D2）。
    if (existing != null && existing.dirty == 1) {
      await archiveConflict(
        db,
        entity: 'book',
        bookId: change.bookId,
        entityId: change.id,
        localUpdatedAt: existing.updatedAt,
        localPayload: existing.toJson(),
        serverUpdatedAt: change.updatedAt,
        serverPayload: change.payload,
      );
    }
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
    // 覆盖一份「本机有未同步改动」的行 = 用户会丢失一份编辑：留档（P6.4b D2）。
    if (existing != null && existing.dirty == 1) {
      await archiveConflict(
        db,
        entity: 'account',
        bookId: change.bookId,
        entityId: change.id,
        localUpdatedAt: existing.updatedAt,
        localPayload: existing.toJson(),
        serverUpdatedAt: change.updatedAt,
        serverPayload: change.payload,
      );
    }
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
    // 覆盖一份「本机有未同步改动」的行 = 用户会丢失一份编辑：留档（P6.4b D2）。
    if (existing != null && existing.dirty == 1) {
      await archiveConflict(
        db,
        entity: 'category',
        bookId: change.bookId,
        entityId: change.id,
        localUpdatedAt: existing.updatedAt,
        localPayload: existing.toJson(),
        serverUpdatedAt: change.updatedAt,
        serverPayload: change.payload,
      );
    }
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
    // 覆盖一份「本机有未同步改动」的行 = 用户会丢失一份编辑：留档（P6.4b D2）。
    if (existing != null && existing.dirty == 1) {
      await archiveConflict(
        db,
        entity: 'transaction',
        bookId: change.bookId,
        entityId: change.id,
        localUpdatedAt: existing.updatedAt,
        localPayload: existing.toJson(),
        serverUpdatedAt: change.updatedAt,
        serverPayload: change.payload,
      );
    }
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
    // 覆盖一份「本机有未同步改动」的行 = 用户会丢失一份编辑：留档（P6.4b D2）。
    if (existing != null && existing.dirty == 1) {
      await archiveConflict(
        db,
        entity: 'budget',
        bookId: change.bookId,
        entityId: change.id,
        localUpdatedAt: existing.updatedAt,
        localPayload: existing.toJson(),
        serverUpdatedAt: change.updatedAt,
        serverPayload: change.payload,
      );
    }
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
