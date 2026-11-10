/// P3 · 分类 `undelete()` 的事务化。
///
/// 旧实现四步裸跑：读原记录 → 校验重名 → 查父分类 → UPDATE。校验通过后、UPDATE 之前
/// 若并发插入同名活跃分类或删掉父分类，就会写出一个**不该恢复**的节点（校验结果在写入那
/// 一刻已过期）。现在整段包进一个事务：校验与写入看到同一份快照，且写入失败时整体回滚。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/data/repositories/book_repository.dart';
import 'package:yanxin/data/repositories/category_repository.dart';

import '../../helpers/test_database.dart';

void main() {
  late AppDatabase db;
  late CategoryRepository repo;
  late Book book;

  setUp(() async {
    db = openTestDatabase();
    addTearDown(db.close);
    book = await BookRepository(db).ensureDefaultBook();
    repo = CategoryRepository(db);
  });

  Future<Category> makeDeletedCategory(String name) async {
    final Category c = await repo.create(bookId: book.id, name: name, kind: 'expense');
    await repo.deleteIfUnused(c.id);
    final Category? deleted = await repo.getById(c.id, includeDeleted: true);
    expect(deleted!.deletedAt, isNotNull, reason: '前置条件：得先真的被软删');
    return deleted;
  }

  test('正常恢复：返回 true，记录回到活跃态', () async {
    final Category deleted = await makeDeletedCategory('待恢复');

    expect(await repo.undelete(deleted.id), isTrue);

    final Category? back = await repo.getById(deleted.id);
    expect(back, isNotNull);
    expect(back!.deletedAt, isNull);
  });

  test('同父级下已有同名活跃分类：返回 false，且记录仍是删除态', () async {
    final Category deleted = await makeDeletedCategory('撞名');
    // 删完之后又建了一个同名的
    await repo.create(bookId: book.id, name: '撞名', kind: 'expense');

    expect(await repo.undelete(deleted.id), isFalse);

    final Category? still = await repo.getById(deleted.id, includeDeleted: true);
    expect(still!.deletedAt, isNotNull);
  });

  test('写入阶段失败：异常抛出且不留部分恢复（事务回滚）', () async {
    final Category deleted = await makeDeletedCategory('写失败');
    // 恢复走的正是 `UPDATE ... SET deleted_at = NULL`，这里让它必然 ABORT。
    await db.customStatement('''
CREATE TRIGGER cat_undelete_boom BEFORE UPDATE OF deleted_at ON categories
WHEN NEW.deleted_at IS NULL
BEGIN
  SELECT RAISE(ABORT, 'boom');
END
''');

    await expectLater(repo.undelete(deleted.id), throwsA(anything));

    final Category? still = await repo.getById(deleted.id, includeDeleted: true);
    expect(still!.deletedAt, isNotNull, reason: '事务回滚后不能有半截状态');
  });
}
