/// 分类仓储（schema v4：两级 + 归档 + 迁移）。
///
/// 三条铁律：
/// 1. **历史账单永不静默丢分类**：被引用的分类只能「归档」或「先把账单迁走再删」；
/// 2. **层级只有两级**：`parentId` 只能指向同账本、同收支方向的一级分类；
/// 3. **软删除**：与全项目一致，`deleted_at` 非空即已删；归档用 `is_archived = 1`。
///
/// 校验失败抛 [CategoryException]（带可直接展示的中文），UI 捕获后给提示。
library;

import 'package:drift/drift.dart';

import '../../core/constants/preset.dart';
import '../../core/db/database.dart';
import '../../core/utils/id.dart';

/// 分类操作的**业务**错误（不是程序 bug：重名、层级超限、仍被引用等）。
class CategoryException implements Exception {
  const CategoryException(this.message);

  final String message;

  @override
  String toString() => message;
}

class CategoryRepository {
  CategoryRepository(this._db);

  final AppDatabase _db;

  // ────────────────────────────── 查询 ──────────────────────────────

  /// 按账本列出分类（默认**含归档**：历史账单要能显示归档分类的名字/图标）。
  ///
  /// [kind] 为 null 时返回支出 + 收入；排序 `sort_order → created_at`，同级顺序稳定。
  Future<List<Category>> listByBook(
    String bookId, {
    String? kind,
    bool includeArchived = true,
  }) {
    final q = _db.select(_db.categories)
      ..where((t) => t.bookId.equals(bookId) & t.deletedAt.isNull());
    if (kind != null) q.where((t) => t.kind.equals(kind));
    if (!includeArchived) q.where((t) => t.isArchived.equals(0));
    q.orderBy(<OrderingTerm Function($CategoriesTable)>[
      (t) => OrderingTerm.asc(t.sortOrder),
      (t) => OrderingTerm.asc(t.createdAt),
    ]);
    return q.get();
  }

  /// 按 id 取分类；[includeDeleted]=true 时可取已软删行（历史账单兜底用）。
  Future<Category?> getById(String id, {bool includeDeleted = false}) {
    final q = _db.select(_db.categories)..where((t) => t.id.equals(id));
    if (!includeDeleted) q.where((t) => t.deletedAt.isNull());
    return q.getSingleOrNull();
  }

  /// 某个一级分类的子分类（按排序）。
  Future<List<Category>> childrenOf(String parentId) {
    return (_db.select(_db.categories)
          ..where(
            (t) => t.parentId.equals(parentId) & t.deletedAt.isNull(),
          )
          ..orderBy(<OrderingTerm Function($CategoriesTable)>[
            (t) => OrderingTerm.asc(t.sortOrder),
            (t) => OrderingTerm.asc(t.createdAt),
          ]))
        .get();
  }

  /// 引用这个分类的账单数（默认连子分类一起算）。
  Future<int> countTransactions(String id, {bool includeChildren = true}) async {
    final List<String> ids = <String>[id];
    if (includeChildren) {
      ids.addAll(
        (await childrenOf(id)).map((Category c) => c.id),
      );
    }
    final count = _db.transactions.id.count();
    final q = _db.selectOnly(_db.transactions)
      ..addColumns(<Expression<Object>>[count])
      ..where(
        _db.transactions.categoryId.isIn(ids) &
            _db.transactions.deletedAt.isNull(),
      );
    final row = await q.getSingle();
    return row.read(count) ?? 0;
  }

  // ────────────────────────────── 预置补齐 ──────────────────────────────

  /// 幂等补齐预置分类（新建账本已写过，这里服务**老账本升级**）。
  ///
  /// 命中规则（2026-10-29 起分两级判定，原来只按 `kind|name` 全局比对）：
  /// - **一级**：只在「父级为空」的行里找 —— 同名或命中别名（理财 / 红包 / 人情）就算已存在；
  /// - **二级**：只在**同一个父分类**下找 —— 不同一级下允许同名子分类（「红包」只属于人情社交）；
  /// - 已存在但 `icon` 为空时顺手补上 icon key（只补空值，不改用户改过的图标）；
  /// - **父分类被用户删掉（软删）→ 整棵树都不补**，不给一个已删的父级塞子分类。
  Future<void> ensurePresets(String bookId) async {
    // ⚠️ **连软删的行一起看**：用户删掉的预置分类不能被「补装」复活
    //    （真机实测踩到：删掉「购物」3 秒后，下一次 provider 刷新又冒出来一条）。
    final List<Category> existing =
        await (_db.select(_db.categories)
              ..where((t) => t.bookId.equals(bookId)))
            .get();

    final Map<String, Category> roots = <String, Category>{};
    final Map<String, Category> children = <String, Category>{};
    for (final Category c in existing) {
      if (c.parentId == null) {
        roots['${c.kind}|${c.name}'] = c;
      } else {
        children['${c.parentId}|${c.name}'] = c;
      }
    }

    /// 只补空图标（用户改过的图标不覆盖）。
    Future<void> fillIcon(String id, String iconKey) => _db.customStatement(
      'UPDATE categories SET icon = ? WHERE id = ? '
      "AND (icon IS NULL OR icon = '')",
      <Object?>[iconKey, id],
    );

    Future<Category> ensureRoot(
      PresetCategory preset,
      String kind,
      int index,
    ) async {
      Category? hit;
      for (final String n in <String>[preset.name, ...preset.aliases]) {
        hit = roots['$kind|$n'];
        if (hit != null) break;
      }
      if (hit != null) {
        await fillIcon(hit.id, preset.iconKey);
        return hit;
      }
      final Category created = await create(
        bookId: bookId,
        name: preset.name,
        kind: kind,
        icon: preset.iconKey,
        color: preset.color,
        sortOrder: index,
        isPreset: true,
      );
      roots['$kind|${preset.name}'] = created;
      return created;
    }

    Future<void> ensureChildren(
      Category root,
      PresetCategory preset,
      String kind,
    ) async {
      if (root.deletedAt != null) return;
      for (int i = 0; i < preset.children.length; i++) {
        final PresetChild child = preset.children[i];
        Category? hit;
        for (final String n in <String>[child.name, ...child.aliases]) {
          hit = children['${root.id}|$n'];
          if (hit != null) break;
        }
        if (hit != null) {
          await fillIcon(hit.id, child.iconKey);
          continue;
        }
        final Category created = await create(
          bookId: bookId,
          name: child.name,
          kind: kind,
          parentId: root.id,
          icon: child.iconKey,
          color: preset.color, // 二级沿用一级的颜色，视觉上归组
          sortOrder: i,
          isPreset: true,
        );
        children['${root.id}|${child.name}'] = created;
      }
    }

    for (int i = 0; i < presetExpense.length; i++) {
      final Category root = await ensureRoot(presetExpense[i], 'expense', i);
      await ensureChildren(root, presetExpense[i], 'expense');
    }
    for (int i = 0; i < presetIncome.length; i++) {
      final Category root = await ensureRoot(presetIncome[i], 'income', i);
      await ensureChildren(root, presetIncome[i], 'income');
    }
  }

  // ────────────────────────────── 创建 / 修改 ──────────────────────────────

  /// 新建分类（一级：[parentId] 为 null）。
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
    if (bookId.isEmpty) {
      throw const CategoryException('账本不存在，请重新进入');
    }
    final String trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const CategoryException('分类名称不能为空');
    }
    if (kind != 'expense' && kind != 'income') {
      throw const CategoryException('收支类型不合法');
    }

    String? parent = parentId;
    if (parent != null) {
      final Category? p = await getById(parent);
      if (p == null) throw const CategoryException('父分类不存在');
      if (p.kind != kind) {
        throw const CategoryException('子分类必须和父分类同属支出或收入');
      }
      if (p.parentId != null) {
        throw const CategoryException('最多支持两级分类');
      }
      parent = p.id;
    }

    await _assertNameFree(
      bookId: bookId,
      kind: kind,
      parentId: parent,
      name: trimmed,
    );

    final int order = sortOrder >= 0
        ? sortOrder
        : await _nextSortOrder(bookId, kind, parent);
    final int now = DateTime.now().millisecondsSinceEpoch;
    return _db
        .into(_db.categories)
        .insertReturning(
          CategoriesCompanion.insert(
            id: id ?? uuidV4(),
            bookId: bookId,
            name: trimmed,
            kind: kind,
            parentId: Value(parent),
            createdAt: now,
            updatedAt: now,
            icon: Value(icon),
            color: Value(color),
            sortOrder: Value(order),
            isPreset: Value(isPreset ? 1 : 0),
            ownerId: Value(ownerId),
          ),
        );
  }

  /// 局部更新。改名 / 改图标 / 改颜色 / 挪父级 / 改排序 / 归档都用它。
  ///
  /// [changeParent] 为 true 时，主字段与父级变更在**同一个事务**里完成：
  /// 主字段先写、父级后写，任一步失败（含数据库层失败）整笔回滚，
  /// 不会出现「UI 报保存失败，但名称/图标已经落库」的半更新状态。
  Future<Category> update(
    String id, {
    String? name,
    String? icon,
    String? color,
    int? sortOrder,
    int? isArchived,
    String? parentId,
    bool changeParent = false,
  }) {
    return _db.transaction<Category>(() async {
      final Category? current = await getById(id);
      if (current == null) throw const CategoryException('分类不存在或已删除');

      String? trimmed;
      if (name != null) {
        trimmed = name.trim();
        if (trimmed.isEmpty) throw const CategoryException('分类名称不能为空');
      }

      // 父级合法性：与 setParent 完全一致（自己、父存在、同类型、两级、无子分类）。
      if (changeParent) {
        await _assertParentAssignable(current, parentId);
      }

      final String? targetParentId = changeParent ? parentId : current.parentId;
      if (trimmed != null || changeParent) {
        await _assertNameFree(
          bookId: current.bookId,
          kind: current.kind,
          parentId: targetParentId,
          name: trimmed ?? current.name,
          excludeId: id,
        );
      }

      int? targetSortOrder = sortOrder;
      if (changeParent) {
        targetSortOrder = await _nextSortOrder(
          current.bookId,
          current.kind,
          parentId,
        );
      }

      final int now = DateTime.now().millisecondsSinceEpoch;
      // 第一段：主字段（名称 / 图标 / 颜色 / 排序 / 归档）。
      await (_db.update(_db.categories)
            ..where((t) => t.id.equals(id) & t.deletedAt.isNull()))
          .write(
            CategoriesCompanion(
              name: trimmed == null ? const Value.absent() : Value(trimmed),
              icon: icon == null ? const Value.absent() : Value(icon),
              color: color == null ? const Value.absent() : Value(color),
              sortOrder: targetSortOrder == null
                  ? const Value.absent()
                  : Value(targetSortOrder),
              isArchived: isArchived == null
                  ? const Value.absent()
                  : Value(isArchived),
              updatedAt: Value(now),
              dirty: const Value(1),
            ),
          );

      // 第二段：父级。与第一段同属一个事务 —— 这里失败会连第一段一起回滚。
      if (changeParent) {
        await (_db.update(_db.categories)..where((t) => t.id.equals(id)))
            .write(
              CategoriesCompanion(
                parentId: Value(parentId),
                updatedAt: Value(now),
                dirty: const Value(1),
              ),
            );
      }

      final Category? fresh = await getById(id);
      if (fresh == null) throw const CategoryException('分类不存在或已删除');
      return fresh;
    });
  }

  /// 父级变更的业务校验（`setParent` 与原子 `update` 共用）。
  Future<void> _assertParentAssignable(Category current, String? parentId) async {
    if (parentId == current.id) {
      throw const CategoryException('不能把分类挂到自己下面');
    }
    if (parentId == null) return;

    final Category? parent = await getById(parentId);
    if (parent == null) throw const CategoryException('父分类不存在');
    if (parent.kind != current.kind) {
      throw const CategoryException('子分类必须和父分类同属支出或收入');
    }
    if (parent.parentId != null) {
      throw const CategoryException('最多支持两级分类');
    }
    // 自己下面还有子分类时不能再变成二级（否则会出现三级）
    final List<Category> kids = await childrenOf(current.id);
    if (kids.isNotEmpty) {
      throw const CategoryException('这个分类下还有子分类，不能再设为二级');
    }
  }

  /// 改变父级（`null` = 提为一级）。只允许两级，且不能挂到自己的子分类下。
  ///
  /// 走原子 [update]：父级与主字段写在同一事务内。
  Future<void> setParent(String id, String? parentId) async {
    await update(id, parentId: parentId, changeParent: true);
  }

  // ────────────────────────────── 排序 ──────────────────────────────

  /// 把一组**同级**分类按给定顺序重排（id 顺序即新的 sort_order）。
  Future<void> reorder(List<String> orderedIds) async {
    if (orderedIds.isEmpty) return;
    final int now = DateTime.now().millisecondsSinceEpoch;
    await _db.transaction(() async {
      for (int i = 0; i < orderedIds.length; i++) {
        await (_db.update(_db.categories)
              ..where((t) => t.id.equals(orderedIds[i])))
            .write(
              CategoriesCompanion(
                sortOrder: Value(i),
                updatedAt: Value(now),
                dirty: const Value(1),
              ),
            );
      }
    });
  }

  // ────────────────────────────── 归档 / 删除 / 迁移 ──────────────────────────────

  /// 归档：不出现在新建账单的选择里，但历史账单照常显示。
  ///
  /// [withChildren] = true 时把子分类一起归档（避免父级归档后子级还能选）。
  Future<int> archive(String id, {bool withChildren = true}) async {
    final Category? category = await getById(id, includeDeleted: true);
    if (category == null) throw const CategoryException('分类不存在或已删除');
    final int now = DateTime.now().millisecondsSinceEpoch;
    int changed = 0;
    await _db.transaction(() async {
      changed = await (_db.update(_db.categories)
            ..where((t) => t.id.equals(id) & t.deletedAt.isNull()))
          .write(
            CategoriesCompanion(
              isArchived: const Value(1),
              updatedAt: Value(now),
              dirty: const Value(1),
            ),
          );
      if (withChildren) {
        final List<Category> kids = await childrenOf(id);
        for (final Category kid in kids) {
          await (_db.update(_db.categories)..where((t) => t.id.equals(kid.id)))
              .write(
                CategoriesCompanion(
                  isArchived: const Value(1),
                  updatedAt: Value(now),
                  dirty: const Value(1),
                ),
              );
        }
      }
    });
    return changed;
  }

  /// 取消归档（同时把子分类恢复，避免半残状态）。
  Future<void> unarchive(String id) async {
    final Category? category = await getById(id);
    if (category == null) throw const CategoryException('分类不存在或已删除');
    final int now = DateTime.now().millisecondsSinceEpoch;
    await _db.transaction(() async {
      await (_db.update(_db.categories)..where((t) => t.id.equals(id))).write(
        CategoriesCompanion(
          isArchived: const Value(0),
          updatedAt: Value(now),
          dirty: const Value(1),
        ),
      );
      for (final Category kid in await childrenOf(id)) {
        await (_db.update(_db.categories)..where((t) => t.id.equals(kid.id)))
            .write(
              CategoriesCompanion(
                isArchived: const Value(0),
                updatedAt: Value(now),
                dirty: const Value(1),
              ),
            );
      }
    });
  }

  /// 删除**没有被任何账单引用**的分类（软删）。
  ///
  /// 有引用 / 有子分类时抛 [CategoryException]，提示改用归档或迁移。
  Future<void> deleteIfUnused(String id) async {
    final Category? category = await getById(id);
    if (category == null) throw const CategoryException('分类不存在或已删除');
    final int used = await countTransactions(id);
    if (used > 0) {
      throw CategoryException('这个分类下有 $used 笔账单，不能直接删除，可以归档或先把账单迁走');
    }
    final List<Category> kids = await childrenOf(id);
    if (kids.isNotEmpty) {
      throw CategoryException('这个分类下还有 ${kids.length} 个子分类，请先处理子分类');
    }
    final int now = DateTime.now().millisecondsSinceEpoch;
    await (_db.update(_db.categories)
          ..where((t) => t.id.equals(id) & t.deletedAt.isNull()))
        .write(
          CategoriesCompanion(
            deletedAt: Value(now),
            updatedAt: Value(now),
            dirty: const Value(1),
          ),
        );
  }

  /// 恢复一笔软删的分类（写回 deleted_at = null）。返回是否成功。
  ///
  /// 父分类在删除期间也被删掉时返回 false，不做“升为一级”的部分恢复；
  /// 只有完整原层级可恢复时才执行。
  ///
  /// P3：**读 + 校验 + 写入全部收进同一个事务**。原先四步裸跑，校验通过后、
  /// UPDATE 之前若有并发插入同名活跃分类或删掉父分类，就会写出一个不该恢复的节点
  /// （校验结果在写入那一刻已经过期）。事务内重做校验 = 校验与写入看到同一份快照。
  Future<bool> undelete(String id) {
    return _db.transaction<bool>(() async {
      final Category? category = await getById(id, includeDeleted: true);
      if (category == null || category.deletedAt == null) return false;
      try {
        await _assertNameFree(
          bookId: category.bookId,
          kind: category.kind,
          parentId: category.parentId,
          name: category.name,
          excludeId: category.id,
        );
      } on CategoryException {
        // 事务里「返回 false」= 提交一个只读事务，什么都没写。
        return false;
      }
      final int now = DateTime.now().millisecondsSinceEpoch;
      final String? originalParentId = category.parentId;
      final String? parentId = originalParentId;
      if (originalParentId != null) {
        final Category? parent =
            await (_db.select(_db.categories)
                  ..where((t) => t.id.equals(originalParentId)))
                .getSingleOrNull();
        if (parent == null || parent.deletedAt != null) return false;
      }
      // 并发下这一步可能 0 行（别人刚把它恢复了 / 又删了一次），用受影响行数兜底。
      final int changed =
          await (_db.update(_db.categories)..where((t) => t.id.equals(id)))
              .write(
                CategoriesCompanion(
                  deletedAt: const Value(null),
                  parentId: Value(parentId),
                  updatedAt: Value(now),
                  dirty: const Value(1),
                ),
              );
      return changed > 0;
    });
  }

  /// 把 [fromId]（含其子分类）下的账单迁到 [toId]，然后删掉原分类。
  ///
  /// 一个事务内完成：要么全迁全删，要么都不动。金额 / 日期 / 备注 / 账户**一律不动**，
  /// 只改 `category_id`（这是任务书 §7 的硬要求）。
  Future<int> migrateAndDelete(String fromId, String toId) async {
    if (fromId == toId) throw const CategoryException('目标分类不能是自己');
    final Category? from = await getById(fromId);
    final Category? to = await getById(toId);
    if (from == null) throw const CategoryException('原分类不存在或已删除');
    if (to == null) throw const CategoryException('目标分类不存在或已删除');
    if (from.kind != to.kind) {
      throw const CategoryException('只能迁移到同一收支类型的分类');
    }

    final List<String> sources = <String>[
      fromId,
      ...(await childrenOf(fromId)).map((Category c) => c.id),
    ];
    final int now = DateTime.now().millisecondsSinceEpoch;
    int moved = 0;
    await _db.transaction(() async {
      moved = await (_db.update(_db.transactions)
            ..where(
              (t) =>
                  t.categoryId.isIn(sources) & t.deletedAt.isNull(),
            ))
          .write(
            TransactionsCompanion(
              categoryId: Value(toId),
              updatedAt: Value(now),
              dirty: const Value(1),
            ),
          );
      // 子分类先删，避免 parent_id 指向已删父级
      for (final String kid in sources.skip(1)) {
        await (_db.update(_db.categories)..where((t) => t.id.equals(kid)))
            .write(
              CategoriesCompanion(
                deletedAt: Value(now),
                updatedAt: Value(now),
                dirty: const Value(1),
              ),
            );
      }
      await (_db.update(_db.categories)..where((t) => t.id.equals(fromId)))
          .write(
            CategoriesCompanion(
              deletedAt: Value(now),
              updatedAt: Value(now),
              dirty: const Value(1),
            ),
          );
    });
    return moved;
  }

  // ────────────────────────────── 内部 ──────────────────────────────

  /// 同级重名校验：`(book, kind, parent, name)` 唯一（未删除 + 未归档的一起算）。
  Future<void> _assertNameFree({
    required String bookId,
    required String kind,
    required String? parentId,
    required String name,
    String? excludeId,
  }) async {
    final q = _db.select(_db.categories)
      ..where(
        (t) =>
            t.bookId.equals(bookId) &
            t.kind.equals(kind) &
            t.name.equals(name) &
            t.deletedAt.isNull(),
      );
    if (parentId == null) {
      q.where((t) => t.parentId.isNull());
    } else {
      q.where((t) => t.parentId.equals(parentId));
    }
    final List<Category> hits = await q.get();
    final bool conflict = hits.any((Category c) => c.id != excludeId);
    if (conflict) {
      throw CategoryException(
        parentId == null ? '已经有叫「$name」的分类了' : '这个父分类下已经有「$name」了',
      );
    }
  }

  Future<int> _nextSortOrder(
    String bookId,
    String kind,
    String? parentId,
  ) async {
    final List<Category> siblings = (await listByBook(bookId, kind: kind))
        .where((Category c) => c.parentId == parentId)
        .toList();
    if (siblings.isEmpty) return 0;
    return siblings
            .map((Category c) => c.sortOrder)
            .reduce((int a, int b) => a > b ? a : b) +
        1;
  }
}
