/// 记一笔 / 编辑流水。
///
/// 对应旧栈 `pages/record/edit.vue`：支出/收入切换 + 金额键盘 + 分类 + 备注。
/// 编辑模式由路由 extra 传入流水 id。
///
/// 性能约定：分类列表 watch 已缓存的 `categoriesProvider`（首页加载时就绪），
/// push 首帧即渲染完整页面——**不允许**再加 initState 异步门闩（spinner→二次
/// build 会在转场动画中途换内容，肉眼可见卡顿）；编辑模式的流水详情异步填充。
///
/// F7.7 A.0：新增第 4 个字段「账户」（默认仍是账户列表首个，老行为不变）。
///
/// F7.9：保存入口**只留底部一处**（原 AppBar 右上角「保存」已移除）—— 底部按钮改为
/// **吸底常驻**（`Column` + `Expanded` 包滚动区，按钮不随内容滚走），于是「大屏 / 横屏下
/// 主按钮被折叠到视口外」的兜底理由不再成立，顶部冗余入口即可删掉。
/// 吸底栏放在 **body 内**而非 `Scaffold.bottomNavigationBar`：后者按 `size.height - h`
/// 贴屏幕底、**不随键盘上移**（会被键盘盖住）；而 body 会被 `viewInsets.bottom` 压缩，
/// 吸底栏自然落到键盘上方。细节见 `docs/spec/SPEC-F7.9-record-sticky-save.md`。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/core/providers/data_epoch.dart';
import 'package:yanxin/core/theme/tokens.dart';
import 'package:yanxin/core/theme/toon.dart';
import 'package:yanxin/core/utils/date.dart';
import 'package:yanxin/core/utils/money.dart';
import 'package:yanxin/data/providers/account_providers.dart';
import 'package:yanxin/data/providers/book_providers.dart';
import 'package:yanxin/data/providers/category_providers.dart';
import 'package:yanxin/data/providers/database.dart';
import 'package:yanxin/features/calendar/application/calendar_controller.dart';
import 'package:yanxin/features/ledger/application/ledger_controller.dart';
import 'package:yanxin/features/shared/write_failure.dart';
import 'package:yanxin/features/stats/application/stats_controller.dart';

import '../application/amount_input.dart';
import 'widgets/account_picker_sheet.dart';
import 'widgets/amount_keyboard.dart';
import 'widgets/category_picker.dart';
import 'widgets/date_picker_sheet.dart';

/// 记一笔页。[txId] 非空时为编辑模式。
///
/// [occurredAtMs] 为新建时的默认发生时间（日历页按选中日期带入）；
/// 为空取「现在」。
class RecordPage extends ConsumerStatefulWidget {
  const RecordPage({super.key, this.txId, this.occurredAtMs});

  /// 待编辑的流水 id；为空则新建。
  final String? txId;

  /// 新建时的默认发生时间（毫秒）；为空取当前时间。
  final int? occurredAtMs;

  @override
  ConsumerState<RecordPage> createState() => _RecordPageState();
}

class _RecordPageState extends ConsumerState<RecordPage> {
  final TextEditingController _noteController = TextEditingController();
  String _type = 'expense';
  String _amount = '';
  String? _categoryId;

  /// 所选账户 id；为空 = 沿用账户列表首个（老行为不变）。
  String? _accountId;
  late int _occurredAtMs;
  bool _saving = false;

  bool get _isEdit => widget.txId != null;

  @override
  void initState() {
    super.initState();
    _occurredAtMs =
        widget.occurredAtMs ?? DateTime.now().millisecondsSinceEpoch;
    // 仅编辑模式需要补流水详情；分类数据走缓存 provider，不挡首帧
    if (_isEdit) {
      unawaited(_loadTx());
    }
  }

  Future<void> _loadTx() async {
    final tx = await ref
        .read(transactionRepositoryProvider)
        .getById(widget.txId!);
    if (!mounted || tx == null) return;
    setState(() {
      _type = tx.type;
      _amount = centsToYuan(tx.amountCents);
      _noteController.text = tx.note;
      _categoryId = tx.categoryId;
      _accountId = tx.accountId;
      _occurredAtMs = tx.occurredAt;
    });
  }

  /// 选日期（上限为今天：未来月份首页翻不过去，记未来账会「看不见」）。
  ///
  /// F7.6 P3 起走自绘卡通弹层（原型 `ovlDate`），不再是 Material `showDatePicker`。
  Future<void> _pickDate() async {
    final DateTime initial = DateTime.fromMillisecondsSinceEpoch(_occurredAtMs);
    final DateTime? picked = await showDatePickerSheet(
      context,
      initial: initial,
    );
    if (picked == null || !mounted) return;
    setState(() {
      // 保留原有时分秒，只换年月日
      _occurredAtMs = DateTime(
        picked.year,
        picked.month,
        picked.day,
        initial.hour,
        initial.minute,
        initial.second,
      ).millisecondsSinceEpoch;
    });
  }

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  Category? _selectedCategory(List<Category> categories) {
    for (final c in categories) {
      if (c.id == _categoryId) return c;
    }
    return null;
  }

  /// 当前生效的账户：显式选过就用选的，否则沿用列表首个。
  ///
  /// 选过的账户若已不存在（被软删）也退回首个 —— `transactions.account_id`
  /// 是 NOT NULL，保存时必须给一个**存在**的账户。
  Account? _effectiveAccount(List<Account> accounts) {
    if (accounts.isEmpty) return null;
    for (final Account a in accounts) {
      if (a.id == _accountId) return a;
    }
    return accounts.first;
  }

  /// 选分类。弹层内部可切支出/收入，故传全量分类，并以选中项的 kind 回写类型。
  Future<void> _pickCategory(List<Category> all) async {
    final picked = await showCategoryPicker(
      context,
      categories: all,
      kind: _type,
      selectedId: _categoryId,
    );
    if (picked == null) return;
    setState(() {
      _categoryId = picked.id;
      _type = picked.kind;
    });
  }

  /// 选账户（F7.7 A.0）。
  Future<void> _pickAccount(List<Account> accounts) async {
    if (accounts.isEmpty) {
      showToonError(context, '账本无账户');
      return;
    }
    final Account? picked = await showAccountPicker(
      context,
      accounts: accounts,
      selectedId: _effectiveAccount(accounts)?.id,
    );
    if (picked == null || !mounted) return;
    setState(() => _accountId = picked.id);
  }

  Future<void> _save() async {
    if (!isParsableAmount(_amount) || yuanToCents(_amount) <= 0) {
      showToonError(context, '请输入金额');
      return;
    }
    if (_categoryId == null) {
      showToonError(context, '请选择分类');
      return;
    }
    final String? bookId;
    try {
      bookId = await ref.read(activeBookIdProvider.future);
    } catch (e) {
      if (!mounted) return;
      showToonError(context, writeFailureMessage(e, action: '读取账本'));
      return;
    }
    if (bookId == null) {
      if (!mounted) return;
      showToonError(context, '账本未就绪，无法保存');
      return;
    }
    final List<Account> accounts;
    try {
      accounts = await ref.read(accountsProvider.future);
    } catch (e) {
      if (!mounted) return;
      showToonError(context, writeFailureMessage(e, action: '读取账户'));
      return;
    }
    final Account? account = _effectiveAccount(accounts);
    if (account == null) {
      if (!mounted) return;
      showToonError(context, '账本无账户');
      return;
    }

    if (!mounted) return;
    setState(() => _saving = true);
    try {
      final repo = ref.read(transactionRepositoryProvider);
      final amountCents = yuanToCents(_amount);
      try {
        if (_isEdit) {
          await repo.update(
            widget.txId!,
            type: _type,
            categoryId: _categoryId,
            accountId: account.id,
            amountCents: amountCents,
            occurredAt: _occurredAtMs,
            note: _noteController.text.trim(),
          );
        } else {
          await repo.create(
            bookId: bookId,
            accountId: account.id,
            type: _type,
            categoryId: _categoryId,
            amountCents: amountCents,
            occurredAt: _occurredAtMs,
            note: _noteController.text.trim(),
          );
        }
      } catch (e) {
        // 数据库锁 / 磁盘 / Drift 等非业务异常：不 pop、不报成功，保留输入。
        if (mounted) {
          showToonError(context, writeFailureMessage(e, action: '保存'));
        }
        return;
      }
      // 刷新首页 / 日历（go_router push 的 Future 在壳路由下不兑现 .then，
      // 刷新必须在 pop 前由本页自己触发）
      if (ref.context.mounted) {
        unawaited(ref.read(ledgerProvider.notifier).refresh());
        unawaited(ref.read(calendarProvider.notifier).refresh());
        unawaited(ref.read(statsProvider.notifier).refresh());
        ref.invalidate(yearDayIndexProvider);
        // 资产页 watch 数据版本号，bump 即重算
        ref.read(dataEpochProvider.notifier).bump();
      }
      if (mounted) Navigator.of(context).pop(true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    // 首页加载时就已解析并缓存，push 首帧直接有数据；若真未就绪（冷启动直进
    // 编辑模式的极端情况），这一帧退化为轻量占位，provider 完成后自动重渲染
    final categories =
        ref.watch(categoriesProvider).value ?? const <Category>[];
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];
    final selected = _selectedCategory(categories);
    final selectedAccount = _effectiveAccount(accounts);

    return Scaffold(
      // F7.9：保存入口只留底部一处（原右上角「保存」已移除，见 SPEC-F7.9）
      appBar: AppBar(title: Text(_isEdit ? '编辑流水' : '记一笔')),
      body: SafeArea(
        // 原型这一页的 pbody 用 `--surface`（纯白），不是全局暖白画布
        child: Container(
          color: p.paper,
          child: Column(
            children: <Widget>[
              // 滚动区。吸底栏是它的**兄弟**节点 → 按钮不随内容滚走。
              // 外层用 Expanded 是因为键盘弹起时 body 会被压缩，吸底栏要跟着上移，
              // 只能让滚动区吃掉剩余高度。
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                  child: Column(
                    children: <Widget>[
                      Center(
                        child: ToonSeg(
                          labels: const <String>['支出', '收入'],
                          index: _type == 'income' ? 1 : 0,
                          onChanged: (int i) {
                            setState(() {
                              _type = i == 1 ? 'income' : 'expense';
                              // 切类型后原分类不再适用，清空让用户重选
                              final bool stillValid = categories.any(
                                (Category c) =>
                                    c.id == _categoryId && c.kind == _type,
                              );
                              if (!stillValid) _categoryId = null;
                            });
                          },
                        ),
                      ),
                      const SizedBox(height: 14),
                      AmountKeyboard(
                        value: _amount,
                        onKey: (String key) => setState(
                          () => _amount = applyAmountKey(_amount, key),
                        ),
                      ),
                      const SizedBox(height: 6),
                      ToonField(
                        label: '分类',
                        value: selected?.name ?? '请选择分类',
                        placeholder: selected == null,
                        onTap: () => _pickCategory(categories),
                        trailing: selected == null
                            ? null
                            : ToonAvatar(
                                text: selected.name.isEmpty
                                    ? '?'
                                    : selected.name.substring(0, 1),
                                small: true,
                                bg: _type == 'income'
                                    ? p.greenTint
                                    : p.redTint,
                                fg: _type == 'income' ? p.green : p.red,
                              ),
                      ),
                      ToonField(
                        label: '日期',
                        value: formatFullDay(
                          DateTime.fromMillisecondsSinceEpoch(_occurredAtMs),
                        ),
                        onTap: _pickDate,
                        dashedTop: true,
                      ),
                      ToonField(
                        label: '备注',
                        dashedTop: true,
                        child: TextField(
                          controller: _noteController,
                          style: const TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w700,
                          ),
                          // 原型这里是裸 input（`style="border:0"`）：必须逐项关掉主题的
                          // 填充 + 描边，否则 `InputDecoration.collapsed` 仍会吃到
                          // `inputDecorationTheme.filled` 渲染出一个白框。
                          decoration: InputDecoration(
                            hintText: '选填',
                            hintStyle: TextStyle(
                              color: p.ink3,
                              fontWeight: FontWeight.w600,
                            ),
                            filled: false,
                            isDense: true,
                            contentPadding: EdgeInsets.zero,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            errorBorder: InputBorder.none,
                            focusedErrorBorder: InputBorder.none,
                          ),
                        ),
                      ),
                      // F7.7 A.0：第 4 个字段「账户」；默认沿用列表首个（老行为不变）
                      ToonField(
                        label: '账户',
                        value: selectedAccount?.name ?? '请选择账户',
                        placeholder: selectedAccount == null,
                        onTap: () => _pickAccount(accounts),
                        dashedTop: true,
                        trailing: selectedAccount == null
                            ? null
                            : ToonAvatar(
                                text: selectedAccount.name.isEmpty
                                    ? '?'
                                    : selectedAccount.name.substring(0, 1),
                                small: true,
                              ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '保存后首页 / 日历 / 统计 / 资产同步刷新',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: p.ink2,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // F7.9 吸底保存栏：全页唯一的保存入口，常驻视口底部。
              // 顶部墨色描边与 AppBar 底边对称（同一 `Tok.bw`）。
              Container(
                decoration: BoxDecoration(
                  color: p.paper,
                  border: Border(
                    top: BorderSide(color: p.ink, width: Tok.bw),
                  ),
                ),
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: ToonButton(
                  label: _isEdit ? '保存修改' : '记一笔',
                  block: true,
                  onPressed: _saving ? null : _save,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
