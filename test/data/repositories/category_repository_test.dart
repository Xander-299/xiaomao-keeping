/// 分类仓储（schema v4）：预置补齐、两级、校验、排序、归档、迁移。
///
/// 对应任务书 §7「测试要求」里能在仓储层覆盖的部分；UI 层的选择器/编辑器另有 widget 测试。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/core/constants/preset.dart';
import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/data/repositories/account_repository.dart';
import 'package:yanxin/data/repositories/book_repository.dart';
import 'package:yanxin/data/repositories/category_repository.dart';
import 'package:yanxin/data/repositories/transaction_repository.dart';

import '../../helpers/test_database.dart';

void main() {
  late AppDatabase db;
  late CategoryRepository repo;
  late TransactionRepository txRepo;
  late String bookId;
  late String accountId;

  setUp(() async {
    db = openTestDatabase();
    addTearDown(db.close);
    final Book book = await BookRepository(db).create(name: 'x');
    bookId = book.id;
    repo = CategoryRepository(db);
    txRepo = TransactionRepository(db);
    accountId = (await AccountRepository(db).listByBook(bookId)).first.id;
  });

  Future<Category> mk(
    String name, {
    String kind = 'expense',
    String? parentId,
    String icon = '',
    String color = '',
  }) => repo.create(
    bookId: bookId,
    name: name,
    kind: kind,
    parentId: parentId,
    icon: icon,
    color: color,
  );

  Future<TxRow> addTx(
    String categoryId, {
    int cents = 1000,
    String note = '午饭',
    int? occurredAt,
  }) => txRepo.create(
    bookId: bookId,
    accountId: accountId,
    type: 'expense',
    amountCents: cents,
    occurredAt: occurredAt ?? DateTime(2026, 10, 5, 12).millisecondsSinceEpoch,
    categoryId: categoryId,
    note: note,
  );

  group('预置分类', () {
    test('新建账本：11 个支出 + 7 个收入一级，支出带二级（含任务书点名的两条）', () async {
      final List<Category> expense = await repo.listByBook(bookId, kind: 'expense');
      final List<Category> income = await repo.listByBook(bookId, kind: 'income');
      final List<Category> roots =
          expense.where((Category c) => c.parentId == null).toList();
      final List<Category> kids =
          expense.where((Category c) => c.parentId != null).toList();

      expect(roots.length, 11);
      expect(income.length, 7, reason: '收入刻意不带二级，一级本身就是 7 条');
      expect(kids.length, presetChildCount);
      expect(expense.every((Category c) => c.icon.isNotEmpty), isTrue);
      expect(expense.every((Category c) => c.color.startsWith('#')), isTrue);
      expect(roots.map((Category c) => c.name), contains('通讯'));

      // 任务书点名的两条：餐饮 → 早餐 / 午餐 / 晚餐；交通 → 地铁 / 公交 / 共享单车
      final Category food = roots.firstWhere((Category c) => c.name == '餐饮');
      expect(
        kids.where((Category c) => c.parentId == food.id).map((Category c) => c.name),
        containsAll(<String>['早餐', '午餐', '晚餐']),
      );
      final Category transport =
          roots.firstWhere((Category c) => c.name == '交通');
      expect(
        kids
            .where((Category c) => c.parentId == transport.id)
            .map((Category c) => c.name),
        containsAll(<String>['地铁', '公交', '共享单车']),
      );

      // 二级也是预置，且颜色跟随父级（视觉上归组）
      expect(kids.every((Category c) => c.isPreset == 1), isTrue);
      expect(
        kids
            .where((Category c) => c.parentId == food.id)
            .every((Category c) => c.color == food.color),
        isTrue,
      );
    });

    test('老账本（只有一级）：补装只加二级，已删的二级不会被复活', () async {
      final Category food = (await repo.listByBook(bookId, kind: 'expense'))
          .firstWhere((Category c) => c.parentId == null && c.name == '餐饮');
      // 模拟「上一版只有一级」：把餐饮的二级物理删掉
      await db.customStatement(
        'DELETE FROM categories WHERE parent_id = ?',
        <Object?>[food.id],
      );
      expect(await repo.childrenOf(food.id), isEmpty);

      await repo.ensurePresets(bookId);
      final List<Category> kids = await repo.childrenOf(food.id);
      expect(
        kids.map((Category c) => c.name),
        containsAll(<String>['早餐', '午餐', '晚餐', '饮料', '零食']),
      );
      expect(
        (await repo.listByBook(bookId, kind: 'expense'))
            .where((Category c) => c.parentId == null && c.name == '餐饮')
            .length,
        1,
        reason: '补二级不能顺手把一级再插一遍',
      );

      // 用户删掉「零食」→ 再补装也不该回来
      final Category snack =
          kids.firstWhere((Category c) => c.name == '零食');
      await repo.deleteIfUnused(snack.id);
      await repo.ensurePresets(bookId);
      expect(
        (await repo.childrenOf(food.id)).where((Category c) => c.name == '零食'),
        isEmpty,
      );
    });

    test('一级被用户删掉后，不再给它的二级补装（整棵树都不复活）', () async {
      final Category food = (await repo.listByBook(bookId, kind: 'expense'))
          .firstWhere((Category c) => c.parentId == null && c.name == '餐饮');
      for (final Category kid in await repo.childrenOf(food.id)) {
        await repo.deleteIfUnused(kid.id);
      }
      await repo.deleteIfUnused(food.id);

      await repo.ensurePresets(bookId);

      expect(await repo.childrenOf(food.id), isEmpty);
      expect(
        (await repo.listByBook(bookId, kind: 'expense'))
            .where((Category c) => c.name == '餐饮'),
        isEmpty,
        reason: '软删的一级既不能自己复活，也不能被塞回子分类',
      );
    });

    test('ensurePresets 幂等：重复调用不会多出分类', () async {
      final int before = (await repo.listByBook(bookId)).length;
      await repo.ensurePresets(bookId);
      await repo.ensurePresets(bookId);
      expect((await repo.listByBook(bookId)).length, before);
    });

    test('用户删掉的预置分类不会被补装复活（真机实测踩到的坑）', () async {
      final Category comm = (await repo.listByBook(bookId, kind: 'expense'))
          .firstWhere((Category c) => c.name == '通讯');
      // 通讯现在带二级（话费 / 宽带）：按「有子分类不能直接删」的规则，先删子分类
      for (final Category kid in await repo.childrenOf(comm.id)) {
        await repo.deleteIfUnused(kid.id);
      }
      await repo.deleteIfUnused(comm.id);

      await repo.ensurePresets(bookId);

      final List<Category> after = await repo.listByBook(bookId, kind: 'expense');
      expect(
        after.where((Category c) => c.name == '通讯'),
        isEmpty,
        reason: '软删的预置分类不该被 ensurePresets 重新插入',
      );
      expect(
        after.where((Category c) => c.parentId == comm.id),
        isEmpty,
        reason: '父级已删，子分类也不该被补装回来',
      );
    });

    test('老账本：旧名字命中别名不重复插，且补齐图标、不改用户改过的名字', () async {
      // 模拟 v3 老账本：把「投资收益」改成旧名「理财」，并清空图标
      final Category invest = (await repo.listByBook(bookId, kind: 'income'))
          .firstWhere((Category c) => c.name == '投资收益');
      await repo.update(invest.id, name: '理财', icon: '');
      // 老库里根本没有「通讯」这一行 → 物理删掉（软删会被「不复活」规则挡住）
      final Category comm = (await repo.listByBook(bookId, kind: 'expense'))
          .firstWhere((Category c) => c.name == '通讯');
      await db.customStatement('DELETE FROM categories WHERE id = ?', <Object?>[comm.id]);

      await repo.ensurePresets(bookId);

      final List<Category> income = await repo.listByBook(bookId, kind: 'income');
      expect(
        income.where((Category c) => c.name == '理财').length,
        1,
        reason: '命中别名（理财）后不应再插一条「投资收益」',
      );
      expect(income.where((Category c) => c.name == '投资收益'), isEmpty);
      expect(
        income.firstWhere((Category c) => c.name == '理财').icon,
        'invest',
        reason: '只补空图标，名字保持用户改过的',
      );
      final List<Category> expense = await repo.listByBook(bookId, kind: 'expense');
      expect(expense.where((Category c) => c.name == '通讯').length, 1);
    });
  });

  group('无引用分类撤销删除', () {
    test('undelete 恢复同一条记录，id / 名称 / 父分类不变', () async {
      final Category parent = await mk('撤销父分类');
      final Category child = await mk('撤销子分类', parentId: parent.id);

      await repo.deleteIfUnused(child.id);
      expect(await repo.getById(child.id), isNull);
      expect(await repo.undelete(child.id), isTrue);

      final Category? restored = await repo.getById(child.id);
      expect(restored, isNotNull);
      expect(restored!.id, child.id);
      expect(restored.name, '撤销子分类');
      expect(restored.parentId, parent.id);
    });

    test('父分类也被删除时拒绝部分恢复，不产生孤儿节点', () async {
      final Category parent = await mk('会被删的父分类');
      final Category child = await mk('父删除后的子分类', parentId: parent.id);

      await repo.deleteIfUnused(child.id);
      await repo.deleteIfUnused(parent.id);
      expect(await repo.undelete(child.id), isFalse);
      final Category? deleted =
          await repo.getById(child.id, includeDeleted: true);
      expect(deleted!.deletedAt, isNotNull);
    });

    test('删除期间出现同名活跃分类时拒绝恢复，避免重复分类', () async {
      final Category original = await mk('同名撤销');
      await repo.deleteIfUnused(original.id);
      await mk('同名撤销');

      expect(await repo.undelete(original.id), isFalse);
    });
  });

  group('两级结构', () {
    test('可以建二级分类，parentId 指向一级', () async {
      final Category food = (await repo.listByBook(bookId, kind: 'expense'))
          .firstWhere((Category c) => c.name == '餐饮');
      // 用非预置的名字：预置二级已经有「早餐」了（同级重名会被拒）
      final Category night = await mk('夜宵', parentId: food.id);
      expect(night.parentId, food.id);
      expect(
        (await repo.childrenOf(food.id)).map((Category c) => c.name),
        contains('夜宵'),
      );
    });

    test('最多两级：给二级分类再挂子分类会抛错', () async {
      final Category food = (await repo.listByBook(bookId, kind: 'expense'))
          .firstWhere((Category c) => c.name == '餐饮');
      final Category night = await mk('夜宵', parentId: food.id);
      expect(
        () => mk('豆浆', parentId: night.id),
        throwsA(isA<CategoryException>()),
      );
    });

    test('不能把分类挂到自己下面', () async {
      final Category food = (await repo.listByBook(bookId, kind: 'expense'))
          .firstWhere((Category c) => c.name == '餐饮');
      expect(() => repo.setParent(food.id, food.id), throwsA(isA<CategoryException>()));
    });

    test('子分类必须和父分类同属支出/收入', () async {
      final Category salary = (await repo.listByBook(bookId, kind: 'income'))
          .firstWhere((Category c) => c.name == '工资');
      expect(
        () => mk('早饭', kind: 'expense', parentId: salary.id),
        throwsA(isA<CategoryException>()),
      );
    });
  });

  group('名称校验', () {
    test('空名 / 纯空格抛错', () async {
      expect(() => mk(''), throwsA(isA<CategoryException>()));
      expect(() => mk('   '), throwsA(isA<CategoryException>()));
    });

    test('同一父级下重名抛错；不同父级可以同名', () async {
      final Category food = (await repo.listByBook(bookId, kind: 'expense'))
          .firstWhere((Category c) => c.name == '餐饮');
      final Category transport = (await repo.listByBook(bookId, kind: 'expense'))
          .firstWhere((Category c) => c.name == '交通');
      await mk('夜宵', parentId: food.id);
      expect(() => mk('夜宵', parentId: food.id), throwsA(isA<CategoryException>()));
      // 换一个父级就允许同名
      final Category other = await mk('夜宵', parentId: transport.id);
      expect(other.name, '夜宵');
    });

    test('名称自动去掉首尾空格', () async {
      final Category c = await mk('  夜宵  ');
      expect(c.name, '夜宵');
    });

    test('kind 非法抛错', () async {
      expect(
        () => mk('bad', kind: 'other'),
        throwsA(isA<CategoryException>()),
      );
    });
  });

  group('编辑与排序', () {
    test('改名 / 改图标 / 改颜色立即生效', () async {
      final Category c = await mk('打车', icon: 'taxi', color: '#5A8DFF');
      await repo.update(c.id, name: '网约车', icon: 'transport', color: '#FF8A3D');
      final Category fresh = (await repo.getById(c.id))!;
      expect(fresh.name, '网约车');
      expect(fresh.icon, 'transport');
      expect(fresh.color, '#FF8A3D');
    });

    test('reorder 持久化：重新查询顺序不变', () async {
      final List<Category> roots =
          (await repo.listByBook(bookId, kind: 'expense'))
              .where((Category c) => c.parentId == null)
              .toList()
            ..sort((Category a, Category b) => a.sortOrder.compareTo(b.sortOrder));
      final List<String> reversed =
          roots.reversed.map((Category c) => c.id).toList();
      await repo.reorder(reversed);

      final List<Category> after =
          (await repo.listByBook(bookId, kind: 'expense'))
              .where((Category c) => c.parentId == null)
              .toList()
            ..sort((Category a, Category b) => a.sortOrder.compareTo(b.sortOrder));
      expect(after.map((Category c) => c.id).toList(), reversed);
    });
  });

  group('删除 / 归档 / 迁移', () {
    test('没有被引用的分类可以删除', () async {
      final Category c = await mk('临时');
      await repo.deleteIfUnused(c.id);
      expect(await repo.getById(c.id), isNull);
    });

    test('被账单引用时不能直接删，报错里带笔数', () async {
      final Category c = await mk('临时');
      await addTx(c.id);
      await expectLater(
        repo.deleteIfUnused(c.id),
        throwsA(
          isA<CategoryException>().having(
            (CategoryException e) => e.message,
            'message',
            contains('1 笔账单'),
          ),
        ),
      );
    });

    test('归档后不在可用列表，但历史账单仍能按 id 解析到名字', () async {
      final Category c = await mk('旧分类', icon: 'other');
      final TxRow tx = await addTx(c.id);
      await repo.archive(c.id);

      final List<Category> active =
          await repo.listByBook(bookId, includeArchived: false);
      expect(active.any((Category x) => x.id == c.id), isFalse);

      // 历史账单仍挂着这个 id，且仓储能取到（改名/归档都不影响历史显示）
      final TxRow? fresh = await txRepo.getById(tx.id);
      expect(fresh!.categoryId, c.id);
      final Category? archived = await repo.getById(c.id);
      expect(archived!.name, '旧分类');
      expect(archived.icon, 'other');
    });

    test('归档父分类会连带归档子分类', () async {
      final Category food = (await repo.listByBook(bookId, kind: 'expense'))
          .firstWhere((Category c) => c.name == '餐饮');
      final Category night = await mk('夜宵', parentId: food.id);
      await repo.archive(food.id);
      expect((await repo.getById(night.id))!.isArchived, 1);
    });

    test('迁移后删除：只改分类，金额/日期/备注/账户不变', () async {
      final Category from = await mk('旧分类');
      final Category to = await mk('新分类');
      final TxRow tx = await addTx(from.id, cents: 12345, note: '星巴克');

      await repo.migrateAndDelete(from.id, to.id);

      final TxRow fresh = (await txRepo.getById(tx.id))!;
      expect(fresh.categoryId, to.id);
      expect(fresh.amountCents, 12345);
      expect(fresh.note, '星巴克');
      expect(fresh.occurredAt, tx.occurredAt);
      expect(fresh.accountId, tx.accountId);
      expect(await repo.getById(from.id), isNull);
    });

    test('不能跨收支类型迁移', () async {
      final Category expense = await mk('临时');
      final Category salary = (await repo.listByBook(bookId, kind: 'income'))
          .firstWhere((Category c) => c.name == '工资');
      expect(
        () => repo.migrateAndDelete(expense.id, salary.id),
        throwsA(isA<CategoryException>()),
      );
    });

    test('有子分类时不能直接删（不留孤儿）', () async {
      final Category parent = await mk('父');
      await mk('子', parentId: parent.id);
      expect(
        () => repo.deleteIfUnused(parent.id),
        throwsA(isA<CategoryException>()),
      );
      // 子分类仍然挂在原父级，没有变成无主
      final Category? parentFresh = await repo.getById(parent.id);
      expect(parentFresh, isNotNull);
      final List<Category> kids = await repo.childrenOf(parent.id);
      expect(kids.single.parentId, parent.id);
    });
  });

  // P2-1：分类编辑必须原子 —— 主字段与父级同一事务，父级失败整笔回滚。
  group('分类编辑原子性', () {
    test('父级写入触发数据库错误：主字段更新一起回滚', () async {
      final Category parent = await mk('原子-父分类');
      final Category target = await mk(
        '原子-待编辑',
        icon: 'old-icon',
        color: '#111111',
      );
      final Category before = (await repo.getById(target.id))!;

      // 真实数据库层故障注入：只拦截「把 parent_id 改成非空」的 UPDATE。
      // 主字段那段不写 parent_id，所以它先执行成功；第二段才被 ABORT。
      await db.customStatement(
        'CREATE TRIGGER trg_block_parent_move '
        'BEFORE UPDATE OF parent_id ON categories '
        "WHEN NEW.id = '${target.id}' AND NEW.parent_id IS NOT NULL "
        "BEGIN SELECT RAISE(ABORT, 'injected parent failure'); END;",
      );
      addTearDown(
        () => db.customStatement('DROP TRIGGER IF EXISTS trg_block_parent_move'),
      );

      Object? thrown;
      try {
        await repo.update(
          target.id,
          name: '原子-改名后',
          icon: 'new-icon',
          color: '#222222',
          parentId: parent.id,
          changeParent: true,
        );
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isNotNull, reason: '父级写入失败必须把异常抛给调用方');

      final Category after = (await repo.getById(target.id))!;
      expect(after.name, before.name, reason: '名称必须回滚');
      expect(after.icon, before.icon, reason: '图标必须回滚');
      expect(after.color, before.color, reason: '颜色必须回滚');
      expect(after.parentId, isNull, reason: '父级必须保持原样');
      expect(after.sortOrder, before.sortOrder, reason: '排序必须回滚');
      expect(after.updatedAt, before.updatedAt, reason: 'updatedAt 必须回滚');
      expect(after.dirty, before.dirty);
    });

    test('无故障时主字段与父级一起生效', () async {
      final Category parent = await mk('原子-父分类2');
      final Category target = await mk('原子-待编辑2');

      final Category updated = await repo.update(
        target.id,
        name: '原子-改名成功',
        icon: 'icon-2',
        color: '#333333',
        parentId: parent.id,
        changeParent: true,
      );

      expect(updated.name, '原子-改名成功');
      expect(updated.icon, 'icon-2');
      expect(updated.color, '#333333');
      expect(updated.parentId, parent.id);

      final Category fresh = (await repo.getById(target.id))!;
      expect(fresh.parentId, parent.id);
      expect(fresh.name, '原子-改名成功');
    });

    test('setParent 走原子更新后仍保留原有业务校验', () async {
      final Category food = await mk('原子-餐饮');
      await expectLater(
        repo.setParent(food.id, food.id),
        throwsA(isA<CategoryException>()),
      );

      final Category child = await mk('原子-早餐', parentId: food.id);
      final Category other = await mk('原子-交通');
      // 把「有父级」的分类再挂到二级分类下 → 会出现三级，必须拒绝。
      await expectLater(
        repo.setParent(other.id, child.id),
        throwsA(isA<CategoryException>()),
      );
      final Category otherFresh = (await repo.getById(other.id))!;
      expect(otherFresh.parentId, isNull);
    });
  });
}
