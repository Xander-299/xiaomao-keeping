/// 首页的「记一笔 / 问一句」入口卡（替换原来的「本月预算」大卡）。
///
/// 设计取舍：**首页不做聊天流**。首页的职责是"看账"，把聊天整块塞进来会把本月账单推到折叠线以下；
/// 所以这里只放一个**能打字的外观**（点一下进聊天页）+ 相机键 + 三个示例问题，
/// 真正的对话、识别与确认都在 `/chat` 里完成。
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:yanxin/core/theme/tokens.dart';
import 'package:yanxin/core/theme/toon.dart';
import 'package:yanxin/features/assistant/application/finance_answer.dart';

import '../chat_page.dart';

/// 首页入口卡。
///
/// [showSamples] 控制是否显示示例问题（首页布局参数，默认开）；
/// [sampleCount] 控制显示几条（1–3，另一条布局参数）。
class ChatEntryCard extends StatelessWidget {
  const ChatEntryCard({
    super.key,
    this.showSamples = true,
    this.sampleCount = 3,
  });

  final bool showSamples;
  final int sampleCount;

  void _open(BuildContext context, {bool image = false, String? question}) {
    context.push('/chat', extra: ChatLaunch(openImagePicker: image, question: question));
  }

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      child: ToonCard(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.forum_outlined, size: 15, color: p.brandDeep),
                const SizedBox(width: 6),
                const Text(
                  '记一笔 / 问一句',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
                ),
                const Spacer(),
                Text(
                  '本地算 · 不上传',
                  style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: p.ink3),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // 整条「假输入框」可点 → 进聊天
            GestureDetector(
              onTap: () => _open(context),
              behavior: HitTestBehavior.opaque,
              child: Container(
                padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
                decoration: BoxDecoration(
                  color: p.canvas2,
                  borderRadius: BorderRadius.circular(12),
                  border: p.inkBorder(w: Tok.bw * 0.8),
                ),
                child: Row(
                  children: <Widget>[
                    Icon(Icons.chat_bubble_outline_rounded, size: 15, color: p.ink3),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '问一句，或发张账单截图',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: p.ink3,
                        ),
                      ),
                    ),
                    GestureDetector(
                      onTap: () => _open(context, image: true),
                      behavior: HitTestBehavior.opaque,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        child: Icon(Icons.photo_camera_outlined, size: 19, color: p.brandDeep),
                      ),
                    ),
                    Icon(Icons.arrow_forward_rounded, size: 17, color: p.ink),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            if (showSamples && sampleCount > 0)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final String q in kExampleQuestions.take(sampleCount))
                    _MiniChip(label: q, onTap: () => _open(context, question: q)),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _MiniChip extends StatelessWidget {
  const _MiniChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: p.paper,
          borderRadius: BorderRadius.circular(999),
          border: p.inkBorder(w: Tok.bw * 0.7),
        ),
        child: Text(
          label,
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: p.ink2),
        ),
      ),
    );
  }
}
