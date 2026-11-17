/// FR-BUDGET-10 · 分类预算口径：父级含子级、二级独立、归档仍能显示。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/features/ledger/application/budget_metrics.dart';

Category _cat(
  String id,
  String name, {
  String? parentId,
  String kind = 'expense',
  int archived = 0,
}) => Category(
  id: id,
  bookId: 'b1',
  name: name,
  kind: kind,
  parentId: parentId,
  icon: '',
  color: '',
  sortOrder: 0,
  isPreset: 0,
  isArchived: archived,
  ownerId: null,
  createdAt: 1,
  updatedAt: 1,
  deletedAt: null,
  dirty: 0,
);

void main() {
  test('一级已花含全部子级；二级只算自己', () {
    final rows = buildCategoryBudgets(
      categories: <Category>[
        _cat('food', '餐饮'),
        _cat('breakfast', '早餐', parentId: 'food'),
        _cat('lunch', '午餐', parentId: 'food'),
      ],
      budgetByCategoryId: <String, int>{'food': 100000, 'breakfast': 20000},
      spentByCategoryId: <String, int>{
        'food': 30000, // 直接记在「餐饮」上的
        'breakfast': 25000,
        'lunch': 10000,
      },
    );

    final food = rows.firstWhere((r) => r.categoryId == 'food');
    expect(food.spentCents, 65000, reason: '自身 300 + 早餐 250 + 午餐 100');
    expect(food.hasChildren, isTrue);

    final breakfast = rows.firstWhere((r) => r.categoryId == 'breakfast');
    expect(breakfast.spentCents, 25000, reason: '二级只算自己');
    expect(breakfast.name, '餐饮 · 早餐');
  });

  test('只输出设了预算的分类；收入类不算', () {
    final rows = buildCategoryBudgets(
      categories: <Category>[
        _cat('food', '餐饮'),
        _cat('salary', '工资', kind: 'income'),
      ],
      budgetByCategoryId: <String, int>{'salary': 100, 'food': 500},
      spentByCategoryId: <String, int>{},
    );
    expect(rows.map((r) => r.categoryId), <String>['food']);
  });

  test('超支边界：等于不算超支', () {
    final rows = buildCategoryBudgets(
      categories: <Category>[_cat('food', '餐饮')],
      budgetByCategoryId: <String, int>{'food': 10000},
      spentByCategoryId: <String, int>{'food': 10000},
    );
    expect(rows.single.over, isFalse);
    expect(rows.single.overCents, 0);
    expect(rows.single.ratio, 1);
  });

  test('归档分类的预算仍能算出来（历史月要显示）', () {
    final rows = buildCategoryBudgets(
      categories: <Category>[_cat('old', '旧分类', archived: 1)],
      budgetByCategoryId: <String, int>{'old': 5000},
      spentByCategoryId: <String, int>{'old': 6000},
    );
    expect(rows.single.name, '旧分类');
    expect(rows.single.over, isTrue);
    expect(rows.single.overCents, 1000);
  });

  test('没设分类预算 → 空列表', () {
    expect(
      buildCategoryBudgets(
        categories: <Category>[_cat('food', '餐饮')],
        budgetByCategoryId: <String, int>{},
        spentByCategoryId: <String, int>{'food': 1},
      ),
      isEmpty,
    );
  });
}
