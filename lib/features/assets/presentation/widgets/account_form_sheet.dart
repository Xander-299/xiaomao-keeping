/// 账户新增 / 编辑底部弹窗。
///
/// - 新增：名称 + 类型 + 初始余额（元，最多两位小数，不允许负数，见 SPEC §7）
/// - 编辑：同上，另加红色「删除账户」（**账户下有流水时禁止删除**）
/// 保存 / 删除成功后由 controller bump 数据版本号 → 资产页自动重算。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:yanxin/core/constants/preset.dart';
import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/core/theme/tokens.dart';
import 'package:yanxin/core/theme/toon.dart';
import 'package:yanxin/core/utils/money.dart';
import 'package:yanxin/ui_kit/app_sheet_header.dart';

import '../../application/account_meta.dart';
import '../../application/asset_aggregate.dart';
import '../../application/assets_controller.dart';

part 'account_form_sheet/form_chips.dart';
part 'account_form_sheet/form_fields.dart';

/// 打开账户表单弹窗。[account] 为空 = 新增，否则 = 编辑。
Future<void> showAccountFormSheet(
  BuildContext context,
  WidgetRef ref, {
  Account? account,
}) {
  final ToonPalette p = context.toon;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: p.paper,
    shape: RoundedRectangleBorder(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(Tok.rXl)),
      side: BorderSide(color: p.ink, width: Tok.bw),
    ),
    builder: (BuildContext _) => _AccountFormSheet(account: account),
  );
}

class _AccountFormSheet extends ConsumerStatefulWidget {
  const _AccountFormSheet({this.account});

  final Account? account;

  @override
  ConsumerState<_AccountFormSheet> createState() => _AccountFormSheetState();
}

class _AccountFormSheetState extends ConsumerState<_AccountFormSheet> {
  late final TextEditingController _name;
  late final TextEditingController _balance;
  late String _type;
  // 自选图标 / 颜色（null = 跟随账户类型，存库时落空串）。
  String? _icon;
  String? _color;
  String? _error;
  bool _busy = false;

  bool get _isEdit => widget.account != null;

  @override
  void initState() {
    super.initState();
    final Account? a = widget.account;
    _name = TextEditingController(text: a?.name ?? '');
    _type = a?.type ?? 'cash';
    // 回填自选值：空串 / 不在候选集 / 非法 hex → 一律视为「跟随类型」。
    _icon = a != null && kAccountIcons.containsKey(a.icon) ? a.icon : null;
    final Color? savedColor = parseHexColor(a?.color);
    _color = savedColor == null ? null : colorToHex(savedColor);
    // 回填金额：1000.00 → 1000（去掉无意义的 .00，方便直接改）
    _balance = TextEditingController(
      text: (a?.initialBalanceCents ?? 0) > 0
          ? centsToYuan(a!.initialBalanceCents)
                .replaceFirst(RegExp(r'\.00$'), '')
          : '',
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _balance.dispose();
    super.dispose();
  }

  /// 解析初始余额（分）。空串 = 0；格式非法抛 [FormatException]。
  int _parseBalanceCents() {
    final String raw = _balance.text.trim();
    if (raw.isEmpty) return 0;
    return yuanToCents(raw);
  }

  Future<void> _save() async {
    if (_busy) return;
    final String name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '请输入账户名称');
      return;
    }
    final int cents;
    try {
      cents = _parseBalanceCents();
    } on FormatException {
      setState(() => _error = '初始余额格式不对，最多两位小数');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    // pop 之后 widget 会销毁，这两个要先取出来
    final NavigatorState navigator = Navigator.of(context);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      final Account? a = widget.account;
      if (a == null) {
        await ref
            .read(assetsProvider.notifier)
            .addAccount(
              name: name,
              type: _type,
              initialBalanceCents: cents,
              icon: _icon ?? '',
              color: _color ?? '',
            );
      } else {
        await ref
            .read(assetsProvider.notifier)
            .updateAccount(
              a.id,
              name: name,
              type: _type,
              initialBalanceCents: cents,
              icon: _icon ?? '',
              color: _color ?? '',
            );
      }
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '保存失败：$e';
      });
      return;
    }
    if (!mounted) return;
    navigator.pop();
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(_isEdit ? '已保存「$name」' : '已新增「$name」'),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  Future<void> _delete() async {
    final Account? a = widget.account;
    if (_busy || a == null) return;

    // 有流水的账户不能删：删了会让这些流水指向不存在的账户
    final int txCount = ref.read(assetsProvider.notifier).txCountOf(a.id);
    if (txCount > 0) {
      await showDialog<void>(
        context: context,
        builder: (BuildContext dialogContext) => AlertDialog(
          title: const Text('删不了这个账户'),
          content: Text('「${a.name}」下还有 $txCount 笔流水，请先把这些流水改到别的账户。'),
          actions: <Widget>[
            ToonButton(
              label: '知道了',
              kind: ToonButtonKind.ghost,
              small: true,
              onPressed: () => Navigator.of(dialogContext).pop(),
            ),
          ],
        ),
      );
      return;
    }

    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('删除账户'),
        content: Text('删除「${a.name}」后不再计入净资产，确定删除？'),
        actions: <Widget>[
          ToonButton(
            label: '取消',
            kind: ToonButtonKind.ghost,
            small: true,
            onPressed: () => Navigator.of(dialogContext).pop(false),
          ),
          ToonButton(
            label: '删除',
            kind: ToonButtonKind.danger,
            small: true,
            onPressed: () => Navigator.of(dialogContext).pop(true),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _busy = true);
    final NavigatorState navigator = Navigator.of(context);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(assetsProvider.notifier).deleteAccount(a.id);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '删除失败：$e';
      });
      return;
    }
    if (!mounted) return;
    navigator.pop();
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('已删除「${a.name}」'),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    final Account? a = widget.account;
    final AssetItem? item = a == null
        ? null
        : ref.watch(assetsProvider).value?.itemOf(a.id);
    final int txCount = item?.txCount ?? 0;
    final int currentCents = item?.balanceCents ?? 0;
    final bool hasInput = _balance.text.trim().isNotEmpty;

    return Padding(
      // 键盘弹起时把内容顶上来
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                AppSheetHeader(
                  title: _isEdit ? '编辑账户' : '新增账户',
                  subtitle: '初始余额不允许负数；有流水的账户不可删除',
                ),
                const SizedBox(height: 16),

                const _FieldLabel('账户名称'),
                _BareInput(
                  child: TextField(
                    controller: _name,
                    autofocus: !_isEdit,
                    textInputAction: TextInputAction.next,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                    // 主题给输入框统一加了填充 + 描边 → 这里要裸输入框
                    decoration: const InputDecoration(
                      hintText: '例如：招商银行储蓄卡',
                      border: InputBorder.none,
                      filled: false,
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                      counterText: '',
                    ),
                  ),
                ),

                const SizedBox(height: 14),
                const _FieldLabel('图标'),
                // 自选图标只是装饰，不参与筛选 / 口径；null = 跟随账户类型。
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    _FollowTypeChip(
                      label: '跟随类型',
                      selected: _icon == null,
                      onTap: _busy ? null : () => setState(() => _icon = null),
                    ),
                    for (final MapEntry<String, IconData> e
                        in kAccountIcons.entries)
                      _IconOption(
                        key: ValueKey<String>('acct-icon-${e.key}'),
                        icon: e.value,
                        selected: _icon == e.key,
                        onTap: _busy
                            ? null
                            : () => setState(() => _icon = e.key),
                      ),
                  ],
                ),

                const SizedBox(height: 14),
                const _FieldLabel('颜色'),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    _FollowTypeChip(
                      label: '跟随类型',
                      selected: _color == null,
                      onTap: _busy ? null : () => setState(() => _color = null),
                    ),
                    for (final String hex in kAccountColors)
                      _ColorOption(
                        key: ValueKey<String>('acct-color-$hex'),
                        color: parseHexColor(hex)!,
                        selected: _color == hex,
                        onTap: _busy
                            ? null
                            : () => setState(() => _color = hex),
                      ),
                  ],
                ),

                const SizedBox(height: 14),
                const _FieldLabel('账户类型'),
                // 原型用 chips 选类型（不是下拉）；6 个类型实测两行放得下
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    for (final String t in accountTypes)
                      ToonChip(
                        key: ValueKey<String>('acct-type-$t'),
                        label: accountTypeLabel(t),
                        selected: _type == t,
                        onTap: _busy ? null : () => setState(() => _type = t),
                      ),
                  ],
                ),

                const SizedBox(height: 14),
                const _FieldLabel('初始余额（元）'),
                _BareInput(
                  child: Row(
                    children: <Widget>[
                      Text(
                        '¥',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          color: p.ink2,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _balance,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          inputFormatters: <TextInputFormatter>[
                            FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                          ],
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                          decoration: const InputDecoration(
                            hintText: '0.00',
                            border: InputBorder.none,
                            filled: false,
                            isDense: true,
                            contentPadding: EdgeInsets.zero,
                            counterText: '',
                          ),
                          onChanged: (_) => setState(() => _error = null),
                          onSubmitted: (_) => _save(),
                        ),
                      ),
                      if (hasInput)
                        ToonIconButton(
                          icon: Icons.close,
                          tooltip: '清空',
                          size: 30,
                          iconSize: 17,
                          onPressed: () => setState(() {
                            _balance.clear();
                            _error = null;
                          }),
                        ),
                    ],
                  ),
                ),

                if (_isEdit)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '当前余额 ¥${centsToYuan(currentCents, group: true)}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: p.ink2,
                      ),
                    ),
                  ),

                // 有流水 → 先摆出红底提示条（原型同款），省得点了删除才被拦
                if (txCount > 0)
                  Container(
                    margin: const EdgeInsets.only(top: 12),
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                    decoration: BoxDecoration(
                      color: p.redTint,
                      borderRadius: BorderRadius.circular(Tok.rSm),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Icon(Icons.info_outline, size: 18, color: p.red),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '该账户下有流水，需先把流水改绑到其它账户才能删除（还剩 $txCount 笔）',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: p.redInk,
                              height: 1.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: p.red,
                      ),
                    ),
                  ),

                const SizedBox(height: 18),
                Row(
                  children: <Widget>[
                    if (_isEdit)
                      ToonPress(
                        dx: 1.5,
                        dy: 1.5,
                        onTap: _busy ? null : _delete,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          child: Text(
                            '删除账户',
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w800,
                              color: p.red,
                            ),
                          ),
                        ),
                      ),
                    const Spacer(),
                    ToonButton(
                      label: '取消',
                      kind: ToonButtonKind.ghost,
                      small: true,
                      onPressed: _busy ? null : () => Navigator.of(context).pop(),
                    ),
                    const SizedBox(width: 8),
                    ToonButton(
                      label: '保存',
                      small: true,
                      onPressed: _busy ? null : _save,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
