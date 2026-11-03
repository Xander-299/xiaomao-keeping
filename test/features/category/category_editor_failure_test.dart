/// Batch C / C2：分类编辑器保存失败的用户反馈。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/app.dart';
import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/core/theme/toon.dart';
import 'package:yanxin/data/providers/database.dart';
import 'package:yanxin/data/repositories/app_meta_repository.dart';
import 'package:yanxin/data/repositories/book_repository.dart';
import 'package:yanxin/data/repositories/category_repository.dart';
import 'package:yanxin/features/onboarding/application/onboarding_keys.dart';

import '../../helpers/test_database.dart';

class _FailingCategoryRepo extends CategoryRepository {
  _FailingCategoryRepo(super.db);

  bool fail = true;
  bool business = false;

  @override
  Future<Category> create({
    required String bookId,
    required String name,
    required String kind,
    String? parentId,
    String icon = '',
    String color = '',
    int sortOrder = -1,
    bool isPreset = false,
    String? ownerId,
    String? id,
  }) async {
    if (!fail) {
      return super.create(
        bookId: bookId,
        name: name,
        kind: kind,
        parentId: parentId,
        icon: icon,
        color: color,
        sortOrder: sortOrder,
        isPreset: isPreset,
        ownerId: ownerId,
        id: id,
      );
    }
    if (business) {
      throw const CategoryException('已经有叫「宠物」的分类了');
    }
    throw StateError('disk I/O error');
  }
}

Future<void> _pumpApp(
  WidgetTester tester,
  AppDatabase db,
  CategoryRepository repo,
) async {
  await AppMetaRepository(db).set(kOnboardingDoneKey, kOnboardingDoneValue);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        categoryRepositoryProvider.overrideWithValue(repo),
      ],
      child: const YanxinApp(),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('我的'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('分类管理'));
  await tester.pumpAndSettle();
}

Future<void> _openNewEditor(WidgetTester tester) async {
  await tester.tap(find.byTooltip('添加分类'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('添加一级分类'));
  await tester.pumpAndSettle();
}

Future<void> _tapSave(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(ToonButton, '保存'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('非预期异常：统一文案、不暴露 \$e、输入保留且按钮恢复', (
    WidgetTester tester,
  ) async {
    final AppDatabase db = openTestDatabase();
    addTearDown(db.close);
    await BookRepository(db).ensureDefaultBook();
    final _FailingCategoryRepo repo = _FailingCategoryRepo(db);

    await _pumpApp(tester, db, repo);
    await _openNewEditor(tester);
    await tester.enterText(find.byType(TextField).first, '宠物');

    await _tapSave(tester);

    expect(find.text('保存分类失败，请稍后重试'), findsOneWidget);
    expect(find.textContaining('StateError'), findsNothing);
    expect(find.textContaining('保存失败：'), findsNothing);
    // 输入没丢
    expect(find.text('宠物'), findsOneWidget);
    // _saving 已恢复，按钮可再点
    final ToonButton save = tester.widget<ToonButton>(
      find.widgetWithText(ToonButton, '保存'),
    );
    expect(save.onPressed, isNotNull);

    // 允许继续编辑并重试成功
    repo.fail = false;
    await tester.enterText(find.byType(TextField).first, '宠物用品');
    await _tapSave(tester);
    await tester.pumpAndSettle();
    expect(find.text('分类名称'), findsNothing);
    final Book book = (await BookRepository(db).listAll()).single;
    final List<Category> cats = await CategoryRepository(
      db,
    ).listByBook(book.id, kind: 'expense');
    expect(cats.any((Category c) => c.name == '宠物用品'), isTrue);
  });

  testWidgets('CategoryException：保留业务语义，不显示通用文案', (
    WidgetTester tester,
  ) async {
    final AppDatabase db = openTestDatabase();
    addTearDown(db.close);
    await BookRepository(db).ensureDefaultBook();
    final _FailingCategoryRepo repo = _FailingCategoryRepo(db)..business = true;

    await _pumpApp(tester, db, repo);
    await _openNewEditor(tester);
    await tester.enterText(find.byType(TextField).first, '宠物');

    await _tapSave(tester);

    expect(find.text('已经有叫「宠物」的分类了'), findsOneWidget);
    expect(find.text('保存分类失败，请稍后重试'), findsNothing);
    expect(find.text('分类名称'), findsOneWidget);
  });
}
