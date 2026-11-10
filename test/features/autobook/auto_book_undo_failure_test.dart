/// P3 · 自动记账「撤销一批」失败必须留下可查的原因。
///
/// 旧行为：`undo()` 里软删失败 → 事务回滚 → 异常一路冒到通知栏命令处理（那里只 `catch` 掉），
/// `autobook_last_run` 什么都不写。用户冷启动后点通知栏「撤销」，再进 `/autobook` 看到的
/// 仍是「上次检查：没有新的支付通知」—— 无从判断为什么没撤掉。
///
/// 新行为：失败时把「哪一批 + 什么错」写进 last-run（诊断块直接显示），异常照旧抛出。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/data/providers/database.dart';
import 'package:yanxin/data/repositories/account_repository.dart';
import 'package:yanxin/data/repositories/app_meta_repository.dart';
import 'package:yanxin/data/repositories/book_repository.dart';
import 'package:yanxin/data/repositories/category_repository.dart';
import 'package:yanxin/data/repositories/transaction_repository.dart';
import 'package:yanxin/features/autobook/application/auto_book_notice.dart';
import 'package:yanxin/features/autobook/data/auto_book_batches.dart';
import 'package:yanxin/features/autobook/data/auto_book_diagnostics.dart';

import '../../helpers/test_database.dart';

void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late Book book;
  late String txId;

  setUp(() async {
    db = openTestDatabase();
    addTearDown(db.close);
    book = await BookRepository(db).ensureDefaultBook();
    final Account account =
        (await AccountRepository(db).listByBook(book.id)).first;
    final Category category =
        (await CategoryRepository(db).listByBook(book.id, kind: 'expense')).first;
    final TxRow tx = await TransactionRepository(db).create(
      bookId: book.id,
      accountId: account.id,
      categoryId: category.id,
      type: 'expense',
      amountCents: 900,
      occurredAt: DateTime.now().millisecondsSinceEpoch,
      note: '撤销失败用例',
    );
    txId = tx.id;
    container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
  });

  Future<AutoBookLastRun?> lastRun() async =>
      AutoBookLastRun.parse(await AppMetaRepository(db).get(kAutoBookLastRunKey));

  test('撤销失败：把批次与错误写进 last-run，异常照旧抛出', () async {
    final AutoBookBatch batch = AutoBookBatch(
      batchId: 'batch-fail-1',
      txIds: <String>[txId],
      count: 1,
      totalCents: 900,
      atMs: DateTime.now().millisecondsSinceEpoch,
      bookId: book.id,
    );
    await AutoBookBatchStore(AppMetaRepository(db)).remember(batch);

    // 让软删那一步必然失败（`UPDATE ... SET deleted_at` 直接 ABORT）。
    await db.customStatement('''
CREATE TRIGGER autobook_undo_boom BEFORE UPDATE OF deleted_at ON transactions
WHEN NEW.deleted_at IS NOT NULL
BEGIN
  SELECT RAISE(ABORT, 'disk full');
END
''');

    await expectLater(
      container.read(autoBookNoticeProvider.notifier).undo('batch-fail-1'),
      throwsA(anything),
    );

    final AutoBookLastRun? run = await lastRun();
    expect(run, isNotNull, reason: '失败必须留痕，否则诊断块看不到原因');
    expect(run!.error, contains('batch-fail-1'));
    expect(run.error, contains('撤销批次'));
  });

  test('撤销成功：不写错误（避免成功也留个红字）', () async {
    final AutoBookBatch batch = AutoBookBatch(
      batchId: 'batch-ok-1',
      txIds: <String>[txId],
      count: 1,
      totalCents: 900,
      atMs: DateTime.now().millisecondsSinceEpoch,
      bookId: book.id,
    );
    await AutoBookBatchStore(AppMetaRepository(db)).remember(batch);

    final int deleted =
        await container.read(autoBookNoticeProvider.notifier).undo('batch-ok-1');

    expect(deleted, 1);
    expect((await lastRun())?.error ?? '', isEmpty);
  });
}
