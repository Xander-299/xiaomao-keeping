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
    if (amountCents <= 0) {
      throw ArgumentError.value(amountCents, 'amountCents', '金额必须为正整数（分）');
    }
    if (bookId.isEmpty || accountId.isEmpty) {
      throw ArgumentError('bookId 与 accountId 为必填');
    }
    if (type != 'transfer' && (categoryId == null || categoryId.isEmpty)) {
      throw ArgumentError('$type 类型必须指定 categoryId');
    }
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

    final tx = await create(
      bookId: bookId,
      accountId: accountId,
      type: type,
      amountCents: amountCents,
      occurredAt: occurredAt,
      categoryId: categoryId,
      note: note,
      source: source,
      fingerprint: fp,
      transferGroupId: transferGroupId,
      ownerId: ownerId,
    );
    return ImportOk(tx);
  }
}
