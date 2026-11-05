/// `/autobook` 页「最近一次自动记账 → 撤销」的二次确认回归。
///
/// 批量撤销会一次删掉整批流水，必须先确认；点「算了」不能动数据。
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
import 'package:yanxin/features/autobook/data/auto_book_batches.dart';
import 'package:yanxin/features/autobook/data/auto_book_bridge.dart';
import 'package:yanxin/features/autobook/data/auto_book_diagnostics.dart';
import 'package:yanxin/features/autobook/presentation/auto_book_page.dart';

import '../../helpers/test_database.dart';

/// 只实现页面要用的读取方法，原生链路全部短路。
class _FakeBridge extends AutoBookBridge {
  @override
  bool get supported => true;

  @override
  Future<bool> listenerEnabled() async => true;

  @override
  Future<bool> notificationsAllowed() async => true;

  @override
  Future<AutoBookDiagnostics?> diagnostics() async => null;

  @override
  Future<int> pendingCount() async => 0;
}

Future<String> _seedTx(AppDatabase db) async {
  final Book book = await BookRepository(db).ensureDefaultBook();
  final Account account =
      (await AccountRepository(db).listByBook(book.id)).first;
  final Category category =
      (await CategoryRepository(db).listByBook(book.id, kind: 'expense')).first;
  final TxRow tx = await TransactionRepository(db).create(
    bookId: book.id,
    accountId: account.id,
    categoryId: category.id,
    type: 'expense',
    amountCents: 1200,
    occurredAt: DateTime.now().millisecondsSinceEpoch,
    note: '自动记账撤销',
  );
  return tx.id;
}

Future<void> _pumpPage(
  WidgetTester tester,
  AppDatabase db,
  _FakeBridge bridge,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        autoBookBridgeProvider.overrideWithValue(bridge),
      ],
      child: const MaterialApp(home: AutoBookPage()),
    ),
  );
  await tester.pumpAndSettle();
}

Future<int> _visibleTx(AppDatabase db) async {
  final Book book = (await BookRepository(db).listAll()).single;
  return (await TransactionRepository(db).listByBook(book.id)).length;
}

void main() {
  testWidgets('撤销整批先弹确认；点「算了」不删任何流水', (WidgetTester tester) async {
    final AppDatabase db = openTestDatabase();
    addTearDown(db.close);
    final String txId = await _seedTx(db);
    final AutoBookBatchStore store = AutoBookBatchStore(
      ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(db)],
      ).read(appMetaRepositoryProvider),
    );
    await store.remember(
      AutoBookBatch(
        batchId: 'page-batch',
        txIds: <String>[txId],
        count: 1,
        totalCents: 1200,
        atMs: DateTime.now().millisecondsSinceEpoch,
        bookId: (await BookRepository(db).listAll()).single.id,
      ),
    );

    await _pumpPage(tester, db, _FakeBridge());

    await tester.tap(find.widgetWithText(ToonButton, '撤销'));
    await tester.pumpAndSettle();
    expect(find.text('撤销这 1 笔？'), findsOneWidget);

    await tester.tap(find.widgetWithText(ToonButton, '算了'));
    await tester.pumpAndSettle();

    expect(find.text('撤销这 1 笔？'), findsNothing);
    expect(await _visibleTx(db), 1);
    expect(await store.byId('page-batch'), isNotNull);
  });

  testWidgets('确认后整批撤销，流水软删且批次记录摘除', (WidgetTester tester) async {
    final AppDatabase db = openTestDatabase();
    addTearDown(db.close);
    final String txId = await _seedTx(db);
    final ProviderContainer container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    final AutoBookBatchStore store = container.read(autoBookBatchStoreProvider);
    await store.remember(
      AutoBookBatch(
        batchId: 'page-batch-2',
        txIds: <String>[txId],
        count: 1,
        totalCents: 1200,
        atMs: DateTime.now().millisecondsSinceEpoch,
        bookId: (await BookRepository(db).listAll()).single.id,
      ),
    );

    await _pumpPage(tester, db, _FakeBridge());

    await tester.tap(find.widgetWithText(ToonButton, '撤销'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(ToonButton, '撤销'),
      ),
    );
    await tester.pumpAndSettle();

    expect(await _visibleTx(db), 0);
    expect(await store.byId('page-batch-2'), isNull);
  });
}
