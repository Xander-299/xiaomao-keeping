import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/data/repositories/account_repository.dart';
import 'package:yanxin/data/repositories/book_repository.dart';
import 'package:yanxin/data/repositories/category_repository.dart';
import 'package:yanxin/data/repositories/transaction_repository.dart';

import '../../helpers/test_database.dart';

void main() {
  late AppDatabase db;
  late TransactionRepository repo;

  setUp(() async {
    db = openTestDatabase();
    addTearDown(db.close);
    repo = TransactionRepository(db);
    // A2 起 restoreTx 会做引用完整性校验：给默认测试数据铺真实 book/account/category。
    await db.customStatement(
      'INSERT INTO books(id, name, created_at, updated_at) '
      "VALUES('b1','测试账本',1,1)",
    );
    await db.customStatement(
      'INSERT INTO accounts(id, book_id, name, type, initial_balance_cents, '
      'sort_order, created_at, updated_at) '
      "VALUES('a1','b1','现金','cash',0,0,1,1)",
    );
    await db.customStatement(
      'INSERT INTO categories(id, book_id, name, kind, sort_order, '
      'created_at, updated_at) '
      "VALUES('c1','b1','餐饮','expense',0,1,1)",
    );
  });

  const baseBookId = 'b1';
  const baseAccountId = 'a1';
  const baseCategoryId = 'c1';

  /// 第二个账本 + 账户 + 分类，供跨账本测试。
  Future<void> seedBookB() async {
    await db.customStatement(
      'INSERT INTO books(id, name, created_at, updated_at) '
      "VALUES('b2','第二账本',1,1)",
    );
    await db.customStatement(
      'INSERT INTO accounts(id, book_id, name, type, initial_balance_cents, '
      'sort_order, created_at, updated_at) '
      "VALUES('a2','b2','现金','cash',0,0,1,1)",
    );
    await db.customStatement(
      'INSERT INTO categories(id, book_id, name, kind, sort_order, '
      'created_at, updated_at) '
      "VALUES('c2','b2','餐饮','expense',0,1,1)",
    );
  }

  Future<TxRow> createTx({
    String bookId = baseBookId,
    String accountId = baseAccountId,
    String categoryId = baseCategoryId,
    String type = 'expense',
  }) => repo.create(
    bookId: bookId,
    accountId: accountId,
    categoryId: categoryId,
    type: type,
    amountCents: 1234,
    occurredAt: DateTime(2026, 9, 1).millisecondsSinceEpoch,
  );

  Future<void> expectSoftDeleted(String id) async {
    final TxRow? row = await repo.getById(id, includeDeleted: true);
    expect(row?.deletedAt, isNotNull, reason: '失败后必须保持软删，不能部分恢复');
  }

  test('金额为 0 / 负数抛错', () {
    expect(
      () => repo.create(
        bookId: baseBookId,
        accountId: baseAccountId,
        categoryId: baseCategoryId,
        type: 'expense',
        amountCents: 0,
        occurredAt: 1,
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => repo.create(
        bookId: baseBookId,
        accountId: baseAccountId,
        categoryId: baseCategoryId,
        type: 'expense',
        amountCents: -100,
        occurredAt: 1,
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('expense 缺 categoryId 抛错', () {
    expect(
      () => repo.create(
        bookId: baseBookId,
        accountId: baseAccountId,
        type: 'expense',
        amountCents: 100,
        occurredAt: 1,
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('创建后 id 为 UUID、dirty=1、deletedAt=null', () async {
    final tx = await repo.create(
      bookId: baseBookId,
      accountId: baseAccountId,
      categoryId: baseCategoryId,
      type: 'expense',
      amountCents: 1234,
      occurredAt: DateTime.now().millisecondsSinceEpoch,
      note: '午饭',
    );
    expect(tx.id, hasLength(36));
    expect(tx.dirty, 1);
    expect(tx.deletedAt, isNull);
    expect(tx.amountCents, 1234);
    expect(tx.note, '午饭');
    expect(tx.source, 'manual');
  });

  test('更新后 updatedAt 变化、createdAt 不变', () async {
    final tx = await repo.create(
      bookId: baseBookId,
      accountId: baseAccountId,
      categoryId: baseCategoryId,
      type: 'expense',
      amountCents: 1234,
      occurredAt: DateTime.now().millisecondsSinceEpoch,
    );
    await Future<void>.delayed(const Duration(milliseconds: 2));
    final updated = await repo.update(
      tx.id,
      amountCents: 2000,
      note: '晚饭',
    );
    expect(updated.amountCents, 2000);
    expect(updated.note, '晚饭');
    expect(updated.createdAt, tx.createdAt);
    expect(updated.updatedAt, greaterThanOrEqualTo(tx.createdAt));
  });

  test('软删除后 listByMonth 查不到，但 getById(includeDeleted) 能取到',
      () async {
    final tx = await repo.create(
      bookId: baseBookId,
      accountId: baseAccountId,
      categoryId: baseCategoryId,
      type: 'expense',
      amountCents: 1234,
      occurredAt: DateTime(2026, 9, 1).millisecondsSinceEpoch,
    );
    await repo.softDelete(tx.id);
    final month = await repo.listByMonth(baseBookId, 2026, 9);
    expect(month.map((t) => t.id), isNot(contains(tx.id)));
    final got = await repo.getById(tx.id, includeDeleted: true);
    expect(got?.deletedAt, isNotNull);
  });

  test('restoreTx 恢复后重新可见且 id / 字段不变；无指纹冲突时成功', () async {
    final tx = await repo.create(
      bookId: baseBookId,
      accountId: baseAccountId,
      categoryId: baseCategoryId,
      type: 'expense',
      amountCents: 1234,
      note: '会被撤回的',
      occurredAt: DateTime(2026, 9, 1).millisecondsSinceEpoch,
    );
    await repo.softDelete(tx.id);
    expect(await repo.restoreTx(tx.id), TxRestoreResult.restored);

    final restored = await repo.getById(tx.id);
    expect(restored, isNotNull);
    expect(restored!.deletedAt, isNull);
    expect(restored.note, '会被撤回的');
    expect(restored.amountCents, 1234);
    expect((await repo.listByMonth(baseBookId, 2026, 9)).map((t) => t.id),
        contains(tx.id));
  });

  test('restoreTx 同账本同指纹活跃行已存在时返回 fingerprintConflict', () async {
    final firstTx = await repo.importTransaction(
      bookId: baseBookId,
      accountId: baseAccountId,
      categoryId: baseCategoryId,
      type: 'expense',
      amountCents: 1234,
      source: 'wechat_csv',
      externalId: 'fp-1',
      occurredAt: DateTime(2026, 9, 1).millisecondsSinceEpoch,
    );
    final String first = (firstTx as ImportOk).tx.id;
    await repo.softDelete(first);

    // 用户删掉后又导入了同一笔（同指纹）
    await repo.importTransaction(
      bookId: baseBookId,
      accountId: baseAccountId,
      categoryId: baseCategoryId,
      type: 'expense',
      amountCents: 1234,
      source: 'wechat_csv',
      externalId: 'fp-1',
      occurredAt: DateTime(2026, 9, 1).millisecondsSinceEpoch,
    );

    expect(await repo.restoreTx(first), TxRestoreResult.fingerprintConflict);
    // 库里仍只有一条活跃的同指纹记录
    final rows = await repo.listByBook(baseBookId);
    expect(rows.where((t) => t.fingerprint != null), hasLength(1));
    // 失败后原流水仍保持软删
    final stillDeleted = await repo.getById(first, includeDeleted: true);
    expect(stillDeleted?.deletedAt, isNotNull);
  });

  test('恢复成功后再次恢复返回 notDeleted', () async {
    final tx = await createTx();
    await repo.softDelete(tx.id);
    expect(await repo.restoreTx(tx.id), TxRestoreResult.restored);
    expect(await repo.restoreTx(tx.id), TxRestoreResult.notDeleted);
  });

  test('账户已删除 → accountUnavailable，流水仍软删', () async {
    final tx = await createTx();
    await repo.softDelete(tx.id);
    await AccountRepository(db).softDelete(baseAccountId);

    expect(await repo.restoreTx(tx.id), TxRestoreResult.accountUnavailable);
    await expectSoftDeleted(tx.id);
  });

  test('分类已删除 → categoryUnavailable，流水仍软删', () async {
    final tx = await createTx();
    await repo.softDelete(tx.id);
    await CategoryRepository(db).deleteIfUnused(baseCategoryId);

    expect(await repo.restoreTx(tx.id), TxRestoreResult.categoryUnavailable);
    await expectSoftDeleted(tx.id);
  });

  test('账户属于其他账本 → accountUnavailable', () async {
    await seedBookB();
    final tx = await createTx(accountId: 'a2');
    await repo.softDelete(tx.id);

    expect(await repo.restoreTx(tx.id), TxRestoreResult.accountUnavailable);
    await expectSoftDeleted(tx.id);
  });

  test('分类属于其他账本 → categoryUnavailable', () async {
    await seedBookB();
    final tx = await createTx(categoryId: 'c2');
    await repo.softDelete(tx.id);

    expect(await repo.restoreTx(tx.id), TxRestoreResult.categoryUnavailable);
    await expectSoftDeleted(tx.id);
  });

  test('分类收支方向与流水类型不一致 → categoryKindMismatch', () async {
    await db.customStatement(
      'INSERT INTO categories(id, book_id, name, kind, sort_order, '
      'created_at, updated_at) '
      "VALUES('c3','b1','工资','income',0,1,1)",
    );
    final tx = await createTx(categoryId: 'c3');
    await repo.softDelete(tx.id);

    expect(await repo.restoreTx(tx.id), TxRestoreResult.categoryKindMismatch);
    await expectSoftDeleted(tx.id);
  });

  test('账本已删除 → bookUnavailable，流水仍软删', () async {
    final tx = await createTx();
    await repo.softDelete(tx.id);
    await BookRepository(db).softDelete(baseBookId);

    expect(await repo.restoreTx(tx.id), TxRestoreResult.bookUnavailable);
    await expectSoftDeleted(tx.id);
  });

  test('流水不存在 → notFound', () async {
    expect(await repo.restoreTx('missing'), TxRestoreResult.notFound);
  });

  test('跨账本相同指纹可导入，且恢复只受同账本冲突约束', () async {
    await seedBookB();
    final int occ = DateTime(2026, 9, 1).millisecondsSinceEpoch;
    Future<ImportResult> run(String bookId, String accountId, String categoryId) =>
        repo.importTransaction(
          bookId: bookId,
          accountId: accountId,
          categoryId: categoryId,
          type: 'expense',
          amountCents: 1234,
          occurredAt: occ,
          source: 'wechat_csv',
          externalId: 'cross-book-fp',
        );

    final ImportOk first = await run('b1', 'a1', 'c1') as ImportOk;
    await repo.softDelete(first.tx.id);
    final ImportOk second = await run('b2', 'a2', 'c2') as ImportOk;

    // b2 的同指纹活跃行不应阻止 b1 的恢复
    expect(await repo.restoreTx(first.tx.id), TxRestoreResult.restored);
    expect((await repo.listByBook('b1')).single.id, first.tx.id);
    expect((await repo.listByBook('b2')).single.id, second.tx.id);

    // 同账本内仍然重复
    expect(
      await run('b1', 'a1', 'c1'),
      isA<ImportDuplicate>(),
    );
  });

  test('listByMonth 月份边界不漏不多', () async {
    Future<void> seed(int cents, DateTime when) => repo.create(
      bookId: baseBookId,
      accountId: baseAccountId,
      categoryId: baseCategoryId,
      type: 'expense',
      amountCents: cents,
      occurredAt: when.millisecondsSinceEpoch,
    );

    await seed(100, DateTime(2026, 7, 31, 23, 59, 59, 999));
    await seed(200, DateTime(2026, 9, 1));
    await seed(300, DateTime(2026, 9, 30, 23, 59, 59, 999));
    await seed(400, DateTime(2026, 10, 1));

    final sep = await repo.listByMonth(baseBookId, 2026, 9);
    final amounts = sep.map((t) => t.amountCents).toList()..sort();
    expect(amounts, <int>[200, 300]);
    // 倒序：9/30 在前
    expect(sep.first.amountCents, 300);
  });

  test('importTransaction 相同指纹第二次返回 duplicate（不抛错）', () async {
    final occ = DateTime.now().millisecondsSinceEpoch;
    Future<ImportResult> run() => repo.importTransaction(
      bookId: baseBookId,
      accountId: baseAccountId,
      categoryId: baseCategoryId,
      type: 'expense',
      amountCents: 1234,
      occurredAt: occ,
      source: 'wechat_csv',
      externalId: 'W123',
    );

    final r1 = await run();
    expect(r1, isA<ImportOk>());
    final r2 = await run();
    expect(r2, isA<ImportDuplicate>());
    expect((r2 as ImportDuplicate).existingTx.id, (r1 as ImportOk).tx.id);
  });

  test('软删该笔后，相同指纹可再次成功写入', () async {
    final occ = DateTime.now().millisecondsSinceEpoch;
    Future<ImportResult> run() => repo.importTransaction(
      bookId: baseBookId,
      accountId: baseAccountId,
      categoryId: baseCategoryId,
      type: 'expense',
      amountCents: 1234,
      occurredAt: occ,
      source: 'wechat_csv',
      externalId: 'WX',
    );

    final r1 = await run();
    await repo.softDelete((r1 as ImportOk).tx.id);
    expect(await run(), isA<ImportOk>());
  });

  test('source=manual 时 fingerprint 为 null，同金额时间可重复写入', () async {
    final occ = DateTime.now().millisecondsSinceEpoch;
    final t1 = await repo.create(
      bookId: baseBookId,
      accountId: baseAccountId,
      categoryId: baseCategoryId,
      type: 'expense',
      amountCents: 50,
      occurredAt: occ,
      source: 'manual',
    );
    final t2 = await repo.create(
      bookId: baseBookId,
      accountId: baseAccountId,
      categoryId: baseCategoryId,
      type: 'expense',
      amountCents: 50,
      occurredAt: occ,
      source: 'manual',
    );
    expect(t1.id, isNot(t2.id));
    expect(t1.fingerprint, isNull);
  });

  test('账本隔离：另一个账本查不到本账本流水', () async {
    await repo.create(
      bookId: 'book-a',
      accountId: baseAccountId,
      categoryId: baseCategoryId,
      type: 'expense',
      amountCents: 500,
      occurredAt: DateTime(2026, 9, 5).millisecondsSinceEpoch,
    );
    expect(await repo.listByMonth('book-b', 2026, 9), isEmpty);
    expect(await repo.listByMonth('book-a', 2026, 9), hasLength(1));
  });

  test('listByYear：跨 12 个月取数，跨年 / 已删不计', () async {
    Future<void> add(DateTime at, {String book = baseBookId}) => repo.create(
      bookId: book,
      accountId: baseAccountId,
      categoryId: baseCategoryId,
      type: 'expense',
      amountCents: 100,
      occurredAt: at.millisecondsSinceEpoch,
    );

    await add(DateTime(2026, 1, 1)); // 年初边界（含）
    await add(DateTime(2026, 7, 16));
    await add(DateTime(2026, 12, 31, 23, 59)); // 年末边界（含）
    await add(DateTime(2025, 12, 31, 23, 59)); // 上一年 → 不含
    await add(DateTime(2027, 1, 1)); // 下一年 → 不含
    await add(DateTime(2026, 3, 3), book: 'book-b'); // 别的账本 → 不含

    final rows = await repo.listByYear(baseBookId, 2026);
    expect(rows, hasLength(3));
    // 倒序：年末 → 年初
    expect(rows.first.occurredAt, DateTime(2026, 12, 31, 23, 59).millisecondsSinceEpoch);

    // 软删后不再计入
    await repo.softDelete(rows.first.id);
    expect(await repo.listByYear(baseBookId, 2026), hasLength(2));
  });

  test('listByBook：全量取数（跨年跨月）、倒序、排除已删、账本隔离', () async {
    Future<TxRow> add(
      DateTime at, {
      String book = baseBookId,
      String note = '',
    }) => repo.create(
      bookId: book,
      accountId: baseAccountId,
      categoryId: baseCategoryId,
      type: 'expense',
      amountCents: 100,
      occurredAt: at.millisecondsSinceEpoch,
      note: note,
    );

    await add(DateTime(2024, 3, 5), note: '两年前');
    await add(DateTime(2026, 9, 12), note: '本月');
    await add(DateTime(2026, 9, 20), note: '本月下旬');
    // 搜索不受「不能翻到未来月」限制，未来日期的账也要能搜到
    await add(DateTime(2027, 1, 2), note: '未来月');
    await add(DateTime(2026, 5, 1), book: 'book-b', note: '别的账本');
    final deleted = await add(DateTime(2026, 6, 1), note: '待删');

    final rows = await repo.listByBook(baseBookId);
    expect(rows, hasLength(5));
    // 倒序：最新的在前
    expect(rows.first.note, '未来月');
    expect(rows.last.note, '两年前');

    await repo.softDelete(deleted.id);
    final after = await repo.listByBook(baseBookId);
    expect(after, hasLength(4));
    expect(after.map((t) => t.id), isNot(contains(deleted.id)));

    // 账本隔离
    expect(await repo.listByBook('book-b'), hasLength(1));
  });
}
