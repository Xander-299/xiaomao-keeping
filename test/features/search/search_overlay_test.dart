/// 搜索浮层 widget 测试：入口（覆盖首页）、三类命中、类型筛选 chips、
/// 结果汇总、一键清空、无结果、关闭、删除链路。
///
/// ⚠️ 断言必须限定在**浮层内**（[_inOverlay]）：浮层是透明度 false 的 dialog，
/// 首页留在下面仍参与 widget 树 —— 首页本月账单里也有 `-88.88` 这类文本，
/// 直接 `find.text` 会同时命中两份（原独立路由是 opaque，首页被 Offstage 屏蔽才没这问题）。
library;

import 'package:flutter/material.dart';
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
import 'package:yanxin/features/ledger/presentation/home_page.dart';
import 'package:yanxin/features/onboarding/application/onboarding_keys.dart';
import 'package:yanxin/features/search/application/search_history.dart';
import 'package:yanxin/features/search/presentation/search_overlay.dart';

import '../../helpers/category_seed.dart';
import '../../helpers/pump_app.dart';

const Key _inputKey = ValueKey<String>('search-input');
const Key _clearKey = ValueKey<String>('search-clear');
const Key _closeKey = ValueKey<String>('search-close');

Key _chipKey(String word) => ValueKey<String>('search-chip-$word');

/// 只在浮层子树里找文本，避开首页那份同名文本。
Finder _inOverlay(Finder matching) =>
    find.descendant(of: find.byType(SearchOverlay), matching: matching);

/// 造三笔跨月数据：
/// - 餐饮 88.88 / 备注「午餐」（当月 5 日，支出）
/// - 交通 12.00 / 备注「打车」（上月 20 日，支出）
/// - 餐饮补贴 200.00 / 备注「工资」（当月 8 日，收入）
///
/// 收入那笔特意用「餐饮补贴」：搜「餐饮」能一次命中支出 + 收入两笔，
/// 顺便验证「分类名命中」的并集与汇总行的收支合计。
/// 支出 2 笔 / 收入 1 笔也正好用来验证「仅支出 / 仅收入」的类型筛选。
Future<void> _seed(AppDatabase db) async {
  final book = await BookRepository(db).ensureDefaultBook();
  final catRepo = CategoryRepository(db);
  final food = await ensureCategory(catRepo, book.id, '餐饮');
  final traffic = await ensureCategory(catRepo, book.id, '交通');
  final salary = await ensureCategory(catRepo, book.id, '餐饮补贴', kind: 'income');
  final accountId = (await AccountRepository(db).listByBook(book.id)).first.id;
  final repo = TransactionRepository(db);
  final now = DateTime.now();

  await repo.create(
    bookId: book.id,
    accountId: accountId,
    categoryId: food.id,
    type: 'expense',
    amountCents: 8888,
    occurredAt: DateTime(now.year, now.month, 5, 12).millisecondsSinceEpoch,
    note: '午餐',
  );
  await repo.create(
    bookId: book.id,
    accountId: accountId,
    categoryId: traffic.id,
    type: 'expense',
    amountCents: 1200,
    occurredAt: DateTime(now.year, now.month - 1, 20, 9).millisecondsSinceEpoch,
    note: '打车',
  );
  await repo.create(
    bookId: book.id,
    accountId: accountId,
    categoryId: salary.id,
    type: 'income',
    amountCents: 20000,
    occurredAt: DateTime(now.year, now.month, 8, 9).millisecondsSinceEpoch,
    note: '工资',
  );
}

/// 从首页搜索图标打开搜索浮层（F7.5 起是 dialog，不再是路由跳转）。
Future<void> _openSearch(WidgetTester tester, AppDatabase db) async {
  await pumpApp(tester, database: db);
  await tester.tap(find.byTooltip('搜索'));
  await tester.pumpAndSettle();
}


/// 删除必定失败（模拟数据库锁 / 磁盘异常）。
class _FailingDeleteRepo extends TransactionRepository {
  _FailingDeleteRepo(super.db);

  @override
  Future<int> softDelete(String id) async {
    throw StateError('database is locked');
  }
}

/// 用指定仓储打开 App 并进入搜索浮层（失败路径需要替换仓储）。
Future<void> _openSearchWithRepo(
  WidgetTester tester,
  AppDatabase db,
  TransactionRepository repo,
) async {
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
  await tester.tap(find.byTooltip('搜索'));
  await tester.pumpAndSettle();
}

Future<void> _type(WidgetTester tester, String keyword) async {
  await tester.enterText(find.byKey(_inputKey), keyword);
  await tester.pumpAndSettle();
}

/// 等异步写库 + provider 重建到位（写库是真实异步，`pumpAndSettle` 可能抢先返回）。
Future<void> _pumpDb(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('首页搜索图标 → 覆盖式浮层：输入框 + 引导态（不列全部流水）', (
    WidgetTester tester,
  ) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    await _seed(db);

    await _openSearch(tester, db);

    expect(find.byKey(_inputKey), findsOneWidget);
    expect(_inOverlay(find.text('输入分类、账户、备注或金额开始搜索')), findsOneWidget);
    // 未输入时浮层里不出现任何流水、也不显示清空按钮
    expect(_inOverlay(find.text('-88.88')), findsNothing);
    expect(find.byKey(_clearKey), findsNothing);
  });

  testWidgets('浮层覆盖而非跳页：首页仍在树里（毛玻璃下方可辨）', (
    WidgetTester tester,
  ) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    await _seed(db);

    await _openSearch(tester, db);

    // DialogRoute 不透明度为 false → 下层路由不会被 Offstage，首页仍在
    expect(find.byType(HomePage), findsOneWidget);
    // 同时浮层也在
    expect(find.byKey(_inputKey), findsOneWidget);
  });

  testWidgets('提示块含三个类型筛选 chips', (WidgetTester tester) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    await _seed(db);

    await _openSearch(tester, db);

    expect(find.byKey(_chipKey('仅支出')), findsOneWidget);
    expect(find.byKey(_chipKey('仅收入')), findsOneWidget);
    expect(find.byKey(_chipKey('转账')), findsOneWidget);
  });

  testWidgets('按分类名搜：命中同分类多笔，汇总笔数与收支', (
    WidgetTester tester,
  ) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    await _seed(db);

    await _openSearch(tester, db);
    await _type(tester, '餐饮');

    expect(_inOverlay(find.text('共 2 笔')), findsOneWidget);
    expect(_inOverlay(find.text('-88.88')), findsOneWidget);
    expect(_inOverlay(find.text('+200.00')), findsOneWidget);
    // 交通那笔被排除
    expect(_inOverlay(find.text('-12.00')), findsNothing);
  });

  testWidgets('按备注搜：跨月的历史流水也能搜到', (WidgetTester tester) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    await _seed(db);

    await _openSearch(tester, db);
    await _type(tester, '打车');

    expect(_inOverlay(find.text('共 1 笔')), findsOneWidget);
    expect(_inOverlay(find.text('-12.00')), findsOneWidget);
  });

  testWidgets('按金额搜：数字走「元.分」文本子串匹配', (WidgetTester tester) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    await _seed(db);

    await _openSearch(tester, db);

    await _type(tester, '88');
    expect(_inOverlay(find.text('-88.88')), findsOneWidget);
    expect(_inOverlay(find.text('共 1 笔')), findsOneWidget);

    await _type(tester, '12');
    expect(_inOverlay(find.text('-12.00')), findsOneWidget);
    expect(_inOverlay(find.text('-88.88')), findsNothing);

    // 带千分位/金额符号也能搜
    await _type(tester, '¥200');
    expect(_inOverlay(find.text('+200.00')), findsOneWidget);
  });

  testWidgets('点「仅支出」：词填进输入框、chip 高亮，结果是全部支出', (
    WidgetTester tester,
  ) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    await _seed(db);

    await _openSearch(tester, db);
    await tester.tap(find.byKey(_chipKey('仅支出')));
    await tester.pumpAndSettle();

    // 词真的进了输入框（可见、可编辑、可一键清空）；
    // 末尾带一个空格 —— 用户接着敲关键词才会被空格分隔开，保持类型指令有效
    final TextField field = tester.widget<TextField>(find.byKey(_inputKey));
    expect(field.controller?.text, '仅支出 ');
    // chip 高亮由输入框内容推导（F7.6 P3 起用卡通 ToonChip，不再是 ChoiceChip）
    expect(
      tester.widget<ToonChip>(find.byKey(_chipKey('仅支出'))).selected,
      isTrue,
    );

    // 2 笔支出都在，收入那笔被排除
    expect(_inOverlay(find.text('共 2 笔')), findsOneWidget);
    expect(_inOverlay(find.text('-88.88')), findsOneWidget);
    expect(_inOverlay(find.text('-12.00')), findsOneWidget);
    expect(_inOverlay(find.text('+200.00')), findsNothing);
  });

  testWidgets('点「仅收入」：结果只剩收入；「转账」无数据 → 无结果态', (
    WidgetTester tester,
  ) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    await _seed(db);

    await _openSearch(tester, db);

    await tester.tap(find.byKey(_chipKey('仅收入')));
    await tester.pumpAndSettle();
    expect(_inOverlay(find.text('共 1 笔')), findsOneWidget);
    expect(_inOverlay(find.text('+200.00')), findsOneWidget);
    expect(_inOverlay(find.text('-88.88')), findsNothing);

    // 切到转账：App 记不了转账，现有数据为空 → 无结果态
    await tester.tap(find.byKey(_chipKey('转账')));
    await tester.pumpAndSettle();
    expect(_inOverlay(find.text('没有匹配「转账」的账单')), findsOneWidget);
  });

  testWidgets('再点同一个 chip = 取消筛选，回到引导态', (WidgetTester tester) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    await _seed(db);

    await _openSearch(tester, db);
    await tester.tap(find.byKey(_chipKey('仅支出')));
    await tester.pumpAndSettle();
    expect(_inOverlay(find.text('共 2 笔')), findsOneWidget);

    await tester.tap(find.byKey(_chipKey('仅支出')));
    await tester.pumpAndSettle();

    final TextField field = tester.widget<TextField>(find.byKey(_inputKey));
    expect(field.controller?.text, isEmpty);
    expect(_inOverlay(find.text('输入分类、账户、备注或金额开始搜索')), findsOneWidget);
  });

  testWidgets('类型筛选 + 关键词 = 交集', (WidgetTester tester) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    await _seed(db);

    await _openSearch(tester, db);
    await tester.tap(find.byKey(_chipKey('仅支出')));
    await tester.pumpAndSettle();
    await _type(tester, '仅支出 打车');

    expect(_inOverlay(find.text('共 1 笔')), findsOneWidget);
    expect(_inOverlay(find.text('-12.00')), findsOneWidget);
    expect(_inOverlay(find.text('-88.88')), findsNothing);
  });

  testWidgets('点 chip 后直接接着敲字（不额外打空格）→ 交集照样生效', (
    WidgetTester tester,
  ) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    await _seed(db);

    await _openSearch(tester, db);
    await tester.tap(find.byKey(_chipKey('仅支出')));
    await tester.pumpAndSettle();

    // 模拟真实操作：点完 chip 直接在后面敲「12」（chip 已留好尾随空格）
    final TextField field = tester.widget<TextField>(find.byKey(_inputKey));
    await _type(tester, '${field.controller!.text}12');

    expect(_inOverlay(find.text('共 1 笔')), findsOneWidget);
    expect(_inOverlay(find.text('-12.00')), findsOneWidget);
    expect(_inOverlay(find.text('-88.88')), findsNothing);
  });

  testWidgets('一键清空：有输入才出现，点一下清空并回到引导态', (
    WidgetTester tester,
  ) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    await _seed(db);

    await _openSearch(tester, db);
    await _type(tester, '打车');
    expect(find.byKey(_clearKey), findsOneWidget);

    await tester.tap(find.byKey(_clearKey));
    await tester.pumpAndSettle();

    final TextField field = tester.widget<TextField>(find.byKey(_inputKey));
    expect(field.controller?.text, isEmpty);
    expect(_inOverlay(find.text('输入分类、账户、备注或金额开始搜索')), findsOneWidget);
    expect(find.byKey(_clearKey), findsNothing);
    expect(_inOverlay(find.text('-12.00')), findsNothing);
  });

  testWidgets('没有命中：回显关键词 + 提供清空入口', (WidgetTester tester) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    await _seed(db);

    await _openSearch(tester, db);
    await _type(tester, '不存在的关键词');

    expect(_inOverlay(find.text('没有匹配「不存在的关键词」的账单')), findsOneWidget);

    // F7.6 P3 起清空入口是卡通胶囊按钮（不再是 TextButton）
    await tester.tap(find.widgetWithText(ToonButton, '清空输入'));
    await tester.pumpAndSettle();
    expect(_inOverlay(find.text('输入分类、账户、备注或金额开始搜索')), findsOneWidget);
  });

  testWidgets('点关闭按钮 → 浮层收起，回首页（数据无变化）', (WidgetTester tester) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    await _seed(db);

    await _openSearch(tester, db);
    await _type(tester, '餐饮');
    await tester.tap(find.byKey(_closeKey));
    await tester.pumpAndSettle();

    expect(find.byKey(_inputKey), findsNothing);
    expect(find.byType(HomePage), findsOneWidget);
  });

  testWidgets('点提示块以下的玻璃空白区 → 浮层收起', (WidgetTester tester) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    await _seed(db);

    await _openSearch(tester, db);
    // 无结果态：提示块只占顶部约 1/5 屏，下方是纯玻璃，可穿透点击
    await _type(tester, '不存在的关键词');
    expect(find.byKey(_inputKey), findsOneWidget);

    final Size size = tester.view.physicalSize / tester.view.devicePixelRatio;
    await tester.tapAt(Offset(size.width / 2, size.height * 0.75));
    await tester.pumpAndSettle();

    expect(find.byKey(_inputKey), findsNothing);
  });

  testWidgets('引导态下点提示块以外的空白区也能关闭（不能被 Scrollable 挡住）', (
    WidgetTester tester,
  ) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    await _seed(db);

    await _openSearch(tester, db);
    expect(_inOverlay(find.text('输入分类、账户、备注或金额开始搜索')), findsOneWidget);

    // 真机曾在此挂掉：引导态原本用 SingleChildScrollView，Scrollable 以 opaque
    // 命中整块下方区域 → 点空白无反应。改成 Align 后空白可穿透。
    final Size size = tester.view.physicalSize / tester.view.devicePixelRatio;
    await tester.tapAt(Offset(size.width / 2, size.height * 0.75));
    await tester.pumpAndSettle();

    expect(find.byKey(_inputKey), findsNothing);
  });

  testWidgets('左滑结果可删：删完只剩空结果提示，且库里已软删', (
    WidgetTester tester,
  ) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    await _seed(db);

    await _openSearch(tester, db);
    await _type(tester, '打车');

    // F7.8：删除入口 = 左滑（长按已移除）→ 滑出右侧动作区
    await tester.drag(_inOverlay(find.text('-12.00')), const Offset(-200, 0));
    await tester.pumpAndSettle();

    // 动作区的「删除」→ 弹二次确认框（PRD / SPEC-F7.4 要求）
    await tester.tap(_inOverlay(find.text('删除')));
    await tester.pumpAndSettle();
    expect(find.text('删除这笔'), findsOneWidget);

    await tester.tap(find.widgetWithText(ToonButton, '删除'));
    await tester.pumpAndSettle();

    expect(_inOverlay(find.text('没有匹配「打车」的账单')), findsOneWidget);
    expect(find.textContaining('已删除「'), findsOneWidget);

    final book = await BookRepository(db).ensureDefaultBook();
    final rows = await TransactionRepository(db).listByBook(book.id);
    expect(rows.map((t) => t.note), isNot(contains('打车')));
    expect(rows, hasLength(2));

    // 撤销：SnackBar 上的「撤销」→ 记录恢复回搜索结果
    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect(_inOverlay(find.text('-12.00')), findsOneWidget);
  });

  // ===== F7.7 D 批：账户名命中 / 时间区间 / 搜索历史 / 高亮 =====

  testWidgets('按账户名搜：账户名也能命中流水（D 批）', (WidgetTester tester) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    await _seed(db);

    await _openSearch(tester, db);
    // _seed 用的都是默认账本自带的「现金」账户 → 三笔全命中
    await _type(tester, '现金');

    expect(_inOverlay(find.text('共 3 笔')), findsOneWidget);
  });

  testWidgets('区间 chips：默认「全部」，点「本月」后结果条标区间且上月流水搜不到', (
    WidgetTester tester,
  ) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    await _seed(db);

    await _openSearch(tester, db);
    // 默认选中「全部」
    expect(
      tester
          .widget<ToonChip>(find.byKey(const ValueKey<String>('search-range-全部')))
          .selected,
      isTrue,
    );

    // 只选区间、不输关键词 → 直接出本月结果（不是引导态）
    await tester.tap(find.byKey(const ValueKey<String>('search-range-本月')));
    await tester.pumpAndSettle();
    expect(_inOverlay(find.text('共 2 笔')), findsOneWidget);
    expect(_inOverlay(find.text('· 本月')), findsOneWidget);
    expect(_inOverlay(find.text('输入分类、账户、备注或金额开始搜索')), findsNothing);

    // 「打车」发生在上月 → 本月区间内搜不到，空态点明「只搜本月」
    await _type(tester, '打车');
    expect(_inOverlay(find.text('没有匹配「打车」的账单')), findsOneWidget);
    expect(_inOverlay(find.textContaining('只搜「本月」')), findsOneWidget);

    // 换回「全部」→ 又能搜到
    await tester.tap(find.byKey(const ValueKey<String>('search-range-全部')));
    await tester.pumpAndSettle();
    expect(_inOverlay(find.text('共 1 笔')), findsOneWidget);
    expect(_inOverlay(find.text('-12.00')), findsOneWidget);
  });

  testWidgets('近 3 月：三条数据都在窗口内（含上月）', (WidgetTester tester) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    await _seed(db);

    await _openSearch(tester, db);
    await tester.tap(find.byKey(const ValueKey<String>('search-range-近3月')));
    await tester.pumpAndSettle();

    expect(_inOverlay(find.text('共 3 笔')), findsOneWidget);
    expect(_inOverlay(find.text('-12.00')), findsOneWidget);
  });

  testWidgets('命中高亮：金额里的 88 被标底色，分类名命中同样高亮（D 批）', (
    WidgetTester tester,
  ) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    await _seed(db);

    await _openSearch(tester, db);
    await _type(tester, '88');

    // 结果行金额改成 Text.rich 后，find.text 仍按 toPlainText 匹配 → 断言串不变
    expect(_inOverlay(find.text('-88.88')), findsOneWidget);
    // 至少有一段带底色的 span（= 命中子串确实被高亮了）
    final Iterable<RichText> rich = tester.widgetList<RichText>(
      _inOverlay(find.byType(RichText)),
    );
    expect(
      rich.any((RichText t) => _highlightCount(t.text) > 0),
      isTrue,
      reason: '关键词 88 的命中子串应当有高亮底色的 span',
    );
  });

  testWidgets('搜索历史：回车记入 → chip 出现 → 点它能搜 → 可一键清空（D 批）', (
    WidgetTester tester,
  ) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    await _seed(db);

    await _openSearch(tester, db);
    await _type(tester, '餐饮');
    // 回车 / 键盘「搜索」键 = 提交，记进历史（写库异步 → 等一拍）
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await _pumpDb(tester);

    // 清空输入回到引导态 → 历史 chip 出现
    await tester.tap(find.byKey(_clearKey));
    await _pumpDb(tester);
    expect(_inOverlay(find.text('最近搜过')), findsOneWidget);
    final Finder historyChip = find.byKey(
      const ValueKey<String>('search-history-餐饮'),
    );
    expect(historyChip, findsOneWidget);

    // 点历史 chip → 关键词回到输入框并出结果
    await tester.tap(historyChip);
    await tester.pumpAndSettle();
    expect(_inOverlay(find.text('共 2 笔')), findsOneWidget);

    // 清空输入 + 清空历史 → 历史块消失，KV 行也删掉
    await tester.tap(find.byKey(_clearKey));
    await _pumpDb(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('search-history-clear')),
    );
    await _pumpDb(tester);
    expect(_inOverlay(find.text('最近搜过')), findsNothing);
    expect(historyChip, findsNothing);
    expect(await AppMetaRepository(db).get(kSearchHistoryKey), isNull);
  });
  testWidgets('确认框点「取消」：不软删、不提示，记录仍在结果里', (
    WidgetTester tester,
  ) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    await _seed(db);

    await _openSearch(tester, db);
    await _type(tester, '打车');

    await tester.drag(_inOverlay(find.text('-12.00')), const Offset(-200, 0));
    await tester.pumpAndSettle();
    await tester.tap(_inOverlay(find.text('删除')));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ToonButton, '取消'));
    await tester.pumpAndSettle();

    expect(find.text('删除这笔'), findsNothing);
    expect(find.textContaining('已删除「'), findsNothing);
    expect(_inOverlay(find.text('-12.00')), findsOneWidget);

    final book = await BookRepository(db).ensureDefaultBook();
    final rows = await TransactionRepository(db).listByBook(book.id);
    expect(rows.map((t) => t.note), contains('打车'));
    expect(rows, hasLength(3));
  });

  testWidgets('删除遇到数据库异常：显示失败、无 Undo、记录仍在', (
    WidgetTester tester,
  ) async {
    final db = openTestDatabase();
    addTearDown(db.close);
    await _seed(db);

    await _openSearchWithRepo(tester, db, _FailingDeleteRepo(db));
    await _type(tester, '打车');

    await tester.drag(_inOverlay(find.text('-12.00')), const Offset(-200, 0));
    await tester.pumpAndSettle();
    await tester.tap(_inOverlay(find.text('删除')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ToonButton, '删除'));
    await _pumpDb(tester);

    expect(find.text('删除失败，请稍后重试'), findsOneWidget);
    expect(find.textContaining('已删除「'), findsNothing);
    expect(_inOverlay(find.text('-12.00')), findsOneWidget);

    final book = await BookRepository(db).ensureDefaultBook();
    final rows = await TransactionRepository(db).listByBook(book.id);
    expect(rows.map((t) => t.note), contains('打车'));
    expect(rows, hasLength(3));
  });
}

/// 数一数 `TextSpan` 树里带高亮底色的段数（>0 即「确实高亮了」）。
int _highlightCount(InlineSpan span) {
  var count = 0;
  span.visitChildren((InlineSpan child) {
    final TextStyle? style = child.style;
    if (style?.backgroundColor != null) count++;
    return true;
  });
  return count;

}
