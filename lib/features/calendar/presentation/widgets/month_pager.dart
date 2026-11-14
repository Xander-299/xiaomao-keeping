/// 月历翻页容器：**跟手**翻页，松手按「过了多少 / 甩多快」落定。
///
/// 为什么自己写、不用 [PageView]：
/// 1. 翻页区域只是日历页的**上半块**，下半块账单属于「选中日」，翻月不能带着它走；
///    PageView 会把整页当成一个滑动物，分不出这块；
/// 2. 相邻月的日标注 / 月汇总要**在拖的过程中就已经画出来**，PageView 拿不到这些数据；
/// 3. 要能做到「翻到一半停住」——进度就是动画值本身，手指停在哪，页面就停在哪。
///
/// 手势 → 进度：横向位移除以容器宽度就是翻页进度 `p ∈ [0, 1]`；
/// 松手时 `p > 0.5` 或顺着翻页方向甩得够快 → 翻过去（回调 [onTurn]），否则弹回。
/// 到边界（已经没有下一个月）时不硬拽，改成阻尼位移，松手必回弹。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 一屏翻页容器。
class MonthPager extends StatefulWidget {
  const MonthPager({
    super.key,
    required this.year,
    required this.month,
    required this.current,
    required this.previous,
    required this.next,
    required this.onTurn,
  });

  /// 当前显示的月（[previous] / [next] 与它相邻）。
  final int year;
  final int month;

  /// 当前页。
  final Widget current;

  /// 上一月；为空 = 没有上一页（当前实现永远有，留空表示「不给翻」）。
  final Widget? previous;

  /// 下一月；为空 = 已经是最新月，往左拖只给阻尼、不翻。
  final Widget? next;

  /// 翻页完成（动画走到 1）后回调：`1` = 下一月，`-1` = 上一月。
  final ValueChanged<int> onTurn;

  @override
  State<MonthPager> createState() => _MonthPagerState();
}

class _MonthPagerState extends State<MonthPager>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  );

  /// 本次翻页的方向：`1` = 翻到下一月，`-1` = 翻到上一月，`0` = 还没定。
  int _dir = 0;

  /// 容器宽度（= 一屏的翻页距离）。
  double _width = 1;

  /// 手势按下时的进度（可能是在「弹回」动画中途接住，所以要记住起点）。
  double _startP = 0;

  /// 本次手势累计的水平位移。
  double _dx = 0;

  /// 翻过去 / 弹回来，分别用多久。
  static const Duration _commitDuration = Duration(milliseconds: 300);
  static const Duration _cancelDuration = Duration(milliseconds: 220);

  /// 甩动多快（px/s）就算翻页，不再看位移。
  static const double _flingVelocity = 420;

  @override
  void didUpdateWidget(covariant MonthPager oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部直接换月（月份选择器 / 换账本）：不播翻页，直接复位。
    // 正常翻页路径在回调 onTurn 之前已经把进度清零，这里基本不会命中。
    if (oldWidget.year != widget.year || oldWidget.month != widget.month) {
      _dir = 0;
      if (_c.isAnimating) _c.stop();
      if (_c.value != 0) _c.value = 0;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _onDragStart(DragStartDetails _) {
    // 接住还没跑完的落定动画：手指按下就由手指接管，进度不跳。
    _c.stop();
    _dx = 0;
    _startP = _c.value;
    if (_startP <= 0.001) _dir = 0;
  }

  void _onDragUpdate(DragUpdateDetails details) {
    _dx += details.delta.dx;
    if (_dir == 0) {
      if (_dx.abs() < 1) return;
      _dir = _dx < 0 ? 1 : -1; // 左滑 = 下一个月
      _startP = 0;
    }
    double p = _startP - _dx * _dir / _width;
    if (p < 0) {
      // 手指反向拉回：换方向重算，而不是当成弹性回弹
      _dir = -_dir;
      _dx = 0;
      _startP = 0;
      p = 0;
    }
    if (p > 1) p = 1;
    // 到边界（已经是最新月）：给阻尼，最多拉出 1/3 屏，松手必回弹
    if (_dir > 0 && widget.next == null) {
      p = 0.34 * (1 - math.exp(-2.4 * p));
    }
    _c.value = p;
  }

  Future<void> _onDragEnd(DragEndDetails details) async {
    final double p = _c.value;
    final double v = details.velocity.pixelsPerSecond.dx;
    final bool atWall = _dir > 0 && widget.next == null;
    final bool fling =
        v.isFinite && _dir != 0 && v * _dir < -_flingVelocity;
    final bool commit = !atWall && _dir != 0 && (p > 0.5 || fling);

    if (!commit) {
      final bool done = await _settleTo(0, _cancelDuration);
      // 只有真的弹回到 0 才清方向：中途被手指接住时要保持同一页、同一方向
      if (done && mounted) _dir = 0;
      return;
    }

    final int dir = _dir;
    final bool done = await _settleTo(1, _commitDuration);
    // 中途又被手指接住：交给下一次手势，别在这里纠正状态
    if (!done || !mounted) return;
    // 先清零再换月：新的一页正好是刚才滑进来的那一页，视觉上连续
    _c.value = 0;
    _dir = 0;
    widget.onTurn(dir);
  }

  /// 把进度动画到 [target]；被新手势打断时返回 `false`。
  Future<bool> _settleTo(double target, Duration duration) async {
    if ((_c.value - target).abs() < 0.001) {
      _c.value = target;
      return true;
    }
    try {
      await _c
          .animateTo(target, duration: duration, curve: Curves.easeOutCubic)
          .orCancel;
      return true;
    } on TickerCanceled {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        _width = constraints.maxWidth > 0 ? constraints.maxWidth : 1;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: _onDragStart,
          onHorizontalDragUpdate: _onDragUpdate,
          onHorizontalDragEnd: _onDragEnd,
          onHorizontalDragCancel: () {
            // 手势被别的东西抢走（比如系统返回）：平滑回位，别瞬跳
            _settleTo(0, _cancelDuration).then((bool done) {
              if (done && mounted) _dir = 0;
            });
          },
          child: AnimatedBuilder(
            animation: _c,
            builder: (BuildContext context, Widget? _) => _buildPages(),
          ),
        );
      },
    );
  }

  Widget _buildPages() {
    final double p = _c.value;
    final int dir = _dir;
    final Widget? incoming = dir > 0
        ? widget.next
        : dir < 0
        ? widget.previous
        : null;
    if (p <= 0.001 || incoming == null) return widget.current;

    final double w = _width;
    // ⚠️ 接缝上不要画阴影：两页都是纸色，一条 10% 黑的渐变带在**浅色**模式下
    // 会在中点留下一条灰线（深色模式看不出来）。要保留「翻起来」的层次感就加
    // 在两页各自的边缘上，别横跨接缝 —— 2026-11-14 用户明确要求去掉。

    return ClipRect(
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: <Widget>[
          // 当前页：往翻页方向整屏移出，顺带绕书脊侧翻一点点（只做深度，不做翻转）
          Transform.translate(
            offset: Offset(-dir * p * w, 0),
            child: Transform(
              alignment: dir > 0 ? Alignment.centerLeft : Alignment.centerRight,
              transform: Matrix4.identity()
                ..setEntry(3, 2, 0.0015)
                ..rotateY(-dir * 0.10 * p),
              child: widget.current,
            ),
          ),
          // 新页：从另一侧整屏移入。用 Positioned 是为了**不参与** Stack 定高，
          // 否则 5 行月 / 6 行月切换时下面账单区会被顶一下。
          Positioned(
            top: 0,
            left: 0,
            width: w,
            child: Transform.translate(
              offset: Offset(dir * (1 - p) * w, 0),
              child: incoming,
            ),
          ),
        ],
      ),
    );
  }
}
