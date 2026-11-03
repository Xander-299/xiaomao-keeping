/// Batch B / B2：手动保存失败（非业务异常）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/core/theme/toon.dart';
import 'package:yanxin/data/providers/database.dart';
import 'package:yanxin/data/repositories/account_repository.dart';
import 'package:yanxin/data/repositories/book_repository.dart';
import 'package:yanxin/data/repositories/category_repository.dart';
import 'package:yanxin/data/repositories/transaction_repository.dart';
import 'package:yanxin/features/record/presentation/record_page.dart';

import '../../helpers/pick_category.dart';
import '../../helpers/test_database.dart';

class _FailingCreateRepo extends TransactionRepository {
  _FailingCreateRepo(super.db);

  @override
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
  }) async {
    throw StateError('disk I/O error');
  }
}

void main() {
  testWidgets('保存遇到存储异常：显示失败、留在页面、按钮恢复可用', (WidgetTester tester) async {
    final AppDatabase db = openTestDatabase();
    addTearDown(db.close);
    final Book book = await BookRepository(db).ensureDefaultBook();
    final Category category =
        (await CategoryRepository(db).listByBook(book.id, kind: 'expense')).first;
    await AccountRepository(db).listByBook(book.id); // 确保默认账户已建

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          transactionRepositoryProvider.overrideWithValue(
            _FailingCreateRepo(db),
          ),
        ],
        child: const MaterialApp(home: RecordPage()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('5'));
    await tester.tap(find.text('请选择分类'));
    await tester.pumpAndSettle();
    await pickCategory(tester, category.name);

    await tester.tap(find.widgetWithText(ToonButton, '记一笔'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('保存失败，请稍后重试'), findsOneWidget);
    // 没有成功 pop：保存按钮还在，且 onPressed 已恢复
    final ToonButton save = tester.widget<ToonButton>(
      find.widgetWithText(ToonButton, '记一笔'),
    );
    expect(save.onPressed, isNotNull);

    // 失败不能写入任何流水
    expect(await TransactionRepository(db).listByBook(book.id), isEmpty);
  });
}
