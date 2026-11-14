/// 分类图标 / 颜色选择弹层（占屏幕高度 **60%**）。
///
/// 为什么要单独一层：分类编辑弹层本体只占 **30%** 屏高（任务书约定），
/// 43 个图标 + 9 个颜色铺不进去；点编辑层里的图标预览 → 另开这一层。
///
/// 交互取舍：
/// - 选中**即时回调**（[onChanged]），不靠 `pop` 返回值 —— 用户挑图标又要换颜色时
///   不必退出重进，且下滑关闭也不会丢已选结果；
/// - 弹层内容用线性布局 `Column`（任务书要求），图标 / 颜色两块各自 `Wrap` 流式换行。
library;

import 'package:flutter/material.dart';

import 'package:yanxin/core/constants/category_icons.dart';
import 'package:yanxin/core/theme/tokens.dart';
import 'package:yanxin/core/theme/toon.dart';

/// 图标 / 颜色弹层占屏比例。
const double kCategoryIconSheetHeightFactor = 0.60;

/// 一次「图标 + 颜色」选择结果（两者一起回传，避免只改一半）。
typedef CategoryStylePick = ({String icon, String color});

/// 打开图标 / 颜色选择弹层。
///
/// [onChanged] 在每次点选后立即回调（父层 `setState` 即可实时更新预览）。
Future<void> showCategoryIconSheet(
  BuildContext context, {
  required String kind,
  required String icon,
  required String color,
  required ValueChanged<CategoryStylePick> onChanged,
}) {
  final ToonPalette p = context.toon;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: p.paper,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(Tok.rXl)),
    ),
    builder: (BuildContext sheetContext) => SizedBox(
      // 测试用固定 key：断言「占屏幕 60%」时直接量这块的高度。
      key: const ValueKey<String>('category-icon-sheet'),
      height: MediaQuery.sizeOf(sheetContext).height *
          kCategoryIconSheetHeightFactor,
      // 手势条 / 导航栏区域不摆内容（只吃底边）。
      child: SafeArea(
        top: false,
        child: _CategoryIconSheet(
          kind: kind,
          icon: icon,
          color: color,
          onChanged: onChanged,
        ),
      ),
    ),
  );
}

class _CategoryIconSheet extends StatefulWidget {
  const _CategoryIconSheet({
    required this.kind,
    required this.icon,
    required this.color,
    required this.onChanged,
  });

  final String kind;
  final String icon;
  final String color;
  final ValueChanged<CategoryStylePick> onChanged;

  @override
  State<_CategoryIconSheet> createState() => _CategoryIconSheetState();
}

class _CategoryIconSheetState extends State<_CategoryIconSheet> {
  late String _icon = widget.icon;
  late String _color = widget.color;

  void _pick({String? icon, String? color}) {
    setState(() {
      if (icon != null) _icon = icon;
      if (color != null) _color = color;
    });
    widget.onChanged((icon: _icon, color: _color));
  }

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
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
          padding: const EdgeInsets.fromLTRB(20, 8, 8, 0),
          child: Row(
            children: <Widget>[
              const Text(
                '图标与颜色',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('完成'),
              ),
            ],
          ),
        ),
        // 图标区自己滚（43 个图标在 60% 里会超一屏），
        // 颜色行钉在底部常驻 —— 真机走查发现：两者挤在一个滚动区时，颜色会被压到
        // 屏幕最底边（贴着导航栏，没有留白），等于「看起来没有颜色可选」。
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('图标', style: _labelStyle(p)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    for (final String key in kCategoryIconKeys)
                      _IconCell(
                        icon: categoryIconData(key, kind: widget.kind),
                        selected: key == _icon,
                        onTap: () => _pick(icon: key),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        Divider(height: 1, color: p.line),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('颜色', style: _labelStyle(p)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: <Widget>[
                  for (final String hex in kCategoryColors)
                    _ColorCell(
                      color: parseHexColor(hex, p.brand),
                      checkColor: categoryOnColor(p, hex, kind: widget.kind),
                      selected: hex == _color,
                      onTap: () => _pick(color: hex),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  TextStyle _labelStyle(ToonPalette p) => TextStyle(
    fontSize: 12.5,
    fontWeight: FontWeight.w600,
    color: p.ink2,
  );
}

/// 一个图标格子（44×44，选中换品牌浅底 + 描边）。
class _IconCell extends StatelessWidget {
  const _IconCell({
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Tok.rSm),
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: selected ? p.brandTint : p.canvas2,
          borderRadius: BorderRadius.circular(Tok.rSm),
          border: Border.all(
            color: selected ? p.brandDeep : Colors.transparent,
            width: Tok.bw,
          ),
        ),
        child: Icon(
          icon,
          size: 22,
          color: selected ? p.brandInk : p.ink2,
        ),
      ),
    );
  }
}

/// 一个颜色圆点（34×34，选中加墨圈 + 对勾）。
class _ColorCell extends StatelessWidget {
  const _ColorCell({
    required this.color,
    required this.checkColor,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final Color checkColor;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? p.ink : Colors.transparent,
            width: Tok.bw,
          ),
        ),
        child: selected
            ? Icon(Icons.check_rounded, size: 17, color: checkColor)
            : null,
      ),
    );
  }
}
