/// 分类的**写操作入口**（application 层）：UI 只调这里，不直接碰仓储。
///
/// 每个动作成功后统一 `invalidate(categoriesProvider)`，让记账页选择器、统计/报表的
/// 分类名解析、搜索都跟着刷新 —— 这类"改完不刷新"的 bug 在本项目里踩过多次
/// （HANDOFF 不变量 #2），所以收口到一处。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/data/providers/category_providers.dart';
import 'package:yanxin/data/providers/database.dart';
import 'package:yanxin/data/repositories/category_repository.dart';

/// 分类写操作的 Provider 入口（widget 里 `ref.read(categoryActionsProvider)`）。
final categoryActionsProvider = Provider<CategoryActions>(
  CategoryActions.new,
);

/// 分类写操作。
class CategoryActions {
  CategoryActions(this._ref);

  final Ref _ref;

  CategoryRepository get _repo => _ref.read(categoryRepositoryProvider);

  void _refresh() {
    _ref.invalidate(categoriesProvider);
    _ref.invalidate(categoriesByKindProvider('expense'));
    _ref.invalidate(categoriesByKindProvider('income'));
  }

  /// 新建（[parentId] 非空即二级分类）。返回新分类；业务错误抛 [CategoryException]。
  Future<Category> create({
    required String bookId,
    required String name,
    required String kind,
    String? parentId,
    String icon = '',
    String color = '',
  }) async {
    final Category created = await _repo.create(
      bookId: bookId,
      name: name,
      kind: kind,
      parentId: parentId,
      icon: icon,
      color: color,
    );
    _refresh();
    return created;
  }

  /// 编辑（名称 / 图标 / 颜色 / 父级）。
  ///
  /// 主字段与父级由仓储在**同一事务**内写入，任一步失败整笔回滚，
  /// 不会出现「保存失败但名称已改」的半更新。
  Future<void> update(
    String id, {
    String? name,
    String? icon,
    String? color,
    String? parentId,
    bool changeParent = false,
  }) async {
    await _repo.update(
      id,
      name: name,
      icon: icon,
      color: color,
      parentId: parentId,
      changeParent: changeParent,
    );
    _refresh();
  }

  Future<void> archive(String id) async {
    await _repo.archive(id);
    _refresh();
  }

  Future<void> unarchive(String id) async {
    await _repo.unarchive(id);
    _refresh();
  }

  /// 删除（无引用时）。有引用会抛 [CategoryException]，UI 提示改用归档/迁移。
  Future<void> deleteIfUnused(String id) async {
    await _repo.deleteIfUnused(id);
    _refresh();
  }

  /// 撤销删除（无引用删除路径）。父分类已不存在时拒绝恢复并返回 false。
  Future<bool> undoDelete(String id) async {
    final bool ok = await _repo.undelete(id);
    if (ok) _refresh();
    return ok;
  }

  /// 把账单迁到 [toId] 后删除 [fromId]（含子分类）。返回迁移笔数。
  Future<int> migrateAndDelete(String fromId, String toId) async {
    final int moved = await _repo.migrateAndDelete(fromId, toId);
    _refresh();
    return moved;
  }

  /// 同级重排（拖拽 / 上移下移都走它）。
  Future<void> reorder(List<String> orderedIds) async {
    await _repo.reorder(orderedIds);
    _refresh();
  }

  Future<int> countTransactions(String id) => _repo.countTransactions(id);
}
