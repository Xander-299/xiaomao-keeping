/// 日历页单笔流水删除：二次确认的取消 / 确认两条路径。
///
/// PRD §删除记账与 `SPEC-F7.4-search.md` 要求删除前二次确认；
/// B2 只补「失败反馈」，不得顺手去掉确认框。
library;

import 'dart:ui' show Size;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/app.dart';
import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/core/theme/toon.dart';
import 'package:yanxin/data/providers/database.dart';
import 'package:yanxin/data/repositories/account_repository.dart';
import 'package:yanxin/data/repositories/app_meta_repository.dart';
import 'package:yanxin/data/repositories/book_repository.dart';
import 'package:yanxin/data/repositories/category_repository.dart';
import 'package:yanxin/data/repositories/transaction_repository.dart';
import 'package:yanxin/features/onboarding/application/onboarding_keys.dart';

import '../../helpers/test_database.dart';

const String _note = '日历删除测试';

Future<void> _pumpCalendar(WidgetTester tester, AppDatabase db) async {
  // 默认视口下账单行会落到导航栏下面，拖拽会命中导航；加高视口便于页面级验证。
  tester.view.physicalSize = const Size(800, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await AppMetaRepository(db).set(kOnboardingDoneKey, kOnboardingDoneValue);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
      child: const YanxinApp(),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('日历'));
  await tester.pumpAndSettle();
}

/// 今天记一笔，日历默认选中今天。
Future<void> _seedTodayTx(AppDatabase db) async {
  final Book book = await BookRepository(db).ensureDefaultBook();
  final Account account =
      (await AccountRepository(db).listByBook(book.id)).first;
  final Category category =
      (await CategoryRepository(db).listByBook(book.id, kind: 'expense')).first;
  final DateTime now = DateTime.now();
  await TransactionRepository(db).create(
    bookId: book.id,
    accountId: account.id,
    categoryId: category.id,
    type: 'expense',
    amountCents: 1234,
    occurredAt:
        DateTime(now.year, now.month, now.day, 10).millisecondsSinceEpoch,
    note: _note,
  );
}

Future<void> _openConfirm(WidgetTester tester) async {
  await tester.drag(find.text(_note), const Offset(-200, 0));
  await tester.pumpAndSettle();
  await tester.tap(find.text('删除'));
  await tester.pumpAndSettle();
}

Future<int> _activeCount(AppDatabase db) async {
  final Book book = (await BookRepository(db).listAll()).single;
  return (await TransactionRepository(db).listByBook(book.id)).length;
}

void main() {
  testWidgets('确认框点「取消」：不软删、不提示', (WidgetTester tester) async {
    final AppDatabase db = openTestDatabase();
    addTearDown(db.close);
    await _seedTodayTx(db);

    await _pumpCalendar(tester, db);
    expect(find.text(_note), findsOneWidget);

    await _openConfirm(tester);
    expect(find.text('删除这笔'), findsOneWidget);

    await tester.tap(find.widgetWithText(ToonButton, '取消'));
    await tester.pumpAndSettle();

    expect(find.text('删除这笔'), findsNothing);
    expect(find.textContaining('已删除「'), findsNothing);
    expect(find.text(_note), findsOneWidget);
    expect(await _activeCount(db), 1);
  });

  testWidgets('确认删除：流水消失并出现 Undo', (WidgetTester tester) async {
    final AppDatabase db = openTestDatabase();
    addTearDown(db.close);
    await _seedTodayTx(db);

    await _pumpCalendar(tester, db);
    await _openConfirm(tester);
    await tester.tap(find.widgetWithText(ToonButton, '删除'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text(_note), findsNothing);
    expect(find.textContaining('已删除「$_note」'), findsOneWidget);
    expect(await _activeCount(db), 0);
  });
}
