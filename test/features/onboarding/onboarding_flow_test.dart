/// 新手引导的**流程**测试（F7.14）：首启弹 / 翻页 / 跳过 / 完成 / 老用户不弹 / 我的入口。
///
/// ⚠️ 含 `testWidgets` → **本机跑不了**（Dart 起不了管道子进程），需用户终端全量 `flutter test`。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/data/repositories/app_meta_repository.dart';
import 'package:yanxin/data/repositories/book_repository.dart';
import 'package:yanxin/features/onboarding/application/onboarding_keys.dart';

import '../../helpers/pump_app.dart';

/// 等某个 finder 出现（写库 / 路由跳转都是真实异步，`pumpAndSettle` 会早退）。
Future<void> pumpUntil(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
  }
  await tester.pumpAndSettle();
}

/// 等到「看过」标记落库（标记写在引导页 `dispose()` 里，pop 动画完才触发）。
Future<String?> readMarker(WidgetTester tester, AppDatabase db) async {
  for (var i = 0; i < 20; i++) {
    final String? value = await AppMetaRepository(db).get(kOnboardingDoneKey);
    if (value != null) return value;
    await tester.pump(const Duration(milliseconds: 50));
  }
  return null;
}

/// 首启场景：等引导首页稳定出现。
Future<void> openFirstRun(WidgetTester tester, AppDatabase db) async {
  await pumpApp(tester, database: db, onboardingDone: false);
  await pumpUntil(tester, find.text('认识一下小耄记账'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('全新安装首启：自动弹出引导（只有当前页在树上）', (WidgetTester tester) async {
    final AppDatabase db = openTestDatabase();
    await openFirstRun(tester, db);

    expect(find.text('认识一下小耄记账'), findsOneWidget);
    expect(find.text('下一步'), findsOneWidget);
    expect(find.text('跳过'), findsOneWidget);
    // PageView 只建当前页 → 末页文案不该在树上
    expect(find.text('可以开始记账了'), findsNothing);
  });

  testWidgets('点「下一步」→ 翻到第 2 页，首页被换掉', (WidgetTester tester) async {
    final AppDatabase db = openTestDatabase();
    await openFirstRun(tester, db);

    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();

    expect(find.text('中间歪着的方块 = 记一笔'), findsOneWidget);
    expect(find.text('认识一下小耄记账'), findsNothing);
  });

  testWidgets('连点到末页 → 按钮变「开始记账」→ 点它回首页并写标记', (WidgetTester tester) async {
    final AppDatabase db = openTestDatabase();
    await openFirstRun(tester, db);

    for (int i = 0; i < 6; i++) {
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
    }
    expect(find.text('可以开始记账了'), findsOneWidget);
    expect(find.text('开始记账'), findsOneWidget);

    await tester.tap(find.text('开始记账'));
    await tester.pumpAndSettle();

    await pumpUntil(tester, find.text('默认账本'));
    expect(find.text('默认账本'), findsOneWidget); // 回到首页
    expect(await readMarker(tester, db), isNotNull); // 标记已落库
  });

  testWidgets('点「跳过」→ 直接回首页并写标记', (WidgetTester tester) async {
    final AppDatabase db = openTestDatabase();
    await openFirstRun(tester, db);

    await tester.tap(find.text('跳过'));
    await tester.pumpAndSettle();

    await pumpUntil(tester, find.text('默认账本'));
    expect(find.text('默认账本'), findsOneWidget);
    expect(await readMarker(tester, db), isNotNull);
  });

  testWidgets('已看过（有标记）→ 冷启动不弹，直接进首页', (WidgetTester tester) async {
    // 默认 onboardingDone = true → 预写标记
    await pumpApp(tester);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    expect(find.text('认识一下小耄记账'), findsNothing);
    expect(find.text('默认账本'), findsOneWidget);
  });

  testWidgets('老用户（已有主账本、无标记）→ 不弹，且不被写上标记', (WidgetTester tester) async {
    final AppDatabase db = openTestDatabase();
    final BookRepository books = BookRepository(db);
    final String bookId = (await books.ensureDefaultBook()).id;
    await books.setActiveBookIdFor(null, bookId); // 老用户：active_book_id 有值

    await pumpApp(tester, database: db, onboardingDone: false);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    expect(find.text('认识一下小耄记账'), findsNothing);
    expect(find.text('默认账本'), findsOneWidget);
    // 老用户不算「看过」—— 不写标记，便于将来排查
    expect(await AppMetaRepository(db).get(kOnboardingDoneKey), isNull);
  });

  testWidgets('我的 → 新手引导：可随时重看，返回后标记仍在', (WidgetTester tester) async {
    final AppDatabase db = openTestDatabase();
    await pumpApp(tester, database: db);

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    expect(find.text('新手引导'), findsOneWidget);

    await tester.tap(find.text('新手引导'));
    await tester.pumpAndSettle();
    expect(find.text('认识一下小耄记账'), findsOneWidget);

    await tester.tap(find.text('跳过'));
    await tester.pumpAndSettle();

    await pumpUntil(tester, find.text('新手引导'));
    expect(find.text('新手引导'), findsOneWidget); // 回到「我的」页
    expect(await readMarker(tester, db), isNotNull);
  });
}
