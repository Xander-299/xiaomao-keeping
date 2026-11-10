/// 「数据导出」底部弹层（`F7.7 B 批`，见 `docs/spec/SPEC-F7.7-backlog.md` §B）。
///
/// 两条选项：导出流水 CSV / 导出备份 JSON。落盘用 `file_picker` 的
/// **静态** `saveFile`（12.x 起没有 `.platform`），Android 走 SAF
/// `ACTION_CREATE_DOCUMENT` → **不需要任何存储权限**，返回 `Uri?`
/// （用户取消 = `null`，按 SPEC §B.1 第 3 条静默处理）。
///
/// 本弹层**只读**：不写库、不 bump `dataEpochProvider`。
library;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/core/theme/tokens.dart';
import 'package:yanxin/core/theme/toon.dart';
import 'package:yanxin/data/providers/account_providers.dart';
import 'package:yanxin/data/providers/book_providers.dart';
import 'package:yanxin/data/providers/category_providers.dart';
import 'package:yanxin/data/providers/database.dart';
import 'package:yanxin/ui_kit/app_sheet_header.dart';

import '../../import/application/backup_settings.dart';
import '../application/csv_export.dart';

/// CSV 的 MIME（SAF 用它决定默认后缀过滤）。
const String kCsvMime = 'text/csv';

/// 备份 JSON 的 MIME。
const String kJsonMime = 'application/json';

/// 弹出「数据导出」弹层。
Future<void> showExportSheet(BuildContext context, WidgetRef ref) {
  final ToonPalette p = context.toon;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: p.paper,
    shape: RoundedRectangleBorder(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(Tok.rXl)),
      side: BorderSide(color: p.ink, width: Tok.bw),
    ),
    builder: (BuildContext _) => const _ExportSheet(),
  );
}

class _ExportSheet extends ConsumerStatefulWidget {
  const _ExportSheet();

  @override
  ConsumerState<_ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends ConsumerState<_ExportSheet> {
  /// 导出中：两条选项一起置灰，避免并发起两次 SAF 对话框。
  bool _busy = false;

  /// 导出中的提示文案（区分两条选项）。
  String _busyLabel = '';

  /// 轻提示。弹层可能已被系统回收 → 先判 `mounted`。
  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
      );
  }

  /// 当前账本 + 全量取数（两条导出共用的前置）。
  ///
  /// 取数一律走既有仓储：`listByBook` 只含**未软删**行（SPEC §B.4.5）。
  Future<({Book? book, List<TxRow> rows, List<Account> accounts, List<Category> categories, List<BudgetRow> budgets})>
  _load() async {
    final String? bookId = await ref.read(activeBookIdProvider.future);
    if (bookId == null) {
      throw StateError('当前账本未就绪');
    }
    return (
      book: await ref.read(currentBookProvider.future),
      rows: await ref.read(transactionRepositoryProvider).listByBook(bookId),
      accounts: await ref.read(accountsProvider.future),
      categories: await ref.read(categoriesProvider.future),
      budgets: await ref.read(budgetRepositoryProvider).listByBook(bookId),
    );
  }

  /// 导出流水 CSV（当前账本 · 全时间）。
  Future<void> _exportCsv() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _busyLabel = '正在生成 CSV…';
    });
    try {
      final data = await _load();
      final int nowMs = DateTime.now().millisecondsSinceEpoch;
      final String fileName = exportFileName(
        bookName: data.book?.name ?? '',
        ext: 'csv',
        nowMs: nowMs,
      );
      final String csv = buildBillCsv(
        rows: data.rows,
        categoryNames: <String, String>{
          for (final Category c in data.categories) c.id: c.name,
        },
        accountNames: <String, String>{
          for (final Account a in data.accounts) a.id: a.name,
        },
      );
      final Uri? saved = await FilePicker.saveFile(
        fileName: fileName,
        bytes: utf8Bytes(csv),
        mimeType: kCsvMime,
      );
      if (saved == null) return; // 用户取消 → 静默
      _toast('已导出 ${data.rows.length} 笔到 $fileName');
    } on Object {
      _toast('导出失败，请换个保存位置再试');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyLabel = '';
        });
      }
    }
  }

  /// 导出备份 JSON（当前账本全量）。
  Future<void> _exportJson() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _busyLabel = '正在生成备份…';
    });
    try {
      final data = await _load();
      final int nowMs = DateTime.now().millisecondsSinceEpoch;
      final String fileName = exportFileName(
        bookName: data.book?.name ?? '',
        ext: 'json',
        nowMs: nowMs,
      );
      final Book? book = data.book;
      if (book == null) {
        throw StateError('当前账本未就绪');
      }
      // 换机时布局 / 外观一起走（白名单见 backup_settings.dart）
      final Map<String, Object?> settings = await collectBackupSettings(
        ref.read(appMetaRepositoryProvider),
      );
      final String json = buildBackupJson(
        book: book,
        accounts: data.accounts,
        categories: data.categories,
        transactions: data.rows,
        budgets: data.budgets,
        exportedAtMs: nowMs,
        settings: settings,
      );
      final Uri? saved = await FilePicker.saveFile(
        fileName: fileName,
        bytes: utf8Bytes(json),
        mimeType: kJsonMime,
      );
      if (saved == null) return; // 用户取消 → 静默
      _toast('已备份 ${data.rows.length} 笔到 $fileName');
    } on Object {
      _toast('导出失败，请换个保存位置再试');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyLabel = '';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const AppSheetHeader(
              title: '数据导出',
              subtitle: '导出的是当前账本，只读、不改动任何数据。',
              subtitleGap: 4,
            ),
            const SizedBox(height: 12),
            Container(
              clipBehavior: Clip.antiAlias,
              decoration: p.cardDeco(),
              child: Column(
                children: <Widget>[
                  _ExportRow(
                    icon: Icons.grid_on_rounded,
                    title: '导出流水 CSV',
                    sub: '全时间 · Excel 可直接打开',
                    iconBg: p.greenTint,
                    iconFg: p.green,
                    enabled: !_busy,
                    onTap: _exportCsv,
                  ),
                  const ToonDashedLine(),
                  _ExportRow(
                    icon: Icons.inventory_2_outlined,
                    title: '导出备份 JSON',
                    sub: '账本 / 账户 / 分类 / 流水 / 预算',
                    iconBg: p.blueTint,
                    iconFg: p.blue,
                    enabled: !_busy,
                    onTap: _exportJson,
                  ),
                ],
              ),
            ),
            if (_busy) ...<Widget>[
              const SizedBox(height: 10),
              Row(
                children: <Widget>[
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _busyLabel,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: p.ink2,
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 10),
            Text(
              'CSV 金额是「元」、不带正负号（方向看类型列）；备份 JSON 金额是整数「分」。',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: p.ink2,
              ),
            ),
            const SizedBox(height: 14),
            ToonButton(
              label: '取消',
              kind: ToonButtonKind.ghost,
              block: true,
              onPressed: _busy ? null : () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExportRow extends StatelessWidget {
  const _ExportRow({
    required this.icon,
    required this.title,
    required this.sub,
    required this.iconBg,
    required this.iconFg,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String sub;
  final Color iconBg;
  final Color iconFg;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    final Widget row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: <Widget>[
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: iconBg,
              borderRadius: BorderRadius.circular(Tok.rSm),
              border: Border.all(color: p.ink, width: Tok.bw),
            ),
            child: Icon(icon, size: 19, color: iconFg),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  sub,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: p.ink2,
                  ),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right, size: 18, color: p.ink2),
        ],
      ),
    );

    if (!enabled) return Opacity(opacity: 0.45, child: row);
    return ToonPress(dx: 0, dy: 0, onTap: onTap, child: row);
  }
}
