part of '../toon.dart';

// ────────────────────────────── 空状态 ──────────────────────────────

/// 通用空状态：图标 + 标题 + 说明 + 可选动作。
///
/// 收敛各页手写的「图标 + 文案 + 按钮」竖排空态；文案与回调由调用方保留，
/// 只有视觉结构统一到这里。页面级大空态用默认的品牌色圆环图标底，
/// 区块内的小空态传 `ring: false` 用裸图标。
class ToonEmptyState extends StatelessWidget {
  const ToonEmptyState({
    super.key,
    required this.title,
    this.message,
    this.icon,
    this.ring = true,
    this.action,
  });

  final String title;

  final String? message;

  final IconData? icon;

  final bool ring;

  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    final Widget? iconArea = icon == null
        ? null
        : ring
        ? ToonDashedBorder(
            circle: true,
            background: p.brandTint,
            child: SizedBox(
              width: 76,
              height: 76,
              child: Center(child: Icon(icon, size: 34, color: p.brandInk)),
            ),
          )
        : Icon(icon, size: 44, color: p.ink3);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Tok.s40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ?iconArea,
            const SizedBox(height: Tok.s12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: Tok.fs15,
                fontWeight: FontWeight.w700,
                color: p.ink,
              ),
            ),
            if (message != null) ...<Widget>[
              const SizedBox(height: Tok.s6),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: Tok.fs13,
                  fontWeight: FontWeight.w600,
                  color: p.ink2,
                ),
              ),
            ],
            if (action != null) ...<Widget>[
              const SizedBox(height: Tok.s16),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// 通用错误态：页面级数据加载失败时使用；局部错误可传入更短的文案。
///
/// 错误态与空态分离：空态表达“没有数据”，错误态表达“这次读取失败”。
/// 这里不默认展示异常详情，避免把技术堆栈变成页面内容。
class ToonErrorState extends StatelessWidget {
  const ToonErrorState({
    super.key,
    required this.title,
    this.message,
    this.action,
  });

  final String title;

  final String? message;

  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Tok.s40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ToonDashedBorder(
              circle: true,
              background: p.redTint,
              child: SizedBox(
                width: 76,
                height: 76,
                child: Center(
                  child: Icon(
                    Icons.error_outline_rounded,
                    size: 34,
                    color: p.redInk,
                  ),
                ),
              ),
            ),
            const SizedBox(height: Tok.s12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: Tok.fs15,
                fontWeight: FontWeight.w700,
                color: p.ink,
              ),
            ),
            if (message != null) ...<Widget>[
              const SizedBox(height: Tok.s6),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: Tok.fs13,
                  fontWeight: FontWeight.w600,
                  color: p.ink2,
                ),
              ),
            ],
            if (action != null) ...<Widget>[
              const SizedBox(height: Tok.s16),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
