/// P3 · 换账本时日历必须跟着换。
///
/// `CalendarController` 刻意**不 watch** 账本（翻月不该把首页月份带走），代价是换账本后
/// 实例还活着：在途请求不会被 `_disposed` 拦住，旧账本的结果会被写进新账本视图。
/// 只比对请求里的 bookId 也没用 —— 在途请求手里的旧 id 与字段里的旧 id 永远相等。
///
/// 现在的做法：`build()` 里监听 `activeBookIdProvider`，账本真的变了就 `invalidateSelf`，
/// 旧实例 dispose → 迟到结果全丢，新实例按新账本重拉。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/data/providers/book_providers.dart';
import 'package:yanxin/data/providers/database.dart';
import 'package:yanxin/data/repositories/account_repository.dart';
import 'package:yanxin/data/repositories/book_repository.dart';
import 'package:yanxin/data/repositories/category_repository.dart';
import 'package:yanxin/data/repositories/transaction_repository.dart';
import 'package:yanxin/features/calendar/application/calendar_controller.dart';

import '../../helpers/test_database.dart';

Future<void> _settle() async {
  for (var i = 0; i < 12; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> _seedToday(AppDatabase db, Book book, String note) async {
  final Account account = (await AccountRepository(db).listByBook(book.id)).first;
  final Category category =
      (await CategoryRepository(db).listByBook(book.id, kind: 'expense')).first;
  final DateTime now = DateTime.now();
  await TransactionRepository(db).create(
    bookId: book.id,
    accountId: account.id,
    categoryId: category.id,
    type: 'expense',
    amountCents: 1000,
    occurredAt: DateTime(now.year, now.month, now.day, 10).millisecondsSinceEpoch,
    note: note,
  );
}

void main() {
  test('切换账本：日历重建并显示新账本当天的流水', () async {
    final AppDatabase db = openTestDatabase();
    addTearDown(db.close);

    final BookRepository bookRepo = BookRepository(db);
    final Book b1 = await bookRepo.ensureDefaultBook();
    final Book b2 = await bookRepo.create(name: '第二本');
    await _seedToday(db, b1, '第一本的钱');
    await _seedToday(db, b2, '第二本的钱');

    final ProviderContainer container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);

    await container.read(activeBookIdProvider.future);
    container.read(calendarProvider);
    await _settle();

    List<String> notes() => container
        .read(calendarProvider)
        .selectedItems
        .map((TxRow t) => t.note)
        .toList();

    expect(notes(), contains('第一本的钱'));
    expect(notes(), isNot(contains('第二本的钱')));

    await container.read(activeBookIdProvider.notifier).select(b2.id);
    await _settle();
    // 重建后的第一次加载是新的异步链，再多给几轮事件循环。
    container.read(calendarProvider);
    await _settle();

    expect(notes(), contains('第二本的钱'), reason: '换账本后必须看到新账本的数据');
    expect(notes(), isNot(contains('第一本的钱')), reason: '旧账本的流水不能留在视图里');
  });
}
