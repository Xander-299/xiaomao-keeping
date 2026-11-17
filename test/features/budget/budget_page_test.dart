/// FR-BUDGET-10 · 预算页：空态、分类行、沿用上月按钮。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/data/providers/database.dart';
import 'package:yanxin/data/repositories/book_repository.dart';
import 'package:yanxin/data/repositories/budget_repository.dart';
import 'package:yanxin/data/repositories/category_repository.dart';
import 'package:yanxin/features/budget/presentation/budget_page.dart';
import 'package:yanxin/features/ledger/application/ledger_controller.dart';

import '../../helpers/test_database.dart';

Future<void> pumpUntil(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
  }
  await tester.pumpAndSettle();
}

Future<AppDatabase> _pumpPage(WidgetTester tester) async {
  final AppDatabase db = openTestDatabase();
  addTearDown(db.close);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
      child: const MaterialApp(home: BudgetPage()),
    ),
  );
  await pumpUntil(tester, find.textContaining('分类预算'));
  return db;
}

void main() {
  testWidgets('没有分类预算：显示空态引导与「沿用上月」', (WidgetTester tester) async {
    await _pumpPage(tester);

    expect(find.text('分类预算'), findsOneWidget);
    expect(find.textContaining('还没有分类预算'), findsOneWidget);
    expect(find.text('沿用上月'), findsOneWidget);
    expect(find.text('添加分类预算'), findsOneWidget);
  });

  testWidgets('设了分类预算：列表显示额度与已花', (WidgetTester tester) async {
    final AppDatabase db = openTestDatabase();
    addTearDown(db.close);
    final Book book = await BookRepository(db).ensureDefaultBook();
    final Category food = (await CategoryRepository(
      db,
    ).listByBook(book.id, kind: 'expense')).first;
    await BudgetRepository(db).setForMonth(
      bookId: book.id,
      year: DateTime.now().year,
      month: DateTime.now().month,
      amountCents: 100000,
      categoryId: food.id,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDatabaseProvider.overrideWithValue(db)],
        child: const MaterialApp(home: BudgetPage()),
      ),
    );
    await pumpUntil(tester, find.text(food.name));

    expect(find.text(food.name), findsOneWidget);
    expect(find.textContaining('¥0.00 / ¥1000.00'), findsOneWidget);
  });

  testWidgets('预算页用首页的月份（标题带月份）', (WidgetTester tester) async {
    final AppDatabase db = await _pumpPage(tester);
    final LedgerState ledger = await ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    ).read(ledgerProvider.future);
    expect(find.text('预算 · ${ledger.month} 月'), findsOneWidget);
  });
}
