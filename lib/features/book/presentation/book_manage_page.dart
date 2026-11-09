/// 账本管理：列表 + 新建 + 切换（F7.6 P3 卡通化，对齐原型 `scrBooks`）。
///
/// 对应旧栈 `pages/book/manage.vue`。切换写 `active_book_id`（落库，杀进程不丢）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/core/theme/tokens.dart';
import 'package:yanxin/core/theme/toon.dart';
import 'package:yanxin/data/providers/book_providers.dart';
import 'package:yanxin/data/providers/database.dart';
import 'package:yanxin/ui_kit/app_page_state.dart';

import '../../shared/name_dialog.dart';

/// 账本管理页。返回 true 表示切换过账本（首页需要刷新）。
class BookManagePage extends ConsumerWidget {
  const BookManagePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ToonPalette p = context.toon;
    final booksAsync = ref.watch(bookListProvider);
    final activeId = ref.watch(activeBookIdProvider).value;

    return Scaffold(
      backgroundColor: p.paper,
      appBar: AppBar(
        title: const Text('账本管理'),
        actions: <Widget>[
          ToonIconButton(
            icon: Icons.add,
            tooltip: '新建账本',
            onPressed: () => _createBook(context, ref),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: booksAsync.when(
        loading: () => const AppPageLoading(),
        error: (Object e, StackTrace _) => AppPageError(error: e),
        data: (List<Book> books) => ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: ToonCard(
                padding: const EdgeInsets.all(6),
                clip: true,
                child: Column(
                  children: <Widget>[
                    for (final Book book in books)
                      _BookRow(
                        book: book,
                        active: book.id == activeId,
                        onTap: () async {
                          await ref
                              .read(activeBookIdProvider.notifier)
                              .select(book.id);
                          if (context.mounted) {
                            Navigator.of(context).pop(true);
                          }
                        },
                      ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Text(
                '· 切换账本后，首页 / 日历 / 统计 / 资产的数据都按当前账本隔离\n'
                '· 新建账本会自动带一个默认账户「现金」\n'
                '· 删除账本为软删除，数据永不物理删除',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: p.ink2,
                  height: 1.7,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _createBook(BuildContext context, WidgetRef ref) async {
    final name = await showNameDialog(context, title: '新建账本');
    if (name == null || name.trim().isEmpty) return;
    final book = await ref
        .read(bookRepositoryProvider)
        .create(name: name.trim());
    await ref.read(activeBookIdProvider.notifier).select(book.id);
    ref.invalidate(bookListProvider);
    if (context.mounted) Navigator.of(context).pop(true);
  }
}

/// 账本行：字母头像 + 名称 / `币种 · 类型`；当前账本 = 品牌浅底 + 墨色描边 + 对勾。
class _BookRow extends StatelessWidget {
  const _BookRow({
    required this.book,
    required this.active,
    required this.onTap,
  });

  final Book book;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    return ToonPress(
      dx: 2,
      dy: 2,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: BoxDecoration(
          color: active ? p.brandTint : Colors.transparent,
          borderRadius: BorderRadius.circular(Tok.rMd),
          border: Border.all(
            color: active ? p.ink : Colors.transparent,
            width: 2,
          ),
          boxShadow: active ? p.hard(d: 2.5) : null,
        ),
        child: Row(
          children: <Widget>[
            ToonAvatar(
              text: book.name.isEmpty ? '?' : book.name.substring(0, 1),
              small: true,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    book.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${book.currency} · ${book.type}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: p.ink2,
                    ),
                  ),
                ],
              ),
            ),
            if (active)
              Icon(Icons.check, size: 20, color: p.brandDeep),
          ],
        ),
      ),
    );
  }
}
