// F4 冒烟 + M1 等价关键路径（UI 层）。
//
// 冷启动/持久化/账本隔离等 DB 层语义已在 test/core/db、test/data/repositories 覆盖；
// 这里验证「点得动」：记一笔 → 列表出现 → 编辑 → 左滑删除。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/core/theme/toon.dart';
import 'package:yanxin/data/repositories/account_repository.dart';
import 'package:yanxin/data/repositories/book_repository.dart';
import 'package:yanxin/data/repositories/category_repository.dart';
import 'package:yanxin/data/repositories/transaction_repository.dart';

import 'helpers/pick_category.dart';
import 'helpers/pump_app.dart';

/// 等 DB 写库 + invalidate 触发的重建到位（写库是真实异步，pumpAndSettle 可能抢先返回）。
Future<void> pumpUntil(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
  }
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('冷启动进入首页并自动建默认账本', (WidgetTester tester) async {
    await pumpApp(tester);

    expect(find.text('默认账本'), findsOneWidget);
    expect(find.textContaining('还没有记账'), findsOneWidget);
  });

  testWidgets('记一笔支出 → 首页出现该笔且金额为负', (WidgetTester tester) async {
    final db = openTestDatabase();
    // 预建账本，拿到 categoryId
    final book = await BookRepository(db).ensureDefaultBook();
    final cat = (await CategoryRepository(db).listByBook(book.id, kind: 'expense')).first;
    addTearDown(db.close);

    await pumpApp(tester, database: db);

    await tester.tap(find.byTooltip('记一笔'));
    await tester.pumpAndSettle();

    // 输金额 12
    await tester.tap(find.text('1'));
    await tester.tap(find.text('2'));
    // 选分类
    await tester.tap(find.text('请选择分类'));
    await tester.pumpAndSettle();
    await pickCategory(tester, cat.name);
    // 保存：F7.6 起主按钮是 ToonButton（胶囊），不再是 FilledButton；
    // F7.9 起按钮**吸底常驻**、位于 Scrollable 的兄弟节点 →
    // **不能**再 ensureVisible（`Scrollable.of` 返回 null 会直接报错）。
    await tester.tap(find.widgetWithText(ToonButton, '记一笔'));
    await tester.pumpAndSettle();

    // 回到首页：hero 结余 -12.00、支出 12.00，列表出现 -12.00
    // （保存后的 refresh 走真实异步读库，用 pumpUntil 等待）
    await pumpUntil(tester, find.text('-12.00'));
    expect(find.text('-12.00'), findsNWidgets(2)); // hero 结余 + 列表金额
    expect(find.text('12.00'), findsOneWidget); // hero 支出
  });

  testWidgets('左滑删除 → 列表消失回到空态', (WidgetTester tester) async {
    final db = openTestDatabase();
    final book = await BookRepository(db).ensureDefaultBook();
    final cat = (await CategoryRepository(db).listByBook(book.id, kind: 'expense')).first;
    addTearDown(db.close);

    await pumpApp(tester, database: db);

    // 通过 UI 记一笔
    await tester.tap(find.byTooltip('记一笔'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1'));
    await tester.tap(find.text('请选择分类'));
    await tester.pumpAndSettle();
    await pickCategory(tester, cat.name);
    await tester.tap(find.widgetWithText(ToonButton, '记一笔'));
    await tester.pumpAndSettle();
    expect(find.text('-1.00'), findsNWidgets(2)); // hero 结余 + 列表金额

    // F7.8：删除入口 = **左滑**（长按已移除）。滑列表里的分类名，避开 hero 上的金额。
    // 视口 800×600 下列表项会被预算卡挤出屏幕 → 必须先滚进可视区，否则
    // drag 落空（"would not hit test"）。
    await tester.ensureVisible(find.text(cat.name));
    await tester.pumpAndSettle();
    await tester.drag(find.text(cat.name), const Offset(-200, 0));
    await tester.pumpAndSettle();

    // 动作区的「删除」此刻唯一 → 点它直接删（不再弹确认框），出 SnackBar
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await pumpUntil(tester, find.textContaining('还没有记账'));

    expect(find.textContaining('还没有记账'), findsOneWidget);
    expect(find.textContaining('已删除「'), findsOneWidget);

    // 撤销：SnackBar 上的「撤销」→ 记录恢复回列表
    await tester.tap(find.text('撤销'));
    await pumpUntil(tester, find.text(cat.name));
    expect(find.text(cat.name), findsOneWidget);
  });

  testWidgets('hero 翻月：上月有账则能看到上月流水', (WidgetTester tester) async {
    final db = openTestDatabase();
    final bookRepo = BookRepository(db);
    final catRepo = CategoryRepository(db);
    final book = await bookRepo.ensureDefaultBook();
    final cat = (await catRepo.listByBook(book.id, kind: 'expense')).first;
    final now = DateTime.now();
    final prevMonth = DateTime(now.year, now.month - 1, 15);
    await TransactionRepository(db).create(
      bookId: book.id,
      accountId: (await AccountRepository(db).listByBook(book.id)).first.id,
      categoryId: cat.id,
      type: 'expense',
      amountCents: 2500,
      occurredAt: prevMonth.millisecondsSinceEpoch,
    );
    addTearDown(db.close);

    await pumpApp(tester, database: db);
    expect(find.textContaining('还没有记账'), findsOneWidget);

    await tester.tap(find.text('‹'));
    await tester.pumpAndSettle();
    expect(find.text('-25.00'), findsNWidgets(2)); // hero 结余 + 列表金额
  });

  testWidgets('分类管理：新建自定义分类并出现在列表', (WidgetTester tester) async {
    await pumpApp(tester);

    // 入口在「我的」tab
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('分类管理'));
    await tester.pumpAndSettle();
    // 入口是右下角的浮动按钮（AppBar 的「＋」已移除，2026-10-29）
    await tester.tap(find.byTooltip('添加分类'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加一级分类'));
    await tester.pumpAndSettle();
    // schema v4 起是「分类编辑弹层」（名称 + 父分类 + 图标 + 颜色），不再是单行对话框
    await tester.enterText(find.byType(TextField).first, '打车');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    // 先等弹层关掉：淡出动画期间 EditableText 也匹配 '打车'，直接断言会「找到 2 个」
    for (var i = 0; i < 20 && find.byType(TextField).evaluate().isNotEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();

    // 新建在列表末尾（11 个预置之后），800×600 视口里 ListView 不会建到它 →
    // 用滚动代替直接 find（这是 v4 预置变多带来的测试口径变化）。
    await tester.scrollUntilVisible(
      find.text('打车'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('打车'), findsOneWidget);
  });

  testWidgets('新建账本并切换，首页随切刷新', (WidgetTester tester) async {
    final db = openTestDatabase();
    await BookRepository(db).ensureDefaultBook();
    addTearDown(db.close);

    await pumpApp(tester, database: db);

    // 首页 header 点开抽屉 → 管理账本
    await tester.tap(find.text('默认账本'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('管理账本'));
    await tester.pumpAndSettle();

    // 新建账本 B（创建即切换）
    await tester.tap(find.byTooltip('新建账本'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'B账本');
    await tester.tap(find.text('确定'));
    // 创建后自动切换并 pop 回首页；先等对话框关掉（避免命中输入框文本），
    // 再等 header 变成 B账本
    for (var i = 0; i < 20 && find.byType(TextField).evaluate().isNotEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await pumpUntil(tester, find.text('B账本'));
    expect(find.text('B账本'), findsOneWidget);
  });

  testWidgets('抽屉切换账本，首页流水随切刷新', (WidgetTester tester) async {
    final db = openTestDatabase();
    final bookRepo = BookRepository(db);
    final bookA = await bookRepo.ensureDefaultBook();
    final bookB = await bookRepo.create(name: 'B账本');

    // 在 B 账本记一笔支出 5.00
    final cat = (await CategoryRepository(db).listByBook(bookB.id, kind: 'expense')).first;
    final accountId = (await AccountRepository(db).listByBook(bookB.id)).first.id;
    await TransactionRepository(db).create(
      bookId: bookB.id,
      accountId: accountId,
      categoryId: cat.id,
      type: 'expense',
      amountCents: 500,
      occurredAt: DateTime.now().millisecondsSinceEpoch,
    );
    addTearDown(db.close);

    await pumpApp(tester, database: db);
    expect(find.textContaining('还没有记账'), findsOneWidget); // A 账本为空

    // 打开抽屉切到 B
    await tester.tap(find.text('默认账本'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('B账本'));
    await pumpUntil(tester, find.text('-5.00'));

    expect(find.text('-5.00'), findsNWidgets(2)); // hero 结余 + 列表金额
    expect(bookA.id, isNotNull);
  });
}
