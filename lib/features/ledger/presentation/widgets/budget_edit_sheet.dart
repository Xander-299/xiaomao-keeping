/// 「设置本月预算」底部弹窗（F7.6 P3 卡通化，对齐原型 `ovlBudget`）。
///
/// 就地设置，不新增路由：常用额度快捷键 + 金额输入 + 保存 / 删除。
/// 保存走 [MonthBudgetController]，成功后只刷新预算卡（不重查流水）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:yanxin/core/theme/tokens.dart';
import 'package:yanxin/core/theme/toon.dart';
import 'package:yanxin/core/utils/money.dart';
import 'package:yanxin/ui_kit/app_sheet_header.dart';

import '../../application/budget_controller.dart';
import '../../application/budget_metrics.dart';
import '../../application/ledger_controller.dart';

/// 常用额度快捷键（元）。
const List<int> kBudgetPresets = <int>[1000, 2000, 3000, 5000];

/// 弹出设置预算弹窗。[view] 用于回填当前预算与已消费。
Future<void> showBudgetEditSheet(
  BuildContext context,
  WidgetRef ref, {
  required BudgetView view,
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
    builder: (BuildContext _) => _BudgetEditSheet(
      initialCents: view.budgetCents,
      spentCents: view.spentCents,
    ),
  );
}

class _BudgetEditSheet extends ConsumerStatefulWidget {
  const _BudgetEditSheet({required this.initialCents, required this.spentCents});

  final int initialCents;

  /// 该月已消费（分），用于「当前 / 已消费」那行提示。
  final int spentCents;

  @override
  ConsumerState<_BudgetEditSheet> createState() => _BudgetEditSheetState();
}

class _BudgetEditSheetState extends ConsumerState<_BudgetEditSheet> {
  late final TextEditingController _controller;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // 回填：1000.00 → 1000（去掉无意义的 .00，方便直接改）
    final String prefill = widget.initialCents > 0
        ? centsToYuan(widget.initialCents).replaceFirst(RegExp(r'\.00$'), '')
        : '';
    _controller = TextEditingController(text: prefill);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 当前弹窗对应的月份（取首页真实状态，避免弹窗开着时首页翻月导致写错月份）。
  ({int year, int month}) _month() {
    final LedgerState? ledger = ref.read(ledgerProvider).value;
    final DateTime now = DateTime.now();
    return (
      year: ledger?.year ?? now.year,
      month: ledger?.month ?? now.month,
    );
  }

  Future<void> _save() async {
    if (_busy) return;
    final String raw = _controller.text.trim();
    if (raw.isEmpty) {
      setState(() => _error = '请输入预算金额');
      return;
    }
    final int cents;
    try {
      cents = yuanToCents(raw);
    } on FormatException {
      setState(() => _error = '金额格式不对，最多两位小数');
      return;
    }
    if (cents <= 0) {
      setState(() => _error = '金额要大于 0');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    // pop 之后 widget 会被销毁，月份与 Navigator 都要先取出来
    final int month = _month().month;
    final NavigatorState navigator = Navigator.of(context);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(monthBudgetProvider.notifier).setAmount(cents);
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
          content: Text('已设置$month月预算 ¥${centsToYuan(cents, group: true)}'),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  Future<void> _clear() async {
    if (_busy) return;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('删除本月预算'),
        content: const Text('删除后将不再跟踪本月预算进度，确定删除？'),
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
    try {
      await ref.read(monthBudgetProvider.notifier).clear();
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '删除失败：$e';
      });
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    final ({int year, int month}) ym = _month();
    final bool hasExisting = widget.initialCents > 0;
    final bool hasInput = _controller.text.trim().isNotEmpty;

    return Padding(
      // 键盘弹起时把内容顶上来
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              AppSheetHeader(
                title: '设置 ${ym.year}年${ym.month}月 预算',
                subtitle: '用于在首页看到本月花销进度与剩余额度',
              ),
              const SizedBox(height: 16),
              // ¥ 输入框（原型：墨色描边圆角 + 大号数字）
              Container(
                padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
                decoration: BoxDecoration(
                  color: p.paper,
                  borderRadius: BorderRadius.circular(Tok.rMd),
                  border: p.inkBorder(),
                ),
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
                        controller: _controller,
                        autofocus: true,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: <TextInputFormatter>[
                          FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                        ],
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                        // 主题给输入框统一加了填充 + 描边 → 这里要裸输入框
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
                          _controller.clear();
                          _error = null;
                        }),
                      ),
                  ],
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: p.red,
                    ),
                  ),
                ),
              if (hasExisting)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '当前：¥${centsToYuan(widget.initialCents, group: true)}'
                    ' · 已消费 ¥${centsToYuan(widget.spentCents, group: true)}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: p.ink2,
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final int preset in kBudgetPresets)
                    ToonChip(
                      label: '$preset',
                      selected: _controller.text.trim() == '$preset',
                      onTap: () => setState(() {
                        _controller.text = '$preset';
                        _error = null;
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                children: <Widget>[
                  if (hasExisting)
                    ToonPress(
                      dx: 1.5,
                      dy: 1.5,
                      onTap: _busy ? null : _clear,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        child: Text(
                          '删除预算',
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
              const SizedBox(height: 12),
              Text(
                '同一月份重复设置会走更新（部分唯一索引），不会产生两条记录。',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: p.ink2,
                  height: 1.6,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
