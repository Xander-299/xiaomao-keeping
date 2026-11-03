/// Batch B / B2：首页删除写路径的失败与成功。
library;

import 'dart:ui' show Size;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/app.dart';
import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/data/providers/database.dart';
import 'package:yanxin/data/repositories/account_repository.dart';
import 'package:yanxin/data/repositories/app_meta_repository.dart';
import 'package:yanxin/data/repositories/book_repository.dart';
import 'package:yanxin/data/repositories/category_repository.dart';
import 'package:yanxin/data/repositories/transaction_repository.dart';
import 'package:yanxin/features/onboarding/application/onboarding_keys.dart';

import '../../helpers/test_database.dart';

class _FailingDeleteRepo extends TransactionRepository {
  _FailingDeleteRepo(super.db);

  @override
  Future<int> softDelete(String id) async {
    throw StateError('database is locked');
  }
}

Future<void> _pumpApp(
  WidgetTester tester,
  AppDatabase db,
  TransactionRepository repo,
) async {
  // 默认 800×600 时，列表行会落在底栏/导航栏下面，拖拽会命中底栏；
  // 用更高的视口验证「页面级」删除反馈，不改变生产布局。
  tester.view.physicalSize = const Size(800, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await AppMetaRepository(db).set(kOnboardingDoneKey, kOnboardingDoneValue);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        transactionRepositoryProvider.overrideWithValue(repo),
      ],
      child: const YanxinApp(),
    ),
  );
  await tester.pumpAndSettle();
}

Future<String> _seedTx(AppDatabase db, String note) async {
  final Book book = await BookRepository(db).ensureDefaultBook();
  final Account account = (await AccountRepository(db).listByBook(book.id)).first;
  final Category category =
      (await CategoryRepository(db).listByBook(book.id, kind: 'expense')).first;
  final DateTime now = DateTime.now();
  final TxRow tx = await TransactionRepository(db).create(
    bookId: book.id,
    accountId: account.id,
    categoryId: category.id,
    type: 'expense',
    amountCents: 1234,
    occurredAt: DateTime(now.year, now.month, now.day, 10).millisecondsSinceEpoch,
    note: note,
  );
  return tx.id;
}

Future<void> _swipeDelete(WidgetTester tester, String note) async {
  await tester.drag(find.text(note), const Offset(-200, 0));
  await tester.pumpAndSettle();
  await tester.tap(find.text('删除'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('删除遇到数据库异常：显示失败、不出现 Undo、流水仍在', (
    WidgetTester tester,
  ) async {
    final AppDatabase db = openTestDatabase();
    addTearDown(db.close);
    const String note = '删除失败测试';
    await _seedTx(db, note);

    await _pumpApp(tester, db, _FailingDeleteRepo(db));
    expect(find.text(note), findsOneWidget);

    await _swipeDelete(tester, note);

    expect(find.text('删除失败，请稍后重试'), findsOneWidget);
    expect(find.textContaining('已删除「'), findsNothing);
    expect(find.text(note), findsOneWidget);
    // 失败后仍然是活跃流水
    final Book book = (await BookRepository(db).listAll()).single;
    expect(await TransactionRepository(db).listByBook(book.id), hasLength(1));
  });

  testWidgets('删除成功：出现 Undo，流水从列表消失', (WidgetTester tester) async {
    final AppDatabase db = openTestDatabase();
    addTearDown(db.close);
    const String note = '删除成功测试';
    await _seedTx(db, note);

    await _pumpApp(tester, db, TransactionRepository(db));
    await _swipeDelete(tester, note);

    expect(find.textContaining('已删除「$note」'), findsOneWidget);
    expect(find.text(note), findsNothing);
  });
}
