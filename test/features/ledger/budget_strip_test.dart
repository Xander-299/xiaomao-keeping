/// 一行预算条测试：未设置引导 / 已设置显示剩余与百分比 / 点击开编辑弹层。
///
/// 预算口径不变（`buildBudgetView`），这里只验证「整卡降级成一行」之后：
/// 数字还在、状态还在、点击还能编辑。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/core/theme/palette.dart';
import 'package:yanxin/core/theme/tokens.dart';
import 'package:yanxin/data/providers/database.dart';
import 'package:yanxin/data/repositories/account_repository.dart';
import 'package:yanxin/data/repositories/book_repository.dart';
import 'package:yanxin/data/repositories/budget_repository.dart';
import 'package:yanxin/data/repositories/category_repository.dart';
import 'package:yanxin/data/repositories/transaction_repository.dart';
import 'package:yanxin/features/ledger/presentation/widgets/budget_strip.dart';

import '../../helpers/category_seed.dart';
import '../../helpers/test_database.dart';

/// 当月记一笔（金额 = 1000.00 元）。
Future<({AppDatabase db, Book book})> _seed({int? budgetCents}) async {
  final AppDatabase db = openTestDatabase();
  final Book book = await BookRepository(db).ensureDefaultBook();
  final Category food = await ensureCategory(
    CategoryRepository(db),
    book.id,
    '餐饮',
  );
  final Account acc = await AccountRepository(db).create(bookId: book.id, name: '现金');
  final DateTime now = DateTime.now();
  await TransactionRepository(db).create(
    bookId: book.id,
    accountId: acc.id,
    type: 'expense',
    amountCents: 100000,
    occurredAt: DateTime(now.year, now.month, 2, 12).millisecondsSinceEpoch,
    categoryId: food.id,
    note: '午饭',
  );
  if (budgetCents != null) {
    await BudgetRepository(db).setForMonth(
      bookId: book.id,
      year: now.year,
      month: now.month,
      amountCents: budgetCents,
    );
  }
  return (db: db, book: book);
}

Future<void> _pump(WidgetTester tester, AppDatabase db) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
      child: MaterialApp(
        theme: buildToonTheme(ToonPalette.light, Brightness.light),
        home: const Scaffold(body: Padding(padding: EdgeInsets.all(8), child: BudgetStrip())),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('没设预算：显示「设本月预算」引导', (WidgetTester tester) async {
    final r = await _seed();
    addTearDown(r.db.close);
    await _pump(tester, r.db);

    expect(find.text('设本月预算'), findsOneWidget);
  });

  testWidgets('已设预算：显示预算金额、百分比与剩余', (WidgetTester tester) async {
    final r = await _seed(budgetCents: 200000); // 预算 ¥2000，已花 ¥1000
    addTearDown(r.db.close);
    await _pump(tester, r.db);

    expect(find.text('预算 ¥2,000.00'), findsOneWidget);
    expect(find.text('50.0%'), findsOneWidget);
    expect(find.textContaining('还剩 ¥1000.00'), findsOneWidget);
  });

  testWidgets('超支：显示「已超支」', (WidgetTester tester) async {
    final r = await _seed(budgetCents: 50000); // 预算 ¥500，已花 ¥1000
    addTearDown(r.db.close);
    await _pump(tester, r.db);

    expect(find.textContaining('已超支 ¥500.00'), findsOneWidget);
  });

  testWidgets('点这一行 → 进预算页（FR-BUDGET-10 改了入口）', (WidgetTester tester) async {
    final r = await _seed(budgetCents: 200000);
    addTearDown(r.db.close);

    // 入口现在是路由跳转（/budget），所以这里要挂一个最小 GoRouter
    final GoRouter router = GoRouter(
      initialLocation: '/',
      routes: <RouteBase>[
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: BudgetStrip()),
        ),
        GoRoute(
          path: '/budget',
          builder: (_, _) => const Scaffold(body: Text('预算页占位')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDatabaseProvider.overrideWithValue(r.db)],
        child: MaterialApp.router(
          theme: buildToonTheme(ToonPalette.light, Brightness.light),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('预算 ¥2,000.00'));
    await tester.pumpAndSettle();

    expect(find.text('预算页占位'), findsOneWidget);
  });
}
