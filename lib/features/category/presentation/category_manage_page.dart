/// 分类管理（schema v4）：支出/收入 Tab、两级树、图标/颜色、排序、归档、迁移删除。
///
/// 交互取舍：
/// - **排序用「上移 / 下移」**而不是拖拽 —— 两级树里嵌套拖拽的落点很容易跨层级
///   （任务书也明确允许用上移/下移兜底），误操作代价比"炫"更重要；
/// - 删除**永远先看引用**：没账单才真删；有账单给「归档」或「迁移到别的分类」两条路，
///   绝不让历史账单丢分类；
/// - 归档分区默认折叠，恢复/彻底删除都在这里；
/// - 一级分类 = Collapse：点根分类内联展开/收起二级分类（AnimatedSize 过渡），
///   二级分类用 `Wrap` 流式排布；行内三点菜单升级为底部 ActionSheet
///   （`showModalBottomSheet`），操作集合与旧 PopupMenu 一致。
/// - **添加分类的入口两个**（2026-10-29）：
///   ① **右下角、屏高 15%（自底算）** 固定的 [ToonFloatMenu]（圆形 / 加号 /
///   `trigger: click` / 向上展开 `F` 一级、`S` 二级）—— 新建的主入口；
///   ② 列表末尾的 ghost 按钮（滚到底顺手能点，空态也有一个同款）。
///   AppBar 原来还有个「＋」，与浮动按钮功能完全重复，已移除。
///   展开网格末尾的「添加」块（二级入口）保持原样不动。
/// - **所有底部面板的内容都是线性布局 `Column`**（不用 `ListView` / `PopupMenu`）：
///   操作面板、父分类选择、迁移目标、分类编辑层、图标层一致。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:yanxin/core/constants/category_icons.dart';
import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/core/theme/tokens.dart';
import 'package:yanxin/core/theme/toon.dart';
import 'package:yanxin/data/providers/book_providers.dart';
import 'package:yanxin/data/providers/category_providers.dart';
import 'package:yanxin/features/shared/write_failure.dart';
import 'package:yanxin/ui_kit/app_page_state.dart';

import '../application/category_actions.dart';
import 'widgets/category_editor.dart';

/// 浮动按钮圆心距屏幕**底部**的比例（任务书：右下角、屏高 15% 处，固定不可拖动）。
const double _kFloatBottomFactor = 0.15;

/// 浮动按钮直径（与 M3 FAB 默认一致，保证 48dp 以上触控区）。
const double _kFloatSize = 56;

/// 分类管理页。
class CategoryManagePage extends ConsumerStatefulWidget {
  const CategoryManagePage({super.key});

  @override
  ConsumerState<CategoryManagePage> createState() => _CategoryManagePageState();
}

class _CategoryManagePageState extends ConsumerState<CategoryManagePage> {
  String _kind = 'expense';
  bool _showArchived = false;

  /// 当前展开的一级分类 id（默认全部收起）。
  final Set<String> _expandedRoots = <String>{};

  CategoryActions get _actions => ref.read(categoryActionsProvider);

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    final AsyncValue<List<Category>> async = ref.watch(categoriesProvider);
    final double screenH = MediaQuery.sizeOf(context).height;

    return Stack(
      children: <Widget>[
        Scaffold(
          backgroundColor: p.paper,
          // AppBar 不再放「＋」：新建入口收敛到右下角的浮动按钮
          //（两者功能完全重复，2026-10-29 用户要求只留悬浮按钮）。
          appBar: AppBar(title: const Text('分类管理')),
          body: async.when(
            loading: () => const AppPageLoading(),
            error: (Object e, StackTrace _) => AppPageError(error: e),
            data: (List<Category> all) => Column(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Center(
                    child: ToonSeg(
                      labels: const <String>['支出', '收入'],
                      index: _kind == 'expense' ? 0 : 1,
                      onChanged: (int i) =>
                          setState(() => _kind = i == 0 ? 'expense' : 'income'),
                    ),
                  ),
                ),
                Expanded(child: _buildBody(all)),
              ],
            ),
          ),
        ),
        // 添加分类的浮动入口（Ant Design `FloatButton` 语义）：
        // 圆形 + 加号 + `trigger: click`，**固定**在右下角、屏幕高度 15% 处（自底算），
        // 点按**向上**展开。坐标用整屏高度算，所以这一层必须挂在 Scaffold 外面（`Stack` 覆盖整屏）。
        Positioned(
          right: 16,
          bottom: screenH * _kFloatBottomFactor - _kFloatSize / 2,
          child: ToonFloatMenu(
            tooltip: '添加分类',
            expandUp: true,
            actions: <ToonFloatAction>[
              ToonFloatAction(
                letter: 'F',
                label: '添加一级分类',
                onTap: _create,
              ),
              ToonFloatAction(
                letter: 'S',
                label: '添加二级分类',
                onTap: _createChild,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBody(List<Category> all) {
    final ToonPalette p = context.toon;
    final List<Category> mine = all
        .where((Category c) => c.kind == _kind)
        .toList();
    final List<Category> active = mine
        .where((Category c) => c.isArchived == 0)
        .toList();
    final List<Category> roots =
        active.where((Category c) => c.parentId == null).toList()
          ..sort(_bySort);
    final List<Category> archived =
        mine.where((Category c) => c.isArchived == 1).toList()..sort(_bySort);

    if (roots.isEmpty && archived.isEmpty) {
      return _EmptyState(onCreate: _create);
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
      children: <Widget>[
        for (final Category root in roots) ...<Widget>[
          _CategoryGroup(
            root: root,
            children:
                active.where((Category c) => c.parentId == root.id).toList()
                  ..sort(_bySort),
            expanded: _expandedRoots.contains(root.id),
            onAddChild: (Category c) => _create(parentId: c.id),
            onToggle: () => setState(
              () => _expandedRoots.contains(root.id)
                  ? _expandedRoots.remove(root.id)
                  : _expandedRoots.add(root.id),
            ),
            onMore: (Category c) => _openActions(
              c,
              roots: roots,
              active: active,
              all: all,
            ),
          ),
          const SizedBox(height: 10),
        ],
        const SizedBox(height: 4),
        ToonButton(
          block: true,
          kind: ToonButtonKind.ghost,
          icon: Icons.add_rounded,
          label: '新建${_kind == 'expense' ? '支出' : '收入'}分类',
          onPressed: _create,
        ),
        if (archived.isNotEmpty) ...<Widget>[
          const SizedBox(height: 14),
          Divider(color: p.line),
          InkWell(
            onTap: () => setState(() => _showArchived = !_showArchived),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: <Widget>[
                  Text(
                    '已归档（${archived.length}）',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: p.ink2,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    _showArchived
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 20,
                    color: p.ink3,
                  ),
                ],
              ),
            ),
          ),
          if (_showArchived)
            for (final Category c in archived)
              _ArchivedRow(
                category: c,
                onRestore: () => _restore(c),
                onDelete: () => _remove(c, all),
              ),
          if (_showArchived)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '归档的分类不会出现在新建账单里，历史账单照常显示。',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: p.ink3,
                ),
              ),
            ),
        ],
      ],
    );
  }

  int _bySort(Category a, Category b) {
    final int byOrder = a.sortOrder.compareTo(b.sortOrder);
    return byOrder != 0 ? byOrder : a.createdAt.compareTo(b.createdAt);
  }

  /// 底部 ActionSheet：一级 / 二级分类共用（「添加」不在面板里 —— 它是网格末尾的块）。
  Future<void> _openActions(
    Category category, {
    required List<Category> roots,
    required List<Category> active,
    required List<Category> all,
  }) async {
    final ToonPalette p = context.toon;
    final String? action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: p.paper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Tok.rLg)),
      ),
      builder: (BuildContext sheetContext) => SafeArea(
        // 矮视口（横屏 / 小屏）下操作行可能超出面板上限：允许滚动，禁止溢出。
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const SizedBox(height: 10),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: p.line,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                child: Row(
                  children: <Widget>[
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: categoryColor(
                          p,
                          category.color,
                          kind: category.kind,
                        ),
                        borderRadius: BorderRadius.circular(Tok.rSm),
                      ),
                      child: Icon(
                        categoryIconData(category.icon, kind: category.kind),
                        size: 18,
                        color: categoryOnColor(
                          p,
                          category.color,
                          kind: category.kind,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        category.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              _SheetTile(
                icon: Icons.edit_outlined,
                label: '编辑',
                onTap: () => Navigator.of(sheetContext).pop('edit'),
              ),
              _SheetTile(
                icon: Icons.arrow_upward_rounded,
                label: '上移',
                onTap: () => Navigator.of(sheetContext).pop('up'),
              ),
              _SheetTile(
                icon: Icons.arrow_downward_rounded,
                label: '下移',
                onTap: () => Navigator.of(sheetContext).pop('down'),
              ),
              _SheetTile(
                icon: Icons.archive_outlined,
                label: '归档',
                onTap: () => Navigator.of(sheetContext).pop('archive'),
              ),
              _SheetTile(
                icon: Icons.delete_outline_rounded,
                label: '删除',
                danger: true,
                onTap: () => Navigator.of(sheetContext).pop('delete'),
              ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'edit':
        await _edit(category);
      case 'up':
        await _move(category, roots, active, -1);
      case 'down':
        await _move(category, roots, active, 1);
      case 'archive':
        await _archive(category);
      case 'delete':
        await _remove(category, all);
    }
  }

  // ────────────────────────────── 操作 ──────────────────────────────

  Future<void> _create({String? parentId}) async {
    final String? bookId = await ref.read(activeBookIdProvider.future);
    if (bookId == null || !mounted) return;
    await showCategoryEditor(
      context,
      bookId: bookId,
      kind: _kind,
      initialParentId: parentId,
    );
  }

  /// 浮动按钮的「S（二级）」入口：二级必须挂在某个一级分类下，
  /// 所以先选父分类、再把它预置进编辑器。
  /// 原有入口（展开网格末尾的「添加」块）保持不变。
  Future<void> _createChild() async {
    final List<Category> all =
        ref.read(categoriesProvider).value ?? const <Category>[];
    final List<Category> roots =
        all
            .where(
              (Category c) =>
                  c.kind == _kind &&
                  c.parentId == null &&
                  c.isArchived == 0 &&
                  c.deletedAt == null,
            )
            .toList()
          ..sort(_bySort);
    if (roots.isEmpty) {
      _toast('先建一个一级分类，才能往下加二级分类');
      return;
    }
    final ToonPalette p = context.toon;
    final Category? parent = await showModalBottomSheet<Category>(
      context: context,
      backgroundColor: p.paper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Tok.rXl)),
      ),
      // 内容用线性布局 Column（任务书要求）；矮屏可滚动，不溢出。
      builder: (BuildContext sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const SizedBox(height: 8),
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: p.line,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '挂到哪个一级分类下？',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: p.ink2,
                    ),
                  ),
                ),
              ),
              for (final Category c in roots)
                _SheetTile(
                  icon: categoryIconData(c.icon, kind: c.kind),
                  label: c.name,
                  onTap: () => Navigator.of(sheetContext).pop(c),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    if (!mounted || parent == null) return;
    await _create(parentId: parent.id);
  }

  Future<void> _edit(Category category) async {
    final String? bookId = await ref.read(activeBookIdProvider.future);
    if (bookId == null || !mounted) return;
    await showCategoryEditor(
      context,
      bookId: bookId,
      kind: _kind,
      editing: category,
    );
  }

  /// 同级上移 / 下移（[delta] = -1 / +1）。
  Future<void> _move(
    Category category,
    List<Category> roots,
    List<Category> active,
    int delta,
  ) async {
    final List<Category> siblings = category.parentId == null
        ? roots
        : (active
              .where((Category c) => c.parentId == category.parentId)
              .toList()
            ..sort(_bySort));
    final int index = siblings.indexWhere((Category c) => c.id == category.id);
    final int target = index + delta;
    if (index < 0 || target < 0 || target >= siblings.length) return;
    final List<Category> next = <Category>[...siblings];
    final Category moved = next.removeAt(index);
    next.insert(target, moved);
    await _actions.reorder(next.map((Category c) => c.id).toList());
  }

  void _showWriteFailure(Object error, String action) {
    if (mounted) showToonError(context, writeFailureMessage(error, action: action));
  }

  /// 分类写操作的统一护栏：捕获业务/存储异常并反馈；失败返回 false。
  Future<bool> _runWrite(String action, Future<void> Function() write) async {
    try {
      await write();
      return true;
    } catch (e) {
      _showWriteFailure(e, action);
      return false;
    }
  }

  Future<void> _archive(Category category) async {
    final int used;
    try {
      used = await _actions.countTransactions(category.id);
    } catch (e) {
      _showWriteFailure(e, '读取分类引用');
      return;
    }
    if (!mounted) return;
    final bool ok = await _confirm(
      title: '归档「${category.name}」？',
      message: used > 0
          ? '它下面有 $used 笔账单，归档后不会再出现在新建账单里，历史账单照常显示。'
          : '归档后不会再出现在新建账单里，可以随时恢复。',
      confirmLabel: '归档',
    );
    if (!ok) return;
    if (!await _runWrite('归档分类', () => _actions.archive(category.id))) {
      return;
    }
    if (mounted) {
      showToonSuccess(context, '已归档「${category.name}」');
    }
  }

  Future<void> _restore(Category category) async {
    if (!await _runWrite('恢复分类', () => _actions.unarchive(category.id))) {
      return;
    }
    if (mounted) {
      showToonSuccess(context, '已恢复「${category.name}」');
    }
  }

  /// 删除：先看引用与子分类，决定「直接删 / 归档 / 迁移后删」。
  Future<void> _remove(Category category, List<Category> all) async {
    final int used;
    try {
      used = await _actions.countTransactions(category.id);
    } catch (e) {
      _showWriteFailure(e, '读取分类引用');
      return;
    }
    final int kids = all
        .where((Category c) => c.parentId == category.id && c.deletedAt == null)
        .length;
    if (!mounted) return;

    if (used == 0 && kids == 0) {
      if (!await _runWrite(
        '删除分类',
        () => _actions.deleteIfUnused(category.id),
      )) {
        return;
      }
      if (mounted) {
        showToonUndo(
          context,
          '已删除「${category.name}」',
          onUndo: () async {
            final bool ok;
            try {
              ok = await _actions.undoDelete(category.id);
            } catch (e) {
              _showWriteFailure(e, '撤销删除');
              return;
            }
            if (mounted) {
              ok
                  ? showToonSuccess(context, '已恢复「${category.name}」')
                  : showToonError(context, '无法恢复：父分类已删除');
            }
          },
        );
      }
      return;
    }

    // 有引用 / 有子分类：给「归档」或「迁移后删」两条路
    final _RemoveChoice? choice = await showDialog<_RemoveChoice>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text('「${category.name}」还在使用'),
        content: Text(
          <String>[
            if (used > 0) '有 $used 笔账单挂在它（含子分类）下面',
            if (kids > 0) '还有 $kids 个子分类',
            '直接删除会让这些账单失去分类，请选择处理方式。',
          ].join('；'),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(_RemoveChoice.migrate),
            child: const Text('迁移账单后删除'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(_RemoveChoice.archive),
            child: const Text('归档（保留历史）'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == _RemoveChoice.archive) {
      if (!await _runWrite('归档分类', () => _actions.archive(category.id))) {
        return;
      }
      if (mounted) {
        showToonSuccess(context, '已归档「${category.name}」');
      }
      return;
    }
    await _migrateAndDelete(category, all);
  }

  Future<void> _migrateAndDelete(Category category, List<Category> all) async {
    final List<String> blocked = <String>[
      category.id,
      for (final Category c in all)
        if (c.parentId == category.id) c.id,
    ];
    final List<Category> targets =
        all
            .where(
              (Category c) =>
                  c.kind == category.kind &&
                  c.isArchived == 0 &&
                  c.deletedAt == null &&
                  !blocked.contains(c.id),
            )
            .toList()
          ..sort(_bySort);
    if (targets.isEmpty) {
      _toast('没有可迁移的目标分类，请先新建一个');
      return;
    }
    final Category? target = await showModalBottomSheet<Category>(
      context: context,
      backgroundColor: context.toon.paper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Tok.rXl)),
      ),
      // 内容用线性布局 Column（任务书要求）；矮屏可滚动，不溢出。
      builder: (BuildContext sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '把账单迁到哪个分类？',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              for (final Category c in targets)
                _SheetTile(
                  icon: categoryIconData(c.icon, kind: c.kind),
                  label: c.name,
                  onTap: () => Navigator.of(sheetContext).pop(c),
                ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
    if (target == null || !mounted) return;
    final int moved;
    try {
      moved = await _actions.migrateAndDelete(category.id, target.id);
    } catch (e) {
      _showWriteFailure(e, '迁移并删除分类');
      return;
    }
    if (mounted) {
      showToonSuccess(
        context,
        '已把 $moved 笔账单迁到「${target.name}」并删除原分类',
      );
    }
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
    bool danger = false,
  }) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: danger
                ? FilledButton.styleFrom(
                    backgroundColor: context.toon.redTint,
                    foregroundColor: context.toon.redInk,
                  )
                : null,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

enum _RemoveChoice { archive, migrate }

// ────────────────────────────── 列表行 ──────────────────────────────

class _CategoryGroup extends StatelessWidget {
  const _CategoryGroup({
    required this.root,
    required this.children,
    required this.expanded,
    required this.onAddChild,
    required this.onToggle,
    required this.onMore,
  });

  final Category root;
  final List<Category> children;
  final bool expanded;
  final void Function(Category) onAddChild;
  final VoidCallback onToggle;
  final void Function(Category) onMore;

  @override
  Widget build(BuildContext context) {
    return ToonCard(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _CategoryTile(
            category: root,
            subtitle: children.isEmpty ? null : '${children.length} 个二级分类',
            // 所有根分类都走 Collapse：展开区至少有「添加」块（编辑在 ActionSheet 里）
            onTap: onToggle,
            showChevron: true,
            expanded: expanded,
            onMore: () => onMore(root),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeInOut,
            alignment: Alignment.topCenter,
            child: expanded
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(32, 2, 12, 12),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[
                        for (final Category child in children)
                          _ChildBlock(
                            category: child,
                            onTap: () => onMore(child),
                          ),
                        _AddBlock(onTap: () => onAddChild(root)),
                      ],
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

/// 二级分类块：块状分类项（非 Chip / 胶囊）—— 纸底 + 发丝描边，
/// 分类色只落在图标小方块上；点击开 ActionSheet。
class _ChildBlock extends StatelessWidget {
  const _ChildBlock({required this.category, required this.onTap});

  final Category category;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    final Color bg = categoryColor(p, category.color, kind: category.kind);
    final Color fg = categoryOnColor(p, category.color, kind: category.kind);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Tok.rMd),
      child: Container(
        // 块状：上下结构（图标方块 + 名称），宽度由内容决定，Wrap 负责流式换行。
        constraints: const BoxConstraints(minWidth: 76),
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 9),
        decoration: BoxDecoration(
          color: p.canvas,
          border: Border.all(color: p.line),
          borderRadius: BorderRadius.circular(Tok.rMd),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(Tok.rSm),
              ),
              child: Icon(
                categoryIconData(category.icon, kind: category.kind),
                size: 17,
                color: fg,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              category.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: p.ink,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 「添加」块：与 [_ChildBlock] 同构（同尺寸 / 同描边），挂在子分类网格末尾，
/// 让每个展开的一级分类都有可对齐的添加入口；点击直接进编辑器并预置父分类。
class _AddBlock extends StatelessWidget {
  const _AddBlock({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Tok.rMd),
      child: Container(
        constraints: const BoxConstraints(minWidth: 76),
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 9),
        decoration: BoxDecoration(
          color: p.canvas,
          border: Border.all(color: p.line),
          borderRadius: BorderRadius.circular(Tok.rMd),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: p.canvas2,
                borderRadius: BorderRadius.circular(Tok.rSm),
              ),
              child: Icon(Icons.add_rounded, size: 19, color: p.ink2),
            ),
            const SizedBox(height: 5),
            Text(
              '添加',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: p.ink2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile({
    required this.category,
    required this.onTap,
    required this.onMore,
    this.subtitle,
    this.showChevron = false,
    this.expanded = false,
  });

  final Category category;
  final VoidCallback onTap;
  final VoidCallback onMore;
  final String? subtitle;
  final bool showChevron;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    final Color bg = categoryColor(p, category.color, kind: category.kind);
    final Color fg = categoryOnColor(p, category.color, kind: category.kind);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Tok.rSm),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        child: Row(
          children: <Widget>[
            if (showChevron)
              AnimatedRotation(
                turns: expanded ? 0.5 : 0,
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeInOut,
                child: Icon(Icons.expand_more_rounded, size: 22, color: p.ink3),
              ),
            if (showChevron) const SizedBox(width: 4),
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(Tok.rMd),
              ),
              child: Icon(
                categoryIconData(category.icon, kind: category.kind),
                size: 20,
                color: fg,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Flexible(
                        child: Text(
                          category.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (category.isPreset == 1) ...<Widget>[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: p.canvas2,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            '预置',
                            style: TextStyle(
                              fontSize: 9.5,
                              fontWeight: FontWeight.w600,
                              color: p.ink3,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: p.ink3,
                      ),
                    ),
                ],
              ),
            ),
            IconButton(
              tooltip: '更多操作',
              onPressed: onMore,
              icon: Icon(Icons.more_horiz_rounded, size: 20, color: p.ink3),
            ),
          ],
        ),
      ),
    );
  }
}

/// 底部面板里的一行（ActionSheet 的操作行 / 父分类选择行共用）。
///
/// 刻意不用 `ListTile`：面板内容统一是线性布局 `Column`（任务书要求），
/// 自己铺 `Row` 好控制行高（48）与危险色，也不受 `ListTile` 固定内边距的干扰。
class _SheetTile extends StatelessWidget {
  const _SheetTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    final Color color = danger ? p.redInk : p.ink;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 22, color: danger ? p.redInk : p.ink2),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ArchivedRow extends StatelessWidget {
  const _ArchivedRow({
    required this.category,
    required this.onRestore,
    required this.onDelete,
  });

  final Category category;
  final VoidCallback onRestore;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: <Widget>[
          Icon(Icons.inventory_2_outlined, size: 18, color: p.ink3),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              category.name,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: p.ink2,
              ),
            ),
          ),
          TextButton(onPressed: onRestore, child: const Text('恢复')),
          TextButton(
            onPressed: onDelete,
            style: TextButton.styleFrom(foregroundColor: p.redInk),
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.category_outlined, size: 48, color: p.ink3),
            const SizedBox(height: 12),
            Text(
              '还没有分类',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: p.ink,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '先建一个常用的支出分类，记账时就能直接选。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: p.ink2),
            ),
            const SizedBox(height: 16),
            ToonButton(
              icon: Icons.add_rounded,
              label: '新建分类',
              onPressed: onCreate,
            ),
          ],
        ),
      ),
    );
  }
}
