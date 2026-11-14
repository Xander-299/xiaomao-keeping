/// 新增 / 编辑分类弹层（名称、类型、父分类、图标 / 颜色入口）。
///
/// 尺寸约定（2026-10-29 任务书）：
/// - 本体 = `showModalBottomSheet`，占屏幕高度 **30%**（`kCategoryEditorHeightFactor`）；
/// - 图标 / 颜色不在这里铺开 —— 点图标预览后另开 **60%** 的
///   [`showCategoryIconSheet`](category_icon_sheet.dart)（见 `kCategoryIconSheetHeightFactor`）。
///
/// 因为只有 30%，内部结构按「固定头 / 可滚动表单 / 固定按钮」三段排：
/// 抓手 + 标题固定在上，`Expanded` 里滚表单，保存 / 取消钉在底部（矮屏也点得到）。
///
/// 校验在仓储层（`CategoryException`，中文文案），这里只负责展示与回显；
/// 所有写操作走 [CategoryActions]，UI 不直接碰数据库。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:yanxin/core/constants/category_icons.dart';
import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/core/theme/tokens.dart';
import 'package:yanxin/core/theme/toon.dart';
import 'package:yanxin/data/providers/category_providers.dart';
import 'package:yanxin/features/shared/write_failure.dart';

import '../../application/category_actions.dart';
import 'category_icon_sheet.dart';

/// 分类编辑弹层占屏比例（任务书：30%）。
const double kCategoryEditorHeightFactor = 0.30;

/// 打开分类编辑弹层；保存成功返回 true。
Future<bool?> showCategoryEditor(
  BuildContext context, {
  required String bookId,
  required String kind,
  Category? editing,
  String? initialParentId,
}) {
  final ToonPalette p = context.toon;
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: p.paper,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(Tok.rXl)),
    ),
    builder: (BuildContext sheetContext) {
      final MediaQueryData mq = MediaQuery.of(sheetContext);
      return Padding(
        // 键盘弹起时整块面板让出键盘高度（面板自身仍是 30%，不会压到输入框）。
        padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
        child: SizedBox(
          // 测试用固定 key：断言「占屏幕 30%」时直接量这块的高度。
          key: const ValueKey<String>('category-editor-sheet'),
          height: mq.size.height * kCategoryEditorHeightFactor,
          // 手势条 / 导航栏挡住底部按钮：SafeArea 只吃底边（键盘弹起时它自动为 0）。
          child: SafeArea(
            top: false,
            child: _CategoryEditor(
              bookId: bookId,
              kind: kind,
              editing: editing,
              initialParentId: initialParentId,
            ),
          ),
        ),
      );
    },
  );
}

class _CategoryEditor extends ConsumerStatefulWidget {
  const _CategoryEditor({
    required this.bookId,
    required this.kind,
    this.editing,
    this.initialParentId,
  });

  final String bookId;
  final String kind;
  final Category? editing;
  final String? initialParentId;

  @override
  ConsumerState<_CategoryEditor> createState() => _CategoryEditorState();
}

class _CategoryEditorState extends ConsumerState<_CategoryEditor> {
  late final TextEditingController _name = TextEditingController(
    text: widget.editing?.name ?? '',
  );
  late String _kind = widget.editing?.kind ?? widget.kind;
  late String _icon = widget.editing?.icon ?? '';
  late String _color = widget.editing?.color ?? '';
  late String? _parentId = widget.editing?.parentId ?? widget.initialParentId;
  bool _saving = false;
  String? _error;

  bool get _isEditing => widget.editing != null;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  List<Category> _parents(List<Category> all) => all
      .where(
        (Category c) =>
            c.kind == _kind &&
            c.parentId == null &&
            c.id != widget.editing?.id &&
            c.isArchived == 0,
      )
      .toList();

  Future<void> _save(List<Category> all) async {
    final String name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '分类名称不能为空');
      return;
    }
    if (_isEditing && _parentId != widget.editing!.parentId) {
      final bool hasKids = all.any((Category c) => c.parentId == widget.editing!.id);
      if (hasKids) {
        setState(() => _error = '这个分类下还有子分类，不能改成二级分类');
        return;
      }
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    final CategoryActions actions = ref.read(categoryActionsProvider);
    try {
      if (_isEditing) {
        await actions.update(
          widget.editing!.id,
          name: name,
          icon: _icon,
          color: _color,
          parentId: _parentId,
          changeParent: _parentId != widget.editing!.parentId,
        );
      } else {
        await actions.create(
          bookId: widget.bookId,
          name: name,
          kind: _kind,
          parentId: _parentId,
          icon: _icon,
          color: _color,
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      // CategoryException 由 writeFailureMessage 保留业务 message；
      // 数据库/磁盘等非预期异常统一成「保存分类失败」，不暴露 $e。
      if (mounted) {
        setState(() {
          _saving = false;
          _error = writeFailureMessage(e, action: '保存分类');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    final List<Category> all = ref.watch(categoriesProvider).value ?? const <Category>[];
    final List<Category> parents = _parents(all);
    final Category? parent = _parentId == null
        ? null
        : all.where((Category c) => c.id == _parentId).firstOrNull;

    return Column(
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
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              _isEditing ? '编辑分类' : '新建分类',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                // 图标预览（点开 60% 的图标 / 颜色弹层）+ 名称
                Row(
                  children: <Widget>[
                    _IconPreview(
                      background: categoryColor(p, _color, kind: _kind),
                      foreground: categoryOnColor(p, _color, kind: _kind),
                      icon: categoryIconData(_icon, kind: _kind),
                      onTap: _saving ? null : _openIconSheet,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _name,
                        autofocus: !_isEditing,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _save(all),
                        maxLength: 12,
                        style: const TextStyle(fontSize: 15),
                        decoration: const InputDecoration(
                          labelText: '分类名称',
                          counterText: '',
                          hintText: '例如：早餐、打车、房租',
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                // 类型（编辑时不可改：历史账单都挂在原方向上）+ 父分类
                Row(
                  children: <Widget>[
                    if (!_isEditing) ...<Widget>[
                      ToonSeg(
                        small: true,
                        labels: const <String>['支出', '收入'],
                        index: _kind == 'income' ? 1 : 0,
                        onChanged: (int i) => setState(() {
                          _kind = i == 1 ? 'income' : 'expense';
                          _parentId = null; // 换方向后父分类不再适用
                        }),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: _ParentField(
                        label: parent?.name ?? '无（一级分类）',
                        onTap: _saving ? null : () => _pickParent(parents),
                      ),
                    ),
                  ],
                ),
                if (_error != null) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: p.redInk,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 6, 20, 12),
          child: Row(
            children: <Widget>[
              Expanded(
                child: ToonButton(
                  label: '取消',
                  kind: ToonButtonKind.ghost,
                  onPressed: _saving ? null : () => Navigator.of(context).pop(),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: ToonButton(
                  label: _saving ? '保存中…' : '保存',
                  onPressed: _saving ? null : () => _save(all),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 打开图标 / 颜色弹层（占屏 60%），选中即时回写预览。
  Future<void> _openIconSheet() async {
    await showCategoryIconSheet(
      context,
      kind: _kind,
      icon: _icon,
      color: _color,
      onChanged: (CategoryStylePick picked) {
        if (!mounted) return;
        setState(() {
          _icon = picked.icon;
          _color = picked.color;
        });
      },
    );
  }

  Future<void> _pickParent(List<Category> parents) async {
    final ToonPalette p = context.toon;
    // '' = 明确选了「无（一级分类）」；null = 用户直接关掉弹层（不改）
    final String? picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: p.paper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Tok.rXl)),
      ),
      builder: (BuildContext sheetContext) => SafeArea(
        // 内容用线性布局 Column（任务书要求）；矮屏可滚动，不溢出。
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
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '父分类',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: p.ink,
                    ),
                  ),
                ),
              ),
              _SheetRow(
                leading: Icon(
                  Icons.remove_circle_outline_rounded,
                  size: 22,
                  color: p.ink2,
                ),
                label: '无（一级分类）',
                onTap: () => Navigator.of(sheetContext).pop(''),
              ),
              for (final Category c in parents)
                _SheetRow(
                  leading: Icon(
                    categoryIconData(c.icon, kind: c.kind),
                    size: 22,
                    color: p.ink2,
                  ),
                  label: c.name,
                  onTap: () => Navigator.of(sheetContext).pop(c.id),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    if (!mounted || picked == null) return;
    setState(() => _parentId = picked.isEmpty ? null : picked);
  }
}

/// 图标预览方块：点按 → 打开 60% 的图标 / 颜色弹层。
class _IconPreview extends StatelessWidget {
  const _IconPreview({
    required this.background,
    required this.foreground,
    required this.icon,
    required this.onTap,
  });

  final Color background;
  final Color foreground;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    return Tooltip(
      message: '选择图标和颜色',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Tok.rMd),
        child: SizedBox(
          width: 48,
          height: 48,
          child: Stack(
            children: <Widget>[
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: background,
                  borderRadius: BorderRadius.circular(Tok.rMd),
                ),
                child: Icon(
                  icon,
                  key: const ValueKey<String>('category-icon-preview'),
                  size: 24,
                  color: foreground,
                ),
              ),
              // 右下角小铅笔：暗示「这块能点开改」
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  width: 17,
                  height: 17,
                  decoration: BoxDecoration(
                    color: p.paper,
                    shape: BoxShape.circle,
                    border: Border.all(color: p.line),
                  ),
                  child: Icon(Icons.edit_rounded, size: 10, color: p.ink3),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 父分类选择行（紧凑一行，替代原来的整块 ListTile）。
class _ParentField extends StatelessWidget {
  const _ParentField({required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    return Material(
      color: p.canvas2,
      borderRadius: BorderRadius.circular(Tok.rMd),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          child: Row(
            children: <Widget>[
              Icon(Icons.account_tree_outlined, size: 16, color: p.ink3),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: p.ink2,
                  ),
                ),
              ),
              Icon(Icons.expand_more_rounded, size: 16, color: p.ink3),
            ],
          ),
        ),
      ),
    );
  }
}

/// 底部面板里的一行（父分类选择等）：图标 + 文字 + 可点。
class _SheetRow extends StatelessWidget {
  const _SheetRow({
    required this.leading,
    required this.label,
    required this.onTap,
  });

  final Widget leading;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: <Widget>[
            leading,
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: p.ink,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
