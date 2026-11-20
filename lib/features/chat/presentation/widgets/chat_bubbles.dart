part of '../chat_page.dart';

// ────────────────────────────── 用户气泡 ──────────────────────────────

/// 用户发的东西（文字 / 图片）统一靠右显示。
class _QuestionBubble extends StatelessWidget {
  const _QuestionBubble({required this.text, required this.icon});

  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: p.brandTint,
          borderRadius: BorderRadius.circular(Tok.rMd),
          border: p.inkBorder(on: p.brandTint),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 14, color: p.brandInk),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                text,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: p.brandInk,
                  height: 1.45,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ────────────────────────────── 提示 / 错误 ──────────────────────────────

class _NoticeBubble extends StatelessWidget {
  const _NoticeBubble({required this.text, required this.tone});

  final String text;
  final NoticeTone tone;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    final (Color bg, Color fg, IconData icon) = switch (tone) {
      NoticeTone.warn => (p.redTint, p.redInk, Icons.info_outline_rounded),
      NoticeTone.good => (p.greenTint, p.ink, Icons.check_circle_outline_rounded),
      NoticeTone.info => (p.canvas2, p.ink2, Icons.lock_outline_rounded),
    };
    return ToonCard(
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 15, color: fg),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: fg, height: 1.55),
            ),
          ),
        ],
      ),
    );
  }
}

// ────────────────────────────── 回答卡（沿用 M1 视觉）──────────────────────────────

class _AnswerCard extends StatelessWidget {
  const _AnswerCard({required this.answer, required this.onAsk});

  final FinanceAnswer answer;
  final void Function(String) onAsk;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    final Color accent = switch (answer.tone) {
      AnswerTone.warn => p.red,
      AnswerTone.good => p.green,
      AnswerTone.neutral => p.brandDeep,
    };

    return ToonCard(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  answer.title,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: p.ink3,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
            ],
          ),
          if (answer.headline != null) ...<Widget>[
            const SizedBox(height: 8),
            // 新答案卡冒出来时主数字淡入（首次出现也动），不是硬蹦出来
            ToonFadeValue(
              value: answer.headline!,
              animateOnFirstBuild: true,
              child: Text(
                answer.headline!,
                style: TextStyle(
                  fontSize: 27,
                  fontWeight: FontWeight.w800,
                  color: p.ink,
                  height: 1.1,
                ),
              ),
            ),
            if (answer.headlineNote != null) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                answer.headlineNote!,
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: p.ink3),
              ),
            ],
          ],
          if (answer.facts.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            Container(height: 1, color: p.line),
            const SizedBox(height: 8),
            for (final AnswerFact f in answer.facts) _FactRow(fact: f),
          ],
          const SizedBox(height: 10),
          Text(
            answer.narrative,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: p.ink2,
              height: 1.65,
            ),
          ),
          if (answer.suggestions.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final String s in answer.suggestions)
                  _SuggestionChip(label: s, onTap: () => onAsk(s)),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _FactRow extends StatelessWidget {
  const _FactRow({required this.fact});

  final AnswerFact fact;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Text(
              fact.label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: p.ink2,
                height: 1.4,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Text(
                fact.value,
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: p.ink),
              ),
              if (fact.note != null)
                Text(
                  fact.note!,
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: p.ink3),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ────────────────────────────── 小件 ──────────────────────────────

class _SuggestionChip extends StatelessWidget {
  const _SuggestionChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          color: p.canvas2,
          borderRadius: BorderRadius.circular(999),
          border: p.inkBorder(w: Tok.bw * 0.8),
        ),
        child: Text(
          label,
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: p.ink2),
        ),
      ),
    );
  }
}

class _HintNote extends StatelessWidget {
  const _HintNote({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(Icons.lock_outline_rounded, size: 13, color: p.ink3),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: p.ink3,
              height: 1.6,
            ),
          ),
        ),
      ],
    );
  }
}
