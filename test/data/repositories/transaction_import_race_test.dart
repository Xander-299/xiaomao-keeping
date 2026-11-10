/// P3 · 导入指纹并发竞争。
///
/// 旧行为：`importTransaction` 先 `SELECT` 预查同指纹，再 `INSERT`。两步之间若有另一个入口
/// （并发的第二次导入 / 自动记账）写入了同指纹行，`INSERT` 会撞 `(book_id, fingerprint)`
/// 唯一索引并**抛错** —— 于是整批导入回滚，用户看到「导入失败」，而事实是「这笔早就有了」。
///
/// 新行为：`INSERT OR IGNORE` —— 被唯一索引挡下时不抛错、只不写；随后回查同指纹行，
/// 查到就返回 [ImportDuplicate]（幂等口径）。既没写进去又查不到（非空 / 外键等其它约束）
/// 才抛 `StateError`，不假装成功。
///
/// 这里用 SQLite trigger 精确复现「预查与插入之间冒出同指纹行」：trigger 在外层 INSERT
/// 之前先插一条同指纹的，`INSERT OR IGNORE` 必然被忽略。
/// （注：不能用「插失败 + catch 回查」的写法 —— SQLite 的 ABORT 会回滚整条语句、包括触发器写入的行，
/// 失败后什么都查不到。）
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/data/repositories/transaction_repository.dart';

import '../../helpers/test_database.dart';

void main() {
  late AppDatabase db;
  late TransactionRepository repo;

  setUp(() async {
    db = openTestDatabase();
    addTearDown(db.close);
    repo = TransactionRepository(db);
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

  Future<ImportResult> importOnce({String externalId = 'ext-1'}) {
    return repo.importTransaction(
      bookId: 'b1',
      accountId: 'a1',
      categoryId: 'c1',
      type: 'expense',
      amountCents: 1234,
      occurredAt: 1000,
      source: 'wechat_csv',
      externalId: externalId,
    );
  }

  Future<int> activeCount() async {
    final rows = await db
        .customSelect(
          'SELECT COUNT(*) AS c FROM transactions '
          "WHERE book_id = 'b1' AND deleted_at IS NULL",
        )
        .getSingle();
    return rows.read<int>('c');
  }

  test('并发写入同指纹：归为 duplicate，不抛错，库里仍只有一行', () async {
    // 模拟「另一个入口在预查之后、插入之前抢先写入」。
    await db.customStatement('''
CREATE TRIGGER tx_import_race BEFORE INSERT ON transactions
WHEN NEW.fingerprint IS NOT NULL
 AND (SELECT COUNT(*) FROM transactions
      WHERE book_id = NEW.book_id AND fingerprint = NEW.fingerprint) = 0
BEGIN
  INSERT INTO transactions(
    id, book_id, account_id, type, amount_cents, occurred_at,
    source, fingerprint, created_at, updated_at)
  VALUES('race-' || NEW.id, NEW.book_id, NEW.account_id, NEW.type,
         NEW.amount_cents, NEW.occurred_at, NEW.source, NEW.fingerprint,
         NEW.created_at, NEW.updated_at);
END
''');

    final ImportResult res = await importOnce();

    expect(res, isA<ImportDuplicate>());
    expect((res as ImportDuplicate).existingTx.id, startsWith('race-'));
    expect((res).existingTx.fingerprint, isNotNull);
    expect(await activeCount(), 1, reason: '兜底那一行不该再多插一条');
  });

  test('插入真失败（查不到同指纹行）：异常照旧抛出，不被吞成 duplicate', () async {
    // 无并发、纯失败：trigger 直接 ABORT，回查也查不到 → 必须 rethrow。
    await db.customStatement('''
CREATE TRIGGER tx_import_boom BEFORE INSERT ON transactions
BEGIN
  SELECT RAISE(ABORT, 'disk full');
END
''');

    await expectLater(importOnce(), throwsA(anything));
    expect(await activeCount(), 0);
  });

  test('正常路径不受影响：首次导入成功，第二次同指纹跳过', () async {
    final ImportResult first = await importOnce();
    expect(first, isA<ImportOk>());
    final ImportResult second = await importOnce();
    expect(second, isA<ImportDuplicate>());
    expect(await activeCount(), 1);
  });
}
