/// 日历页 widget 测试：月历标注、选中日账单、月汇总、月份选择子页、按日期记一笔。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yanxin/core/theme/toon.dart';
import 'package:yanxin/data/providers/database.dart';
import 'package:yanxin/data/repositories/account_repository.dart';
import 'package:yanxin/data/repositories/book_repository.dart';
import 'package:yanxin/data/repositories/category_repository.dart';
import 'package:yanxin/data/repositories/transaction_repository.dart';
import 'package:yanxin/features/calendar/presentation/widgets/month_grid.dart';
import 'package:yanxin/features/record/presentation/record_page.dart';

import '../../helpers/pick_category.dart';
import '../../helpers/pump_app.dart';

/// 等异步写库 + provider 重建到位。
Future<void> pumpUntil(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
  }
  await tester.pumpAndSettle();
}

void main() {
  /// 造一个「不是今天」的日号（各月都存在，且不等于今天）。
  int otherDay() {
    final int today = DateTime.now().day;
    return today == 15 ? 16 : 15;
  }

  Future<void> seedMonthTx(
    dynamic db, {
    required int day,
    int expense = 2350,
    int income = 2000,
  }) async {
    final book = await BookRepository(db).ensureDefaultBook();
    final catRepo = CategoryRepository(db);
    final expenseCat = (await catRepo.listByBook(book.id, kind: 'expense')).first;
    final incomeCat = (await catRepo.listByBook(book.id, kind: 'income')).first;
    final accountId = (await AccountRepository(db).listByBook(book.id)).first.id;
    final now = DateTime.now();
    final repo = TransactionRepository(db);
    if (expense > 0) {
      await repo.create(
        bookId: book.id,
        accountId: accountId,
        categoryId: expenseCat.id,
        type: 'expense',
        amountCents: expense,
        occurredAt: DateTime(now.year, now.month, day, 10).millisecondsSinceEpoch,
        note: '午餐',
      );
    }
    if (income > 0) {
      await repo.create(
        bookId: book.id,
        accountId: accountId,
        categoryId: incomeCat.id,
        type: 'income',
        amountCents: income,
        occurredAt: DateTime(now.year, now.month, day, 12).millisecondsSinceEpoch,
        note: '红包',
      );
    }
  }

  testWidgets('日历 tab：显示年月、表头、每日标注与月汇总', (WidgetTester tester) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final int day = otherDay();
    await seedMonthTx(db, day: day);

    await pumpApp(tester, database: db);
    await tester.tap(find.text('日历'));
    await tester.pumpAndSettle();

    final DateTime now = DateTime.now();
    expect(find.text('${now.year}年${now.month}月'), findsOneWidget);
    // 表头（周日起始）
    for (final String w in <String>['日', '一', '二', '三', '四', '五', '六']) {
      expect(find.text(w), findsOneWidget);
    }
    // 当天支出负号、收入正号（紧凑写法）
    expect(find.text('-23.5'), findsOneWidget);
    expect(find.text('+20'), findsOneWidget);
    // 月汇总条
    expect(find.text('月结余'), findsOneWidget);
    expect(find.text('日均支出'), findsOneWidget);
  });

  testWidgets('点日历某天 → 下方显示该天账单；今天默认选中且为空态', (WidgetTester tester) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final int day = otherDay();
    await seedMonthTx(db, day: day);

    await pumpApp(tester, database: db);
    await tester.tap(find.text('日历'));
    await tester.pumpAndSettle();

    // 默认选中今天 → 今天没有账单
    expect(find.textContaining('今天'), findsOneWidget);
    expect(find.text('这天没有账单哦，赶紧记一笔吧~'), findsOneWidget);

    // 点第 day 天 → 显示该天两笔（餐饮/红包由分类名呈现，金额两位小数）
    await tester.tap(find.text('$day'));
    await tester.pumpAndSettle();
    expect(find.textContaining('${DateTime.now().month}月$day日'), findsOneWidget);
    expect(find.text('-23.50'), findsOneWidget);
    expect(find.text('+20.00'), findsOneWidget);
    expect(find.text('这天没有账单哦，赶紧记一笔吧~'), findsNothing);
  });

  testWidgets('日历空态「记一笔」→ 记一笔页日期带入选中日', (WidgetTester tester) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    await BookRepository(db).ensureDefaultBook();

    await pumpApp(tester, database: db);
    await tester.tap(find.text('日历'));
    await tester.pumpAndSettle();

    final int day = otherDay();
    await tester.tap(find.text('$day'));
    await tester.pumpAndSettle();
    // 800×600 测试视口下空态按钮在折叠下方 → 先滚进可视区
    await tester.ensureVisible(find.text('记一笔'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('记一笔'));
    await tester.pumpAndSettle();

    final DateTime now = DateTime.now();
    expect(find.text('日期'), findsOneWidget);
    expect(find.textContaining('${now.year}年${now.month}月$day日'), findsOneWidget);
  });

  testWidgets('点 header 年月 → 月份选择子页；点缩略图某天 → 回到日历并切月选日', (
    WidgetTester tester,
  ) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    await BookRepository(db).ensureDefaultBook();

    await pumpApp(tester, database: db);
    await tester.tap(find.text('日历'));
    await tester.pumpAndSettle();

    final int year = DateTime.now().year;
    await tester.tap(find.text('$year年${DateTime.now().month}月'));
    await tester.pumpAndSettle();

    // 子页：标题为年份，12 个月缩略图 + 年份切换
    expect(find.text('$year年'), findsOneWidget);
    for (int m = 1; m <= 12; m++) {
      expect(find.text('$m月'), findsOneWidget);
    }
    expect(find.text('‹ 上一年'), findsOneWidget);
    expect(find.text('下一年 ›'), findsOneWidget);

    // 点 3 月的 7 号 → 回日历页且切到 3 月并选中 7 日
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('mini-month-3')),
        matching: find.text('7'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('$year年3月'), findsOneWidget);
    expect(find.textContaining('3月7日'), findsOneWidget);
  });

  testWidgets('子页「上一年/下一年」切换年份；未来年不可去（R2）', (
    WidgetTester tester,
  ) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    await BookRepository(db).ensureDefaultBook();

    await pumpApp(tester, database: db);
    await tester.tap(find.text('日历'));
    await tester.pumpAndSettle();

    final int year = DateTime.now().year;
    await tester.tap(find.text('$year年${DateTime.now().month}月'));
    await tester.pumpAndSettle();

    // 当前年：下一年是禁用的（与首页 / 网格同口径）
    await tester.tap(find.text('下一年 ›'));
    await tester.pumpAndSettle();
    expect(find.text('$year年'), findsOneWidget, reason: '不能翻到未来年');

    await tester.tap(find.text('‹ 上一年'));
    await tester.pumpAndSettle();
    expect(find.text('${year - 1}年'), findsOneWidget);

    // 回到当前年（历史年之间可以来回切）
    await tester.tap(find.text('下一年 ›'));
    await tester.pumpAndSettle();
    expect(find.text('$year年'), findsOneWidget);
  });

  testWidgets('记一笔：传入 occurredAtMs 时按该日期入账', (WidgetTester tester) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final book = await BookRepository(db).ensureDefaultBook();
    final cat = (await CategoryRepository(db).listByBook(book.id, kind: 'expense')).first;
    final target = DateTime(2026, 3, 7, 9, 30);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDatabaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: RecordPage(occurredAtMs: target.millisecondsSinceEpoch),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 日期字段展示目标日期
    expect(find.text('日期'), findsOneWidget);
    expect(find.textContaining('2026年3月7日'), findsOneWidget);

    // 录金额 5.00 + 选分类 + 保存
    await tester.tap(find.text('5'));
    await tester.pump();
    await tester.tap(find.text('请选择分类'));
    await tester.pumpAndSettle();
    await pickCategory(tester, cat.name);
    // F7.6 起主按钮是 ToonButton（胶囊），不再是 FilledButton；
    // F7.9 起吸底常驻（不在 Scrollable 内）→ 不能再 ensureVisible
    await tester.tap(find.widgetWithText(ToonButton, '记一笔'));
    await tester.pumpAndSettle();

    final rows = await TransactionRepository(db).listByMonth(book.id, 2026, 3);
    expect(rows, hasLength(1));
    final DateTime at = DateTime.fromMillisecondsSinceEpoch(rows.first.occurredAt);
    expect(at.year, 2026);
    expect(at.month, 3);
    expect(at.day, 7);
    expect(rows.first.amountCents, 500);
    // 3 月的账不该出现在 9 月
    expect(await TransactionRepository(db).listByMonth(book.id, 2026, 9), isEmpty);
  });

  // ===== F7.7 E 批：长按快速记一笔 / 左右滑动翻月 =====

  testWidgets('长按日历某天 → 直接进「记一笔」并带上该日期（E 批）', (
    WidgetTester tester,
  ) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    await BookRepository(db).ensureDefaultBook();

    await pumpApp(tester, database: db);
    await tester.tap(find.text('日历'));
    await tester.pumpAndSettle();

    final int day = otherDay();
    await tester.longPress(find.text('$day'));
    await tester.pumpAndSettle();

    // 直接落在记一笔页，日期 = 长按那天（毫秒口径，与空态「记一笔」按钮一致）
    expect(find.text('日期'), findsOneWidget);
    final DateTime now = DateTime.now();
    expect(find.textContaining('${now.year}年${now.month}月$day日'), findsOneWidget);
  });

  testWidgets('月历左右滑动：能回看历史月，但翻不到未来月（R2）', (
    WidgetTester tester,
  ) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    await BookRepository(db).ensureDefaultBook();

    await pumpApp(tester, database: db);
    await tester.tap(find.text('日历'));
    await tester.pumpAndSettle();

    final DateTime now = DateTime.now();
    final DateTime prev = DateTime(now.year, now.month - 1);
    final String header = '${now.year}年${now.month}月';

    // 左滑 = 下一个月 → 已经是当前月，**不该动**（与首页 canGoNext 同口径）
    await tester.drag(find.byType(MonthGrid), const Offset(-520, 0));
    await tester.pumpAndSettle();
    expect(find.text(header), findsOneWidget, reason: '不能翻到未来月');

    // 右滑 = 上一个月 → 正常
    await tester.drag(find.byType(MonthGrid), const Offset(520, 0));
    await tester.pumpAndSettle();
    expect(find.text('${prev.year}年${prev.month}月'), findsOneWidget);

    // 从历史月左滑回来
    await tester.drag(find.byType(MonthGrid), const Offset(-520, 0));
    await tester.pumpAndSettle();
    expect(find.text(header), findsOneWidget);
  });

  testWidgets('滑不够阈值不翻月；竖向滑动仍然滚动页面（不吃竖向手势）', (
    WidgetTester tester,
  ) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    await BookRepository(db).ensureDefaultBook();

    await pumpApp(tester, database: db);
    await tester.tap(find.text('日历'));
    await tester.pumpAndSettle();

    final DateTime now = DateTime.now();
    final String header = '${now.year}年${now.month}月';

    // 只滑 10dp（远小于半屏）→ 不动
    await tester.drag(find.byType(MonthGrid), const Offset(-10, 0));
    await tester.pumpAndSettle();
    expect(find.text(header), findsOneWidget);

    // 竖向拖动 = 外层 SingleChildScrollView 滚动（网格上移），且月份不变
    final double before = tester.getTopLeft(find.byType(MonthGrid)).dy;
    await tester.drag(find.byType(MonthGrid), const Offset(0, -120));
    await tester.pumpAndSettle();
    final double after = tester.getTopLeft(find.byType(MonthGrid)).dy;
    expect(after, lessThan(before), reason: '竖向滑动必须仍能滚动页面');
    expect(find.text(header), findsOneWidget);
  });

  // 用户报：「滑动切换页面没有过渡动画，很生硬」。
  // 两件事一起兜住：① 翻月时**不能闪转圈**（controller 不再切 loading）；
  // ② 要有过渡 —— 落定动画期间新旧两页同时在场，落定后只剩新的。
  testWidgets('翻月有过渡动画：动画中新旧两页同时在场，且全程不闪转圈', (
    WidgetTester tester,
  ) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    await BookRepository(db).ensureDefaultBook();

    await pumpApp(tester, database: db);
    await tester.tap(find.text('日历'));
    await tester.pumpAndSettle();

    final DateTime now = DateTime.now();
    // 只能往历史月翻（未来月被 R2 挡住）
    final DateTime prev = DateTime(now.year, now.month - 1);

    await tester.drag(find.byType(MonthGrid), const Offset(520, 0));
    await tester.pump(); // 松手 → 落定动画开始
    await tester.pump(const Duration(milliseconds: 80)); // 动画进行中

    // 过渡中：新旧两页共存（瞬切的话只会有 1 个），且在屏幕上错开
    expect(find.byType(MonthGrid), findsNWidgets(2), reason: '翻月要有过渡，不能瞬切');
    final double leftA = tester.getTopLeft(find.byType(MonthGrid).at(0)).dx;
    final double leftB = tester.getTopLeft(find.byType(MonthGrid).at(1)).dx;
    expect((leftA - leftB).abs(), greaterThan(40), reason: '两页要真的有位移，不是原地换');
    // 翻月不闪整页转圈
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await tester.pumpAndSettle();
    expect(find.byType(MonthGrid), findsOneWidget);
    expect(find.text('${prev.year}年${prev.month}月'), findsOneWidget);
  });

  // 用户要求：「我要的是那种甚至能翻一半的」——页面必须**跟手**：
  // 手指按住不放，就停在半页；松手没过半屏才弹回。
  testWidgets('跟手翻页：拖到一半停住不自动跑完，松手不够半屏弹回', (
    WidgetTester tester,
  ) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    await BookRepository(db).ensureDefaultBook();

    await pumpApp(tester, database: db);
    await tester.tap(find.text('日历'));
    await tester.pumpAndSettle();

    final DateTime now = DateTime.now();
    final String header = '${now.year}年${now.month}月';

    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byType(MonthGrid)),
    );
    // 往右拖 = 翻上一月（当前月是「最新月」，不能往左拖）。
    // 先过 slop 再拖：真机是连续事件，测试里必须分两步才拿得到 update。
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(350, 0));
    await tester.pump();

    // 拖到一半：两页同时在场，当前页已经跟着手指走掉了一大截
    expect(find.byType(MonthGrid), findsNWidgets(2));
    final double left = tester.getTopLeft(find.byType(MonthGrid).first).dx;
    expect(left, greaterThan(200), reason: '页面要跟手走，不是等松手才动');

    // 按住不动 400ms：页面必须停在原地，不能自己跑完
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      tester.getTopLeft(find.byType(MonthGrid).first).dx,
      closeTo(left, 0.5),
      reason: '手指还按着，翻页就该停在半路',
    );

    // 松手：没过半屏 → 弹回，月份不变
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byType(MonthGrid), findsOneWidget);
    expect(find.text(header), findsOneWidget);
  });

  // 位移不够半屏、但甩得够快 → 也翻过去（真机上的常见操作）。
  testWidgets('快速甩动：位移不到半屏也能翻页', (WidgetTester tester) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    await BookRepository(db).ensureDefaultBook();

    await pumpApp(tester, database: db);
    await tester.tap(find.text('日历'));
    await tester.pumpAndSettle();

    final DateTime now = DateTime.now();
    final DateTime prev = DateTime(now.year, now.month - 1);

    await tester.fling(find.byType(MonthGrid), const Offset(160, 0), 1200);
    await tester.pumpAndSettle();
    expect(find.text('${prev.year}年${prev.month}月'), findsOneWidget);
  });

  // 2026-10-29 用户要求：打开页面不能「整页加载完才显示」——网格先出，账单随后。
  testWidgets('打开日历：首帧就有网格与月汇总条，不等账单查询（R1）', (
    WidgetTester tester,
  ) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final int day = otherDay();
    await seedMonthTx(db, day: day);

    await pumpApp(tester, database: db);
    await tester.tap(find.text('日历'));
    await tester.pump(); // 只推一帧：此时数据查询还没落地

    expect(
      find.byType(MonthGrid),
      findsOneWidget,
      reason: '网格不依赖任何数据，必须首帧就渲染',
    );
    expect(find.text('月结余'), findsOneWidget);
    expect(find.text('日均支出'), findsOneWidget);
    // 整月聚合还没回来 → 汇总用占位符，而不是空白/转圈
    expect(find.text('—'), findsNWidgets(2));

    await tester.pumpAndSettle();
    expect(find.text('—'), findsNothing, reason: '数据到了要换成真实金额');
  });

  // 2026-10-29 用户要求：翻月不改变「选中日」，下面账单跟着日期走，不跟着月份跳。
  testWidgets('翻月不动选中日：网格换月，下面仍是原来那天的账单（R3）', (
    WidgetTester tester,
  ) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    final int day = otherDay();
    await seedMonthTx(db, day: day);

    await pumpApp(tester, database: db);
    await tester.tap(find.text('日历'));
    await tester.pumpAndSettle();

    final DateTime now = DateTime.now();
    final DateTime prev = DateTime(now.year, now.month - 1);

    // 先选中这一天（这笔账单挂在这一天）
    await tester.tap(find.text('$day'));
    await tester.pumpAndSettle();
    expect(find.textContaining('${now.month}月$day日'), findsOneWidget);
    expect(find.text('午餐'), findsOneWidget);

    // 翻到上一个月：网格变了，但日期头与账单都不动
    await tester.drag(find.byType(MonthGrid), const Offset(520, 0));
    await tester.pumpAndSettle();
    expect(find.text('${prev.year}年${prev.month}月'), findsOneWidget);
    expect(
      find.textContaining('${now.month}月$day日'),
      findsOneWidget,
      reason: '翻月不能把选中日改成新月份的 1 号',
    );
    expect(find.text('午餐'), findsOneWidget, reason: '账单区域不跟着月份换');

    // 真正点了上一个月的某天 → 这时账单才跟着换
    await tester.tap(find.text('$day'));
    await tester.pumpAndSettle();
    expect(find.textContaining('${prev.month}月$day日'), findsOneWidget);
    expect(find.text('午餐'), findsNothing);
  });
}
