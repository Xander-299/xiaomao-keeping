/// 导入账单页：选文件 → 解析预览（可单条取消）→ 确认导入 → 结果报告。
///
/// F7.6 P3 按原型 `scrImport` 改为**三步页**（步骤条 + 虚线投放区 + 勾选列表 + 报告卡），
/// 报告由原来的 AlertDialog 变成第 3 步页面 —— 步骤条能把「现在到哪一步」说清楚。
///
/// [pickBytesOverride] 供测试注入文件字节（绕过平台文件选择器）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:yanxin/ui_kit/app_page_state.dart';

import '../../../core/platform/media_picker.dart';
import '../../../core/providers/data_epoch.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/theme/toon.dart';
import '../../../core/utils/money.dart';
import '../../../data/providers/book_providers.dart';
import '../../../data/providers/database.dart';
import '../../../data/repositories/account_repository.dart';
import '../../../data/repositories/category_repository.dart';
import '../../ledger/application/ledger_controller.dart';
import '../../ledger/presentation/dashboard/dashboard_config_controller.dart';
import '../../settings/application/theme_controller.dart';
import '../../stats/application/stats_controller.dart';
import '../application/backup_restore.dart';
import '../application/bill_importer.dart';
import '../data/bill_normalize.dart';
import '../data/bill_parse.dart';
import '../data/category_rules.dart';
import 'backup_settings_dialog.dart';

part 'widgets/import_step_bar.dart';
part 'widgets/import_pick_body.dart';
part 'widgets/import_row.dart';
part 'widgets/import_report_kv.dart';

class ImportPage extends ConsumerStatefulWidget {
  const ImportPage({super.key, this.pickBytesOverride});

  final Future<List<int>?> Function()? pickBytesOverride;

  @override
  ConsumerState<ImportPage> createState() => _ImportPageState();
}

class _ImportPageState extends ConsumerState<ImportPage> {
  bool _parsing = false;
  bool _importing = false;
  BillParseResult? _parsed;
  List<bool> _cancelled = const [];
  String? _fileName;

  // ── 备份文件（换机迁移）：命中即整体恢复，不走逐行预览 ──
  bool _isBackup = false;
  BackupRestoreReport? _backupReport;

  // ── 第 3 步（导入报告）的状态快照 ──
  ImportReport? _report;
  bool _hasNew = false;
  int _activeRows = 0;
  ({int year, int month})? _target;

  /// 当前步骤：有报告 = 3，有解析结果 = 2，否则 1。由数据推导，不额外存状态。
  int get _step => _report != null || _backupReport != null
      ? 3
      : (_parsed != null ? 2 : 1);

  void _resetToPick() {
    setState(() {
      _parsed = null;
      _cancelled = const <bool>[];
      _fileName = null;
      _report = null;
      _target = null;
      _isBackup = false;
      _backupReport = null;
    });
  }

  /// 第 1 步返回 = 退出页面；第 2 / 3 步返回 = 回到选文件（重来一遍）。
  void _back() {
    if (_step == 1) {
      context.pop();
    } else {
      _resetToPick();
    }
  }

  Future<void> _pickAndParse() async {
    setState(() {
      _parsing = true;
      _parsed = null;
      _fileName = null;
    });
    try {
      List<int>? bytes;
      String? name;
      if (widget.pickBytesOverride != null) {
        bytes = await widget.pickBytesOverride!();
      } else {
        // F8.1 起改走自家通道（SAF）：`file_picker` 在这台机器上点不出系统选择器
        // （真机实测 release 包 `pickFile()` 直接返回 null，见 core/platform/media_picker.dart）。
        final String? path = await ref.read(mediaPickerProvider).pickDocument();
        if (path != null && path.isNotEmpty) {
          bytes = await File(path).readAsBytes();
          name = path.split(Platform.pathSeparator).last;
        }
      }
      if (bytes == null || bytes.isEmpty) {
        if (mounted) setState(() => _parsing = false);
        return; // 用户取消选择
      }
      final ParseOutcome outcome = parseBillFileAuto(bytes);
      if (outcome is BackupOutcome) {
        // 备份文件：直接整体恢复（含账本/账户/分类/预算），成功后进报告步
        await _restoreBackup(bytes, name);
        return;
      }
      final BillParseResult parsed = (outcome as BillRowsOutcome).result;
      setState(() {
        _parsed = parsed;
        _cancelled = List<bool>.filled(parsed.rows.length, false);
        _fileName = name;
        _parsing = false;
      });
    } on FormatException catch (e) {
      if (!mounted) return;
      setState(() => _parsing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    } on MediaPickFailure catch (e) {
      if (!mounted) return;
      setState(() => _parsing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.userMessage)),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _parsing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('读取文件失败：$e')),
      );
    }
  }

  /// 恢复小耄记账备份（JSON）。恢复进当前账本，指纹去重保证幂等。
  Future<void> _restoreBackup(List<int> bytes, String? name) async {
    try {
      // 备份里带了外观 / 布局时先问一句：默认一并恢复（换机是最常见场景），
      // 但只把账并进来的用户不该被顺手换了主题。
      var restoreSettings = true;
      if (backupHasSettings(bytes)) {
        if (!mounted) return;
        restoreSettings = await askRestoreBackupSettings(context);
        if (!mounted) return;
      }
      final db = ref.read(appDatabaseProvider);
      final BackupRestoreReport report = await restoreBackupJson(
        db,
        bytes: bytes,
        createBook: false,
        restoreSettings: restoreSettings,
      );
      // 恢复改变了首页 / 统计 / 资产数据，全部主动刷新
      await ref.read(ledgerProvider.notifier).refresh();
      unawaited(ref.read(statsProvider.notifier).refresh());
      if (report.settingsRestored > 0) {
        // 设置是直接写库的，三个 AsyncNotifier 不会自己感知 —— 必须显式失效，
        // 否则「恢复完看着还是旧主题」，得杀进程才生效。
        ref.invalidate(themeSeedProvider);
        ref.invalidate(themeModeProvider);
        ref.invalidate(dashboardConfigProvider);
      }
      ref.read(dataEpochProvider.notifier).bump();
      if (!mounted) return;
      setState(() {
        _parsing = false;
        _isBackup = true;
        _backupReport = report;
        _fileName = name;
      });
    } on FormatException catch (e) {
      if (!mounted) return;
      setState(() => _parsing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _parsing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('备份恢复失败：$e')),
      );
    }
  }

  Future<void> _confirmImport() async {
    final parsed = _parsed;
    if (parsed == null || _importing) return;
    setState(() => _importing = true);
    try {
      // activeBookIdProvider 首次构建是真实异步读库，必须 await future
      final book = await ref.read(currentBookProvider.future);
      if (book == null) throw StateError('当前账本未就绪');
      final db = ref.read(appDatabaseProvider);
      final accountId = await ensureImportAccount(AccountRepository(db), book.id);
      final maps = await buildCategoryMaps(CategoryRepository(db), book.id);
      final report = await importRows(
        db,
        bookId: book.id,
        accountId: accountId,
        categoryMaps: maps,
        rows: parsed.rows,
        options: [
          for (final c in _cancelled) RowOption(cancelled: c),
        ],
      );
      // 导入改变了首页数据，主动刷新（go_router push 的 .then 在壳路由下不兑现）
      await ref.read(ledgerProvider.notifier).refresh();
      // 统计页是常驻 Notifier，也要跟着刷新（导入常落历史月，翻回去才看得到）
      unawaited(ref.read(statsProvider.notifier).refresh());
      // 资产页 watch 数据版本号，bump 即重算
      ref.read(dataEpochProvider.notifier).bump();
      if (!mounted) return;
      setState(() {
        _importing = false;
        _report = report;
        _hasNew = report.imported > 0;
        _activeRows = _cancelled.where((bool c) => !c).length;
        // 导入的账单几乎都属于历史月份，首页停在当前月会「看起来什么都没发生」
        // → 报告里说明数据落在哪个月，并给一个直达入口。
        _target = _latestMonthOf(parsed.rows, _cancelled);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _importing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败：$e')),
      );
    }
  }

  Future<void> _goToLedger() async {
    final target = _target;
    if (target == null) return;
    await ref
        .read(ledgerProvider.notifier)
        .jumpToMonth(target.year, target.month);
    if (!mounted) return;
    context.go('/');
  }

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    return Scaffold(
      backgroundColor: p.paper,
      appBar: AppBar(
        title: const Text('导入账单'),
        leading: BackButton(onPressed: _back),
      ),
      body: _parsing
          ? const AppPageLoading()
          : Column(
              children: <Widget>[
                _StepBar(step: _step),
                Expanded(
                  child: switch (_step) {
                    1 => _PickBody(onPick: _pickAndParse),
                    2 => _buildPreviewBody(context, _parsed!),
                    _ => _buildReportBody(context),
                  },
                ),
              ],
            ),
    );
  }

  // ────────────────────────────── 第 2 步：预览 ──────────────────────────────

  Widget _buildPreviewBody(BuildContext context, BillParseResult parsed) {
    final ToonPalette p = context.toon;
    final stats = parsed.stats;
    final int activeCount = _cancelled.where((bool c) => !c).length;
    final bool allSelected = activeCount == _cancelled.length;
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: ToonCard(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    const Text(
                      '解析结果',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _fileName ?? '账单文件',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: p.ink2,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '识别为「${parsed.source == 'wechat_csv' ? '微信支付' : '支付宝'}」账单',
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: <Widget>[
                    Text(
                      '可导入 $activeCount 笔',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        '已跳过 ${stats.skipped} 笔（退款 / 不计收支）'
                        '${stats.malformed > 0 ? ' · 坏行 ${stats.malformed}' : ''}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: p.ink2,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: <Widget>[
                    Icon(Icons.check_box_outlined, size: 16, color: p.ink2),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '勾选的条目会导入，点条目可取消它',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: p.ink2,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
          child: Row(
            children: <Widget>[
              Text(
                '已选 $activeCount / ${_cancelled.length} 条',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: p.ink2,
                ),
              ),
              const Spacer(),
              _LinkButton(
                label: allSelected ? '全不选' : '全选',
                onTap: () => setState(
                  () => _cancelled = List<bool>.filled(
                    _cancelled.length,
                    allSelected,
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ToonCard(
              padding: EdgeInsets.zero,
              clip: true,
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: parsed.rows.length,
                itemBuilder: (BuildContext context, int i) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    if (i > 0) const ToonDashedLine(),
                    _ImpRow(
                      index: i,
                      row: parsed.rows[i],
                      cancelled: _cancelled[i],
                      onToggle: () =>
                          setState(() => _cancelled[i] = !_cancelled[i]),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Opacity(
                  opacity: activeCount > 0 && !_importing ? 1 : 0.5,
                  child: ToonButton(
                    block: true,
                    label: _importing ? '导入中…' : '确认导入（$activeCount 笔）',
                    onPressed: activeCount > 0 && !_importing
                        ? _confirmImport
                        : null,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '单事务写入 + 指纹去重，失败整批回滚',
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
      ],
    );
  }

  // ────────────────────────────── 第 3 步：报告 ──────────────────────────────

  Widget _buildReportBody(BuildContext context) {
    final ToonPalette p = context.toon;
    if (_isBackup) return _buildBackupReportBody(context);
    final BillParseResult parsed = _parsed!;
    final ImportReport report = _report!;
    final bool hasNew = _hasNew;
    final ({int year, int month})? target = _target;
    // 行间插虚线（原型 `.kv + .kv`）—— 条件行太多，先收集再交错
    final List<Widget> kvs = <Widget>[
      _Kv(label: '读取行数', value: '${parsed.stats.dataRows}'),
      _Kv(label: '跳过（退款 / 不计收支）', value: '${parsed.stats.skipped}'),
      _Kv(
        label: '未命中分类规则 → 其他',
        value: '${hasNew ? report.uncategorized : 0}',
      ),
      _Kv(label: '本次真正入库', value: '${report.imported}'),
      if (report.duplicates > 0)
        _Kv(label: '重复跳过（指纹一致）', value: '${report.duplicates}'),
      if (report.fileDuplicates > 0)
        _Kv(label: '文件内重复', value: '${report.fileDuplicates}'),
      if (report.cancelled > 0)
        _Kv(label: '已取消', value: '${report.cancelled}'),
    ];

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
          child: ToonCard(
            padding: const EdgeInsets.fromLTRB(18, 20, 18, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Container(
                      width: 44,
                      height: 44,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: hasNew ? p.greenTint : p.track,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: p.ink, width: 2),
                        boxShadow: p.hard(d: 2),
                      ),
                      child: Icon(
                        Icons.check,
                        size: 24,
                        color: hasNew ? p.green : p.ink3,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            hasNew ? '导入完成' : '没有新增',
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            hasNew
                                ? '已写入当前账本'
                                      '${target == null ? '' : ' · ${_fmtMonth(target)}'}'
                                      ' · 成功导入 ${report.imported} 笔'
                                : '这 $_activeRows 笔之前已经导入过了，没有重复记账',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: p.ink2,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (hasNew)
                  Padding(
                    padding: const EdgeInsets.only(top: 18),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: <Widget>[
                        Text(
                          '${report.imported}',
                          style: TextStyle(
                            fontSize: 42,
                            fontWeight: FontWeight.w900,
                            color: p.green,
                            letterSpacing: -1.5,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '笔新增',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: p.ink2,
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 14),
                for (int i = 0; i < kvs.length; i++) ...<Widget>[
                  if (i > 0) const ToonDashedLine(),
                  kvs[i],
                ],
              ],
            ),
          ),
        ),
        if (hasNew && target != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Text(
              '其中 $_activeRows 笔属于 ${_fmtMonth(target)}，点「去看账单」直接翻到该月',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: p.ink2,
                height: 1.7,
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Column(
            children: <Widget>[
              if (target != null) ...<Widget>[
                ToonButton(
                  block: true,
                  label: '去看账单',
                  onPressed: _goToLedger,
                ),
                const SizedBox(height: 10),
              ],
              ToonButton(
                block: true,
                label: '再导入一个文件',
                kind: ToonButtonKind.ghost,
                onPressed: _resetToPick,
              ),
              const SizedBox(height: 10),
              Text(
                '导入后自动跳到数据所在月份；重复导入不会产生任何重复流水',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: p.ink2,
                  height: 1.7,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 未取消行中最晚的账单月份（导入后跳到这个月，用户才看得到结果）。
  ({int year, int month})? _latestMonthOf(
    List<ParsedRow> rows,
    List<bool> cancelled,
  ) {
    int? latest;
    for (var i = 0; i < rows.length; i++) {
      if (i < cancelled.length && cancelled[i]) continue;
      final ms = rows[i].occurredAt;
      if (latest == null || ms > latest) latest = ms;
    }
    if (latest == null) return null;
    final d = DateTime.fromMillisecondsSinceEpoch(latest);
    return (year: d.year, month: d.month);
  }

  String _fmtMonth(({int year, int month}) m) =>
      '${m.year}-${m.month.toString().padLeft(2, '0')}';
}

/// 备份恢复的报告页（第 3 步的备份分支）。
extension _BackupReportUi on _ImportPageState {
  Widget _buildBackupReportBody(BuildContext context) {
    final ToonPalette p = context.toon;
    final BackupRestoreReport r = _backupReport!;
    final ({int year, int month})? target = r.latestMonth;
    final List<Widget> kvs = <Widget>[
      _Kv(label: '备份流水', value: '${r.dataRows}'),
      _Kv(label: '本次恢复', value: '${r.imported}'),
      if (r.duplicates > 0)
        _Kv(label: '重复跳过（已有相同流水）', value: '${r.duplicates}'),
      if (r.createdAccounts > 0) _Kv(label: '新建账户', value: '${r.createdAccounts}'),
      if (r.createdCategories > 0)
        _Kv(label: '新建分类', value: '${r.createdCategories}'),
      if (r.budgetsRestored > 0)
        _Kv(label: '恢复预算', value: '${r.budgetsRestored} 个月'),
      if (r.settingsRestored > 0)
        _Kv(label: '恢复外观与布局', value: '${r.settingsRestored} 项'),
      _Kv(label: '账本', value: r.bookName ?? '当前账本'),
    ];

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
          child: ToonCard(
            padding: const EdgeInsets.fromLTRB(18, 20, 18, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Container(
                      width: 44,
                      height: 44,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: r.imported > 0 ? p.greenTint : p.track,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: p.ink, width: 2),
                        boxShadow: p.hard(d: 2),
                      ),
                      child: Icon(
                        r.imported > 0
                            ? Icons.check_rounded
                            : Icons.inventory_2_outlined,
                        size: 24,
                        color: r.imported > 0 ? p.green : p.ink2,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        r.imported > 0 ? '备份恢复完成' : '备份没有新数据',
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                for (int i = 0; i < kvs.length; i++) ...<Widget>[
                  if (i > 0) const ToonDashedLine(),
                  kvs[i],
                ],
              ],
            ),
          ),
        ),
        if (target != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Text(
              '点「去看账单」翻到 ${_fmtMonth(target)} 查看恢复的流水',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: p.ink2,
                height: 1.7,
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Column(
            children: <Widget>[
              if (target != null) ...<Widget>[
                ToonButton(
                  block: true,
                  label: '去看账单',
                  onPressed: () async {
                    await ref
                        .read(ledgerProvider.notifier)
                        .jumpToMonth(target.year, target.month);
                    if (!mounted) return;
                    if (context.mounted) context.go('/');
                  },
                ),
                const SizedBox(height: 10),
              ],
              ToonButton(
                block: true,
                label: '再导入一个文件',
                kind: ToonButtonKind.ghost,
                onPressed: _resetToPick,
              ),
              const SizedBox(height: 10),
              Text(
                '重复恢复同一份备份不会产生重复流水',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: p.ink2,
                  height: 1.7,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
