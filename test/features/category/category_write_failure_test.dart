/// Batch B / B2：分类删除的业务异常与非预期存储异常。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/app.dart';
import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/data/providers/database.dart';
import 'package:yanxin/data/repositories/app_meta_repository.dart';
import 'package:yanxin/data/repositories/book_repository.dart';
import 'package:yanxin/data/repositories/category_repository.dart';
import 'package:yanxin/features/onboarding/application/onboarding_keys.dart';

import '../../helpers/test_database.dart';

class _FailingCategoryRepo extends CategoryRepository {
  _FailingCategoryRepo(super.db, {this.businessMessage});

  final String? businessMessage;

  @override
  Future<void> deleteIfUnused(String id) async {
    final String? message = businessMessage;
    if (message != null) throw CategoryException(message);
    throw StateError('database is locked');
  }
}

Future<void> _pumpManage(
  WidgetTester tester,
  AppDatabase db,
  CategoryRepository repo,
) async {
  // 页面右下角有浮动「添加分类」菜单；默认 800×600 会盖住列表末行的
  // 「更多」按钮。用更高的视口验证页面级失败反馈，不改变生产布局。
  tester.view.physicalSize = const Size(800, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

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

Future<void> _openDelete(WidgetTester tester) async {
  // 自定义分类在列表末尾，先滚到可见，再点它所在行的「更多」，避免点到预置分类。
  await tester.scrollUntilVisible(
    find.text('宠物'),
    200,
    scrollable: find.byType(Scrollable).first,
  );
  final Finder tile = find
      .ancestor(of: find.text('宠物'), matching: find.byType(InkWell))
      .last;
  await tester.tap(
    find.descendant(of: tile, matching: find.byIcon(Icons.more_horiz_rounded)),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('删除'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('非业务异常：显示通用失败文案、不出现 Undo、分类仍在', (
    WidgetTester tester,
  ) async {
    final AppDatabase db = openTestDatabase();
    addTearDown(db.close);
    final Book book = await BookRepository(db).ensureDefaultBook();
    await CategoryRepository(db).create(
      bookId: book.id,
      name: '宠物',
      kind: 'expense',
    );

    await _pumpManage(tester, db, _FailingCategoryRepo(db));
    await _openDelete(tester);

    expect(find.text('删除分类失败，请稍后重试'), findsOneWidget);
    expect(find.textContaining('已删除「'), findsNothing);
    expect(find.text('宠物'), findsOneWidget);
  });

  testWidgets('业务异常：保留 CategoryException 的用户文案，不出现 Undo', (
    WidgetTester tester,
  ) async {
    final AppDatabase db = openTestDatabase();
    addTearDown(db.close);
    final Book book = await BookRepository(db).ensureDefaultBook();
    await CategoryRepository(db).create(
      bookId: book.id,
      name: '宠物',
      kind: 'expense',
    );
    const String message = '这个分类下有 2 笔账单，不能直接删除，可以归档或先把账单迁走';

    await _pumpManage(
      tester,
      db,
      _FailingCategoryRepo(db, businessMessage: message),
    );
    await _openDelete(tester);

    expect(find.text(message), findsOneWidget);
    expect(find.textContaining('已删除「'), findsNothing);
    expect(find.text('宠物'), findsOneWidget);
  });
}
