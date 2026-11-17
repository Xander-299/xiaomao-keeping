/// 月度预算仓储（schema v2）。
///
/// 一个账本 + 一个月份最多一条有效记录（部分唯一索引 `idx_budget_book_period`）。
/// 设置走「先查后写」而不是 `INSERT OR REPLACE`：
/// - 语义上「重复设置」是**更新**，保留原始 `created_at`；
/// - 与 `importTransaction` 的既有做法一致（不依赖 sqlite 错误消息判重）。
/// 删除 = 软删除（deleted_at 非空），与其它业务表一致。
library;

import 'package:drift/drift.dart';

import '../../core/db/database.dart';
import '../../core/utils/id.dart';

class BudgetRepository {
  BudgetRepository(this._db);

  final AppDatabase _db;

  /// 月份 key：`'YYYY-MM'`（零填充，字典序即时序）。
  static String periodOf(int year, int month) =>
      '$year-${month.toString().padLeft(2, '0')}';

  /// 取某账本某月的预算；未设置返回 null。
  ///
  /// [categoryId] 为 null = **总预算**；非空 = 该分类的额度（FR-BUDGET-10）。
  Future<BudgetRow?> getForMonth(
    String bookId,
    int year,
    int month, {
    String? categoryId,
  }) {
    return (_db.select(_db.budgets)..where(
          (b) =>
              b.bookId.equals(bookId) &
              b.period.equals(periodOf(year, month)) &
              b.deletedAt.isNull() &
              (categoryId == null
                  ? b.categoryId.isNull()
                  : b.categoryId.equals(categoryId)),
        ))
        .getSingleOrNull();
  }

  /// 某账本某月的**所有**有效预算（总预算 + 分类预算），按分类 id 升序（null 最前）。
  Future<List<BudgetRow>> listForMonth(String bookId, int year, int month) {
    return (_db.select(_db.budgets)
          ..where(
            (b) =>
                b.bookId.equals(bookId) &
                b.period.equals(periodOf(year, month)) &
                b.deletedAt.isNull(),
          )
          ..orderBy(<OrderClauseGenerator<$BudgetsTable>>[
            (b) => OrderingTerm.asc(b.categoryId),
          ]))
        .get();
  }

  /// 设置（新增或更新）某账本某月（某分类）的预算。金额必须是正整数分。
  ///
  /// [categoryId] 为 null = 总预算；非空 = 分类预算。
  Future<BudgetRow> setForMonth({
    required String bookId,
    required int year,
    required int month,
    required int amountCents,
    String? categoryId,
  }) async {
    if (amountCents <= 0) {
      throw ArgumentError.value(amountCents, 'amountCents', '预算金额必须为正整数（分）');
    }
    if (bookId.isEmpty) {
      throw ArgumentError('bookId 为必填');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = await getForMonth(
      bookId,
      year,
      month,
      categoryId: categoryId,
    );
    if (existing != null) {
      await (_db.update(_db.budgets)
            ..where((b) => b.id.equals(existing.id) & b.deletedAt.isNull()))
          .write(
        BudgetsCompanion(
          amountCents: Value(amountCents),
          updatedAt: Value(now),
          dirty: const Value(1),
        ),
      );
      final fresh = await (_db.select(_db.budgets)
            ..where((b) => b.id.equals(existing.id)))
          .getSingle();
      return fresh;
    }
    return _db.into(_db.budgets).insertReturning(
          BudgetsCompanion.insert(
            id: uuidV4(),
            bookId: bookId,
            period: periodOf(year, month),
            amountCents: amountCents,
            categoryId: Value(categoryId),
            createdAt: now,
            updatedAt: now,
          ),
        );
  }

  /// 查询某账本**全部月份**的未删预算，按 `period` 升序（`'YYYY-MM'` 字典序即时序）。
  ///
  /// 供数据导出（`F7.7 B 批` 备份 JSON）一次性取全量用；与 [getForMonth] 的区别是不带月份条件。
  Future<List<BudgetRow>> listByBook(String bookId) {
    return (_db.select(_db.budgets)
          ..where((b) => b.bookId.equals(bookId) & b.deletedAt.isNull())
          ..orderBy([(b) => OrderingTerm.asc(b.period)]))
        .get();
  }

  /// 把 [fromPeriod] 的分类预算复制到 [toPeriod]；**已存在的分类跳过**，返回复制条数。
  ///
  /// 只复制分类预算 —— 总预算由用户按月自己决定（Q4 的口径是「分类预算沿用」）。
  /// 已软删的源行不复制。
  Future<int> carryCategoryBudgets({
    required String bookId,
    required String fromPeriod,
    required String toPeriod,
  }) async {
    if (bookId.isEmpty || fromPeriod == toPeriod) return 0;
    final List<BudgetRow> source = await (_db.select(_db.budgets)
          ..where(
            (b) =>
                b.bookId.equals(bookId) &
                b.period.equals(fromPeriod) &
                b.deletedAt.isNull() &
                b.categoryId.isNotNull(),
          ))
        .get();
    if (source.isEmpty) return 0;

    final List<BudgetRow> targetRows =
        await (_db.select(_db.budgets)..where(
              (b) =>
                  b.bookId.equals(bookId) &
                  b.period.equals(toPeriod) &
                  b.deletedAt.isNull() &
                  b.categoryId.isNotNull(),
            ))
            .get();
    final Set<String> existing = <String>{
      for (final BudgetRow row in targetRows)
        if (row.categoryId != null) row.categoryId!,
    };

    final int now = DateTime.now().millisecondsSinceEpoch;
    int copied = 0;
    for (final BudgetRow row in source) {
      final String? categoryId = row.categoryId;
      if (categoryId == null || existing.contains(categoryId)) continue;
      await _db.into(_db.budgets).insert(
            BudgetsCompanion.insert(
              id: uuidV4(),
              bookId: bookId,
              period: toPeriod,
              amountCents: row.amountCents,
              categoryId: Value(categoryId),
              createdAt: now,
              updatedAt: now,
            ),
          );
      copied++;
    }
    return copied;
  }

  /// 清除某账本某月（某分类）的预算（软删除）。返回受影响行数（0 表示本来就没设）。
  Future<int> clearForMonth(
    String bookId,
    int year,
    int month, {
    String? categoryId,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return (_db.update(_db.budgets)
          ..where(
            (b) =>
                b.bookId.equals(bookId) &
                b.period.equals(periodOf(year, month)) &
                b.deletedAt.isNull() &
                (categoryId == null
                    ? b.categoryId.isNull()
                    : b.categoryId.equals(categoryId)),
          ))
        .write(
      BudgetsCompanion(
        deletedAt: Value(now),
        updatedAt: Value(now),
        dirty: const Value(1),
      ),
    );
  }
}
