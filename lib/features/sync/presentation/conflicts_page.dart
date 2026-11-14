/// 冲突详情页（P6.4b D2）：本机被云端覆盖的那几行，看两份值、可恢复。
///
/// 为什么是独立页面而不是弹窗：一屏可能要看好几条，弹窗里放不下「本机 / 云端」两份值。
/// 为什么用 `Navigator.push` 而不是 `context.push`：测试环境是裸 `MaterialApp`，
/// 没有 GoRouter（HANDOFF 坑清单 #2）。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/core/theme/toon.dart';
import 'package:yanxin/features/sync/application/sync_conflicts.dart';
import 'package:yanxin/ui_kit/app_page_state.dart';

class SyncConflictsPage extends ConsumerWidget {
  const SyncConflictsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ToonPalette p = context.toon;
    final AsyncValue<List<SyncConflictEntry>> list = ref.watch(
      syncConflictsProvider,
    );
    return Scaffold(
      backgroundColor: p.paper,
      appBar: AppBar(title: const Text('冲突详情')),
      body: list.when(
        loading: () => const AppPageLoading(),
        error: (Object e, StackTrace _) => AppPageError(error: e),
        data: (List<SyncConflictEntry> rows) => rows.isEmpty
            ? Center(
                child: Text(
                  '没有被覆盖的数据',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: p.ink2,
                  ),
                ),
              )
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
                itemCount: rows.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (BuildContext context, int index) =>
                    _ConflictCard(entry: rows[index]),
              ),
      ),
    );
  }
}

class _ConflictCard extends ConsumerWidget {
  const _ConflictCard({required this.entry});

  final SyncConflictEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ToonPalette p = context.toon;
    final String title = _title();
    return ToonCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Text(
                _stamp(entry.createdAt),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: p.ink2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _payloadRow('本机', _describe(entry.localPayload), p, p.brandInk),
          const SizedBox(height: 4),
          _payloadRow('云端', _describe(entry.serverPayload), p, p.ink2),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              ToonButton(
                label: '忽略',
                small: true,
                kind: ToonButtonKind.ghost,
                onPressed: () async {
                  await deleteConflictOnRef(ref, entry.id);
                },
              ),
              const SizedBox(width: 8),
              ToonButton(
                label: '恢复本机版本',
                small: true,
                onPressed: () async {
                  final bool ok = await restoreConflict(ref, entry);
                  if (!context.mounted) return;
                  showToonFeedback(
                    context,
                    ok ? '已恢复，下次同步会推上去' : '恢复失败：这份存档可能已损坏',
                    kind: ok
                        ? ToonFeedbackKind.success
                        : ToonFeedbackKind.error,
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _payloadRow(
    String label,
    String text,
    ToonPalette p,
    Color color,
  ) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      SizedBox(
        width: 34,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w800,
            color: p.ink2,
          ),
        ),
      ),
      Expanded(
        child: Text(
          text,
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color),
        ),
      ),
    ],
  );

  /// 卡片标题：能认出「是哪一笔」就行，认不出就退回实体名。
  String _title() {
    final Map<String, Object?> payload = _decode(entry.localPayload);
    switch (entry.entity) {
      case 'transaction':
        final Object? cents = payload['amountCents'];
        final Object? note = payload['note'];
        final String amount = cents is num
            ? '¥${(cents / 100).toStringAsFixed(2)}'
            : '一笔账';
        final String tail = note is String && note.trim().isNotEmpty
            ? ' · ${note.trim()}'
            : '';
        return '$amount$tail';
      case 'account':
        return payload['name'] is String ? '${payload['name']}' : '账户';
      case 'category':
        return payload['name'] is String ? '${payload['name']}' : '分类';
      case 'budget':
        return '预算 ${payload['period'] ?? ''}'.trim();
      case 'book':
        return payload['name'] is String ? '${payload['name']}' : '账本';
      case 'setting':
        return '外观与布局设置';
      default:
        return entry.entity;
    }
  }

  String _describe(String raw) {
    final Map<String, Object?> payload = _decode(raw);
    if (payload.isEmpty) return '（已删除）';
    if (entry.entity == 'transaction') {
      final Object? note = payload['note'];
      final Object? cents = payload['amountCents'];
      final String amount = cents is num
          ? '¥${(cents / 100).toStringAsFixed(2)}'
          : '—';
      final String noteText =
          note is String && note.trim().isNotEmpty ? ' · ${note.trim()}' : '';
      return '$amount$noteText';
    }
    if (entry.entity == 'setting') {
      return payload.entries
          .map((MapEntry<String, Object?> e) => '${e.key}=${e.value}')
          .join(' · ');
    }
    final Object? name = payload['name'];
    return name is String ? name : '（无名称）';
  }

  Map<String, Object?> _decode(String raw) {
    try {
      final Object? decoded = jsonDecode(raw);
      return decoded is Map
          ? Map<String, Object?>.from(decoded)
          : <String, Object?>{};
    } catch (_) {
      return <String, Object?>{};
    }
  }

  String _stamp(int ms) {
    final DateTime t = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }
}
