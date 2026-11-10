/// 流水仓储。
///
/// 对应旧栈 `src/repositories/transaction-repository.js`：
/// 金额一律整数分；type 决定收支方向；删除=软删除。
/// 提供统一入账入口 [TransactionRepository.importTransaction] 供自动记账调用。
library;

import 'package:drift/drift.dart';

import '../../core/db/database.dart';
import '../../core/utils/fingerprint.dart';
import '../../core/utils/id.dart';

/// 入账结果。指纹重复不算错误，由调用方决定跳过或提示。
sealed class ImportResult {
  const ImportResult();
}

/// 入账成功。
final class ImportOk extends ImportResult {
  const ImportOk(this.tx);

  final TxRow tx;
}

/// 指纹命中已有流水，未重复入账。
final class ImportDuplicate extends ImportResult {
  const ImportDuplicate(this.existingTx);

  final TxRow existingTx;
}

/// 恢复软删流水的结果。
///
/// 失败原因必须可识别，调用方不能再把「账户已删」「分类已删」「指纹冲突」
/// 统一说成「同指纹记录已存在」。成功时返回 [restored]。
enum TxRestoreResult {
  /// 恢复成功，流水重新可见。
  restored,

  /// 找不到这条流水。
  notFound,

  /// 流水当前不是软删状态（已经恢复过 / 从未删除）。
  notDeleted,

  /// 所属账本不存在或已软删除。
  bookUnavailable,

  /// 关联账户不存在、已删除或不属于同一账本。
  accountUnavailable,

  /// 关联分类不存在、已删除或不属于同一账本。
  categoryUnavailable,

  /// 分类的收支方向与流水类型不一致。
  categoryKindMismatch,

  /// 同账本内已有同指纹的活跃流水，恢复会撞唯一索引。
  fingerprintConflict,
}

extension TxRestoreResultX on TxRestoreResult {
  bool get isRestored => this == TxRestoreResult.restored;
}

/// 入账前的参数校验（`create` 与 `importTransaction` 共用）。
///
/// ⚠️ 别只在一处做：`importTransaction` 的指纹分支自己拼 companion 直插（为了用
/// `INSERT OR IGNORE`），早先漏调这套校验，结果「分类缺失」不再抛错 ——
/// 直接把 categoryId 为 null 的 expense 写进了库（`bill_importer_test` 的
/// 「非 duplicate 异常 → 整体回滚」当场抓到）。
void _validateTransactionInput({
  required String bookId,
  required String accountId,
  required String type,
  required int amountCents,
  String? categoryId,
}) {
  if (amountCents <= 0) {
    throw ArgumentError.value(amountCents, 'amountCents', '金额必须为正整数（分）');
  }
  if (bookId.isEmpty || accountId.isEmpty) {
    throw ArgumentError('bookId 与 accountId 为必填');
  }
  if (type != 'transfer' && (categoryId == null || categoryId.isEmpty)) {
    throw ArgumentError('$type 类型必须指定 categoryId');
  }
}

class TransactionRepository {
  TransactionRepository(this._db);

  final AppDatabase _db;

  /// 新增一笔流水（手工或已带 fingerprint 的自动入账共用）。
  ///
  /// 金额必须是正整数分；type 非 transfer 时必须给 categoryId。
  Future<TxRow> create({
    required String bookId,
    required String accountId,
    required String type,
    required int amountCents,
    required int occurredAt,
    String? categoryId,
    String note = '',
    String source = 'manual',
    String? fingerprint,
    String? transferGroupId,
    String? ownerId,
    String? id,
  }) {
    _validateTransactionInput(
      bookId: bookId,
      accountId: accountId,
      type: type,
      amountCents: amountCents,
      categoryId: categoryId,
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    return _db
        .into(_db.transactions)
        .insertReturning(
          TransactionsCompanion.insert(
            id: id ?? uuidV4(),
            bookId: bookId,
            accountId: accountId,
            type: type,
            amountCents: amountCents,
            occurredAt: occurredAt,
            createdAt: now,
            updatedAt: now,
            categoryId: Value(categoryId),
            note: Value(note),
            source: Value(source),
            fingerprint: Value(fingerprint),
            transferGroupId: Value(transferGroupId),
            ownerId: Value(ownerId),
          ),
        );
  }

  /// 按 id 取单笔流水；[includeDeleted]=true 时可取已软删行。
  Future<TxRow?> getById(String id, {bool includeDeleted = false}) {
    final q = _db.select(_db.transactions)..where((t) => t.id.equals(id));
    if (!includeDeleted) {
      q.where((t) => t.deletedAt.isNull());
    }
    return q.getSingleOrNull();
  }

  /// 查询某账本指定月份（本地时区）的流水，按发生时间倒序。
  Future<List<TxRow>> listByMonth(String bookId, int year, int month) {
    final start = DateTime(year, month, 1).millisecondsSinceEpoch;
    final end = DateTime(year, month + 1, 1).millisecondsSinceEpoch;
    return (_db.select(_db.transactions)
          ..where(
            (t) =>
                t.bookId.equals(bookId) &
                t.deletedAt.isNull() &
                t.occurredAt.isBiggerOrEqualValue(start) &
                t.occurredAt.isSmallerThanValue(end),
          )
          ..orderBy([(t) => OrderingTerm.desc(t.occurredAt)]))
        .get();
  }

  /// 查询某账本某一整年的流水（本地时区），按发生时间倒序。
  ///
  /// 供日历的「月份缩略图」索引每月的有账日期，一次查询覆盖 12 个月。
  Future<List<TxRow>> listByYear(String bookId, int year) {
    final start = DateTime(year, 1, 1).millisecondsSinceEpoch;
    final end = DateTime(year + 1, 1, 1).millisecondsSinceEpoch;
    return (_db.select(_db.transactions)
          ..where(
            (t) =>
                t.bookId.equals(bookId) &
                t.deletedAt.isNull() &
                t.occurredAt.isBiggerOrEqualValue(start) &
                t.occurredAt.isSmallerThanValue(end),
          )
          ..orderBy([(t) => OrderingTerm.desc(t.occurredAt)]))
        .get();
  }

  /// 查询某账本一段时间区间内的流水（本地时区），按发生时间倒序。
  ///
  /// 供统计页的「近 N 月趋势」一次取齐跨月/跨年数据，避免逐月查询。
  Future<List<TxRow>> listByRange(String bookId, int startMs, int endMs) {
    return (_db.select(_db.transactions)
          ..where(
            (t) =>
                t.bookId.equals(bookId) &
                t.deletedAt.isNull() &
                t.occurredAt.isBiggerOrEqualValue(startMs) &
                t.occurredAt.isSmallerThanValue(endMs),
          )
          ..orderBy([(t) => OrderingTerm.desc(t.occurredAt)]))
        .get();
  }

  /// 查询某账本**全部时间**的未删流水，按发生时间倒序。
  ///
  /// 供搜索页一次载入后在内存里过滤（数量级万级，见 SPEC-F7.4 §3.1）；
  /// 与 [listByMonth] / [listByYear] / [listByRange] 的区别是**不带时间窗**。
  Future<List<TxRow>> listByBook(String bookId) {
    return (_db.select(_db.transactions)
          ..where((t) => t.bookId.equals(bookId) & t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.desc(t.occurredAt)]))
        .get();
  }

  /// 局部更新。目标不存在或已删则抛错。
  Future<TxRow> update(
    String id, {
    int? amountCents,
    String? note,
    int? occurredAt,
    String? categoryId,
    String? accountId,
    String? type,
  }) async {
    if (amountCents != null && amountCents <= 0) {
      throw ArgumentError.value(amountCents, 'amountCents', '金额必须为正整数（分）');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final changed = await (_db.update(_db.transactions)
          ..where((t) => t.id.equals(id) & t.deletedAt.isNull()))
        .write(
          TransactionsCompanion(
            amountCents: amountCents == null
                ? const Value.absent()
                : Value(amountCents),
            note: note == null ? const Value.absent() : Value(note),
            occurredAt: occurredAt == null
                ? const Value.absent()
                : Value(occurredAt),
            categoryId: categoryId == null
                ? const Value.absent()
                : Value(categoryId),
            accountId: accountId == null
                ? const Value.absent()
                : Value(accountId),
            type: type == null ? const Value.absent() : Value(type),
            updatedAt: Value(now),
            dirty: const Value(1),
          ),
        );
    if (changed == 0) {
      throw StateError('transactions 未找到可更新的记录：$id');
    }
    final fresh = await getById(id);
    return fresh!;
  }

  /// 软删除。返回受影响行数。
  Future<int> softDelete(String id) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return (_db.update(_db.transactions)
          ..where((t) => t.id.equals(id) & t.deletedAt.isNull()))
        .write(
          TransactionsCompanion(
            deletedAt: Value(now),
            updatedAt: Value(now),
            dirty: const Value(1),
          ),
        );
  }

  /// 由一批流水 id 推导其所属账本。
  ///
  /// 只用于兼容**旧版自动记账批次**（JSON 里没有 bookId）。要求：
  /// - 所有 id 都能查到行；
  /// - 所有行属于同一个 bookId。
  /// 任一不满足返回 null，调用方应拒绝撤销，避免跨账本误删。
  Future<String?> bookIdOfTransactions(List<String> ids) async {
    final List<String> unique = ids.toSet().toList();
    if (unique.isEmpty) return null;
    final List<TxRow> rows = await (_db.select(_db.transactions)
          ..where((t) => t.id.isIn(unique)))
        .get();
    if (rows.length != unique.length) return null;
    final Set<String> books = rows.map((TxRow t) => t.bookId).toSet();
    return books.length == 1 ? books.first : null;
  }

  /// 批量软删一批流水（A3）。
  ///
  /// **调用方必须把它和批次记录更新放在同一个 `db.transaction` 里**；
  /// 本方法不再自行开事务，避免嵌套事务语义不确定。
  ///
  /// 先校验所有 id 都存在且属于 [bookId]；任一行缺失或跨账本直接抛
  /// [StateError]，由外层事务整体回滚。只更新 `deleted_at IS NULL` 的行，
  /// 已软删的行计入 0（重复撤销幂等）。
  Future<int> softDeleteBatch({
    required List<String> ids,
    required String bookId,
  }) async {
    final List<String> unique = ids.toSet().toList();
    if (unique.isEmpty) return 0;
    final List<TxRow> rows = await (_db.select(_db.transactions)
          ..where((t) => t.id.isIn(unique)))
        .get();
    if (rows.length != unique.length ||
        rows.any((TxRow t) => t.bookId != bookId)) {
      throw StateError('批次流水不存在或不属于账本 $bookId，拒绝批量撤销');
    }
    final int now = DateTime.now().millisecondsSinceEpoch;
    return (_db.update(_db.transactions)
          ..where(
            (t) =>
                t.id.isIn(unique) &
                t.bookId.equals(bookId) &
                t.deletedAt.isNull(),
          ))
        .write(
          TransactionsCompanion(
            deletedAt: Value(now),
            updatedAt: Value(now),
            dirty: const Value(1),
          ),
        );
  }

  /// 恢复一笔软删的流水（写回 deleted_at = null）。
  ///
  /// Batch A / A2：恢复前在**同一事务**内校验引用完整性，任一不满足都返回
  /// 可识别失败、且不写回任何字段：
  /// - 账本存在且未删除；
  /// - 账户存在、未删除、属于同账本；
  /// - 非 transfer 流水的分类存在、未删除、属于同账本、kind 与 type 一致；
  ///   「已归档但未删除」的分类允许恢复（历史流水仍应能显示归档分类）；
  /// - 同账本内没有同指纹活跃行（唯一索引是 `(book_id, fingerprint)`）。
  Future<TxRestoreResult> restoreTx(String id) {
    return _db.transaction<TxRestoreResult>(() async {
      final TxRow? row =
          await (_db.select(_db.transactions)..where((t) => t.id.equals(id)))
              .getSingleOrNull();
      if (row == null) return TxRestoreResult.notFound;
      if (row.deletedAt == null) return TxRestoreResult.notDeleted;

      final Book? book = await (_db.select(_db.books)
            ..where((b) => b.id.equals(row.bookId)))
          .getSingleOrNull();
      if (book == null || book.deletedAt != null) {
        return TxRestoreResult.bookUnavailable;
      }

      final Account? account = await (_db.select(_db.accounts)
            ..where((a) => a.id.equals(row.accountId)))
          .getSingleOrNull();
      if (account == null ||
          account.deletedAt != null ||
          account.bookId != row.bookId) {
        return TxRestoreResult.accountUnavailable;
      }

      if (row.type != 'transfer') {
        final String? categoryId = row.categoryId;
        if (categoryId == null || categoryId.isEmpty) {
          return TxRestoreResult.categoryUnavailable;
        }
        final Category? category = await (_db.select(_db.categories)
              ..where((c) => c.id.equals(categoryId)))
            .getSingleOrNull();
        if (category == null ||
            category.deletedAt != null ||
            category.bookId != row.bookId) {
          return TxRestoreResult.categoryUnavailable;
        }
        if (category.kind != row.type) {
          return TxRestoreResult.categoryKindMismatch;
        }
      }

      if (row.fingerprint != null) {
        final List<TxRow> clash =
            await (_db.select(_db.transactions)
                  ..where(
                    (t) =>
                        t.bookId.equals(row.bookId) &
                        t.fingerprint.equals(row.fingerprint!) &
                        t.deletedAt.isNull(),
                  ))
                .get();
        if (clash.isNotEmpty) return TxRestoreResult.fingerprintConflict;
      }

      final int now = DateTime.now().millisecondsSinceEpoch;
      final int changed = await (_db.update(_db.transactions)
            ..where((t) => t.id.equals(id) & t.deletedAt.isNotNull()))
          .write(
            TransactionsCompanion(
              deletedAt: const Value(null),
              updatedAt: Value(now),
              dirty: const Value(1),
            ),
          );
      if (changed == 0) return TxRestoreResult.notDeleted;
      return TxRestoreResult.restored;
    });
  }

  /// 统一入账入口（自动记账模块调用）。
  ///
  /// [source]='manual' 时 fingerprint 为 null，不参与查重（同金额同时间可重复记）；
  /// 否则按指纹先查重，命中已有未删流水则返回 [ImportDuplicate]，不重复写入。
  Future<ImportResult> importTransaction({
    required String bookId,
    required String accountId,
    required String type,
    required int amountCents,
    required int occurredAt,
    String? categoryId,
    String note = '',
    String source = 'manual',
    String? externalId,
    String? transferGroupId,
    String? ownerId,
  }) async {
    if (source == 'manual') {
      final tx = await create(
        bookId: bookId,
        accountId: accountId,
        type: type,
        amountCents: amountCents,
        occurredAt: occurredAt,
        categoryId: categoryId,
        note: note,
        source: 'manual',
        fingerprint: null,
        transferGroupId: transferGroupId,
        ownerId: ownerId,
      );
      return ImportOk(tx);
    }

    final fp = computeFingerprint(
      source: source,
      externalId: externalId,
      amountCents: amountCents,
      occurredAt: occurredAt,
    );
    final existing = await (_db.select(_db.transactions)
          ..where(
            (t) =>
                t.bookId.equals(bookId) &
                t.fingerprint.equals(fp) &
                t.deletedAt.isNull(),
          ))
        .getSingleOrNull();
    if (existing != null) return ImportDuplicate(existing);

    // 并发竞争（P3）：预查之后、插入之前，另一个入口（另一次导入 / 自动记账）
    // 可能已经写入了同指纹行。这里**不用「插失败再 catch」**，而是 `INSERT OR IGNORE`：
    //
    //   ① 撞 `(book_id, fingerprint)` 唯一索引时静默不写，不产生异常 → 外层事务不会被打断，
    //      整批导入不会因为「这笔其实早就有了」而回滚成「导入失败」；
    //   ② 异常驱动的写法在 SQLite 上还有个坑：`ABORT` 会回滚**整条语句**（含触发器里写入的行），
    //      失败后再回查什么都查不到，只能 `rethrow` —— 那就等于没兜住。
    //
    // 校验（金额 / accountId / categoryId）与 `create` 共用同一套 —— 指纹分支自己拼
    // companion 直插，漏掉这步就会把「分类缺失」的 expense 写进库。
    _validateTransactionInput(
      bookId: bookId,
      accountId: accountId,
      type: type,
      amountCents: amountCents,
      categoryId: categoryId,
    );
    final int now = DateTime.now().millisecondsSinceEpoch;
    final TxRow? inserted = await _db
        .into(_db.transactions)
        .insertReturningOrNull(
          TransactionsCompanion.insert(
            id: uuidV4(),
            bookId: bookId,
            accountId: accountId,
            type: type,
            amountCents: amountCents,
            occurredAt: occurredAt,
            createdAt: now,
            updatedAt: now,
            categoryId: Value(categoryId),
            note: Value(note),
            source: Value(source),
            fingerprint: Value(fp),
            transferGroupId: Value(transferGroupId),
            ownerId: Value(ownerId),
          ),
          mode: InsertMode.insertOrIgnore,
        );
    if (inserted != null) return ImportOk(inserted);

    // 被忽略了 = 唯一索引挡住了：回查那笔已存在的，归为 duplicate（幂等口径）。
    final TxRow? raced = await (_db.select(
      _db.transactions,
    )..where(
          (t) =>
              t.bookId.equals(bookId) &
              t.fingerprint.equals(fp) &
              t.deletedAt.isNull(),
        ))
        .getSingleOrNull();
    if (raced != null) return ImportDuplicate(raced);
    // 既没写进去、又查不到同指纹行 → 被别的约束（非空 / 外键）挡住了。明确报错，
    // 不要假装成功，也不要吐出「重复」误导用户。
    throw StateError('入账被数据库忽略，且查不到同指纹记录（bookId=$bookId）');
  }
}
