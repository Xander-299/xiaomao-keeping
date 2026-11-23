part of '../auto_book_page.dart';

/// 「最近一次自动记账」区块：无记录时给出引导文案。
class _LatestBatchBlock extends StatelessWidget {
  const _LatestBatchBlock({
    required this.batch,
    required this.loading,
    required this.onUndo,
  });

  final AutoBookBatch? batch;
  final bool loading;
  final Future<void> Function(AutoBookBatch) onUndo;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    if (loading) {
      return Text(
        '读取中…',
        style: TextStyle(fontSize: 12, color: p.ink2),
      );
    }
    final AutoBookBatch? b = batch;
    if (b == null) {
      return Row(
        children: <Widget>[
          Icon(Icons.inbox_outlined, size: 20, color: p.ink3),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '还没有自动记过账。识别到支付通知后，这里会显示笔数与合计 ——'
              '若一直为空，先看下面的诊断块卡在哪一层。',
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                fontWeight: FontWeight.w600,
                color: p.ink2,
              ),
            ),
          ),
        ],
      );
    }
    return Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '${b.count} 笔 · 合计 ¥${centsToYuan(b.totalCents)}',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                _stamp(b.atMs),
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: p.ink2,
                ),
              ),
            ],
          ),
        ),
        ToonButton(
          small: true,
          kind: ToonButtonKind.danger,
          label: '撤销',
          onPressed: () => onUndo(b),
        ),
      ],
    );
  }

  static String _stamp(int ms) {
    final DateTime t = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }
}

/// 「诊断」区块 —— 把四个断点各自的**最后一跳**摆出来。
///
/// 没有它时，「自动记账没生效」对用户和开发者都是黑盒：分不清是服务没被系统绑定、
/// 没抓到通知、没触发消费队列，还是抓到后解析失败。这里逐层给可判断的证据。
class _DiagnosticsBlock extends StatelessWidget {
  const _DiagnosticsBlock({
    required this.listenerOn,
    required this.diag,
    required this.pending,
    required this.lastRun,
    required this.loading,
  });

  final bool listenerOn;
  final AutoBookDiagnostics? diag;
  final int? pending;
  final AutoBookLastRun? lastRun;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    final AutoBookDiagnostics? d = diag;
    if (loading && d == null) {
      return Text(
        '读取中…',
        style: TextStyle(fontSize: 12, color: p.ink2),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _InfoLine('监听服务', _listenerText(d)),
        const ToonDashedLine(),
        _InfoLine('最近捕获', _captureText(d)),
        const ToonDashedLine(),
        _InfoLine('待入账', pending == null ? '—' : '$pending 条'),
        const ToonDashedLine(),
        _InfoLine('上次检查', lastRun?.summary ?? '还没有检查过'),
        const ToonDashedLine(),
        _InfoLine('抓取统计', _statsText(d)),
        const ToonDashedLine(),
        _InfoLine('采集通道', _channelText(d)),
        const ToonDashedLine(),
        _InfoLine('补抓通道', _catchUpText(d)),
        const SizedBox(height: 10),
        Text(
          _hint(d),
          style: TextStyle(
            fontSize: 11.5,
            height: 1.6,
            fontWeight: FontWeight.w600,
            color: p.ink2,
          ),
        ),
      ],
    );
  }

  static String _listenerText(AutoBookDiagnostics? d) {
    if (d == null) return '不可用（非 Android 或通道异常）';
    return d.listenerConnected ? '系统已绑定' : '未绑定';
  }

  static String _captureText(AutoBookDiagnostics? d) {
    if (d == null) return '—';
    if (d.neverCaptured) return '从未收到过支付通知';
    final String ago = _ago(d.nowMs, d.lastCaptureAtMs);
    final String who = _pkgName(d.lastCapturePkg);
    return who.isEmpty ? ago : '$ago · $who';
  }

  static String _statsText(AutoBookDiagnostics? d) {
    if (d == null) return '—';
    return '抓到 ${d.capturedTotal} · 取走 ${d.drainedTotal} · '
        '其他通知 ${d.skippedNotWatched} · 空文案 ${d.skippedEmpty} · '
        '组摘要 ${d.skippedGroupSummary} · 去重 ${d.skippedDedup}';
  }

  /// **采集通道**（F7.16 新增）。
  ///
  /// 为什么值得单独一行：实测（Redmi K50 / MIUI，2026-10-09）这台机器上
  /// ① `onNotificationPosted` 一条都不投递，② 后台闹钟与广播被 ROM 静默吞掉
  /// （`am broadcast` 还回报 `result=0` 假成功）→ 用户看到的现象是「时灵时不灵」。
  /// 把「当前靠哪条通道在采集」摆出来，排查就不再靠猜。
  static String _channelText(AutoBookDiagnostics? d) {
    if (d == null) return '—';
    final List<String> parts = <String>[];
    parts.add(
      d.postedChannelUnavailable
          ? '实时推送 不可用'
          : (d.postedCallbackSeen ? '实时推送 可用' : '实时推送 待观察'),
    );
    if (d.tickCatchUpTotal > 0) {
      parts.add('后台唤醒 已生效 ${d.tickCatchUpTotal} 轮');
    } else {
      // 实测：本机后台唤醒被 ROM 吞掉。这是**已知且如实告知**的限制，
      // 不能让用户以为「后台已经在帮我记了」而放心地不看通知。
      parts.add('后台唤醒 被系统限制');
    }
    if (d.removedCaptureTotal > 0) {
      parts.add('撤回时补回 ${d.removedCaptureTotal} 笔');
    }
    return parts.join(' · ');
  }

  /// **补抓通道**（F7.20 新增）。
  ///
  /// 为什么单独一行：「监听服务 = 未绑定」只说明**当前**没连上，而补抓是否可用
  /// 决定了「打开 App 一次能不能补记上」。用户看到的「设置里开着却一条都记不上」，
  /// 断点就在这条通道上 —— 它与「实时推送不可用」是两件不同的事。
  static String _catchUpText(AutoBookDiagnostics? d) {
    if (d == null) return '—';
    if (!d.catchUpChannelDead) return '正常';
    // 试过重绑仍不通 —— 把「试过了」也摆出来，免得用户以为我们什么都没做
    final String tried = d.rebindAttempts > 0
        ? ' · 已尝试重绑 ${d.rebindAttempts} 次未成功'
        : '';
    return '不通（系统未绑定监听服务）$tried';
  }

  /// 按当前证据给**一句可执行的**提示（这是「失败可懂」的核心）。
  String _hint(AutoBookDiagnostics? d) {
    if (!listenerOn) {
      return '通知使用权没开 —— 打开后才会开始识别微信 / 支付宝的支付通知。';
    }
    if (d == null) {
      return '读不到系统状态（可能不在 Android 上运行）。';
    }
    if (d.catchUpChannelDead) {
      // 最狠的一种断法：设置里显示已开启，但系统没绑定 → 实时推送与补抓**都不通**。
      // 此时绝不能再说「打开 App 一次就会补记上」，那条通道根本不存在。
      return '系统当前没有真正绑定监听服务 —— 设置里看着是「已开启」，但连接没建起来'
          '（国产 ROM 常见）。这种状态下实时推送和补记都不会发生：'
          '请在系统设置里把「通知使用权」关掉再打开一次；仍不行就重启手机。';
    }
    if (!d.listenerConnected && d.lastConnectedAtMs > 0) {
      return '设置里开着，但系统当前没有绑定监听服务 —— 常见于国产 ROM 的后台限制。'
          '可在系统设置里把「通知使用权」关掉再打开一次，或重启手机。';
    }
    if (d.neverCaptured && d.skippedNotWatched > 0) {
      return '监听是通的（已经看到过其他 App 的通知），但还没收到过微信 / 支付宝的支付通知。'
          '确认这两个 App 的「允许通知」是开着的。';
    }
    if (d.neverCaptured) {
      return '还没抓到过任何通知。做一笔支付后回到本页，这里会显示捕获时间。';
    }
    final int waiting = pending ?? 0;
    if (waiting > 0) {
      return '有 $waiting 条已捕获但还没入账 —— 切到桌面再打开本 App 会自动入账，'
          '也可以点右上角立刻检查。';
    }
    // ⭐ F7.16 真机结论：这台机器后台唤醒被 ROM 拦死（实测闹钟与广播都被吞），
    // 且支付通知只活 26 秒 → **唯一的可靠时机就是用户自己打开本 App**。
    // 这段话必须说清楚，否则用户以为「后台在记」，结果漏账还不知道为什么。
    if (d.postedChannelUnavailable && d.tickCatchUpTotal == 0) {
      // 走到这里说明补抓通道是活的（上面那条 catchUpChannelDead 已经拦掉了不通的情况），
      // 「打开 App 一次」才真的能补记 —— 文案别越过证据。
      return '这台手机的后台自动记账被系统限制了（国产 ROM 常见），但补记通道还在 ——'
          '支付后请打开本 App 一次，会把通知栏里还在的账单补记上。';
    }
    if (d.postedChannelUnavailable) {
      return '系统不投递实时通知（国产 ROM 常见），已改由定时补抓采集 ——'
          '支付后最多等一分钟就会记上。';
    }
    return '链路正常：捕获与入账都在工作。支付后回到本 App 就能看到结果。';
  }

  /// 相对时间（以原生侧返回的 `nowMs` 为基准，避免两端时钟口径不一致）。
  static String _ago(int nowMs, int atMs) {
    if (atMs <= 0) return '从未';
    final int diff = nowMs - atMs;
    if (diff < 60 * 1000) return '刚刚';
    if (diff < 60 * 60 * 1000) return '${diff ~/ 60000} 分钟前';
    if (diff < 24 * 60 * 60 * 1000) return '${diff ~/ 3600000} 小时前';
    return '${diff ~/ 86400000} 天前';
  }

  static String _pkgName(String pkg) => switch (pkg) {
    'com.tencent.mm' => '微信',
    'com.eg.android.AlipayGphone' => '支付宝',
    _ => '',
  };
}


/// 「后台常驻」卡片（F7.22）：开关 + 两行系统状态与入口。
///
/// 为什么要把「省电优化 / 自启动」摆在开关下面：开关只负责**我们这一侧**（起前台服务 + 自愈），
/// 但 MIUI 能不能真的留住进程，还取决于系统那两项 —— 用户看不到它们，就会觉得开关没用。
class _KeepAliveBlock extends StatelessWidget {
  const _KeepAliveBlock({
    required this.enabled,
    required this.running,
    required this.batteryIgnored,
    required this.loading,
    required this.onToggle,
    required this.onOpenBattery,
    required this.onOpenAutoStart,
  });

  final bool enabled;
  final bool running;
  final bool batteryIgnored;
  final bool loading;
  final ValueChanged<bool> onToggle;
  final VoidCallback onOpenBattery;
  final VoidCallback onOpenAutoStart;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(Icons.battery_saver_rounded, size: 20, color: p.ink),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '后台常驻',
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w800,
                      color: p.ink,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    enabled
                        ? (running ? '常驻服务运行中 · 通知栏会有一条待命提示' : '已开启，但服务没跑起来（多半被系统挡了）')
                        : '关：App 不在后台时，支付通知可能收不到',
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.4,
                      fontWeight: FontWeight.w600,
                      color: running || !enabled ? p.ink2 : p.red,
                    ),
                  ),
                ],
              ),
            ),
            Switch(
              value: enabled,
              onChanged: loading ? null : onToggle,
            ),
          ],
        ),
        if (enabled) ...<Widget>[
          const ToonDashedLine(),
          _GuideRow(
            title: '省电优化',
            ok: batteryIgnored,
            okText: '已忽略（系统不会随便回收）',
            badText: '未忽略 —— 点这里设为「无限制」',
            onTap: onOpenBattery,
          ),
          const ToonDashedLine(),
          _GuideRow(
            title: '自启动',
            ok: true,
            okText: '点这里去系统里确认',
            badText: '点这里去系统里确认',
            onTap: onOpenAutoStart,
            neutral: true,
          ),
        ],
      ],
    );
  }
}

/// 一行「系统侧设置」：左侧标题，右侧状态文案 + 箭头；点整行进设置。
class _GuideRow extends StatelessWidget {
  const _GuideRow({
    required this.title,
    required this.ok,
    required this.okText,
    required this.badText,
    required this.onTap,
    this.neutral = false,
  });

  final String title;
  final bool ok;
  final String okText;
  final String badText;
  final VoidCallback onTap;

  /// true = 没有「好坏」之分，只是入口（如自启动）。
  final bool neutral;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: p.ink2,
                ),
              ),
            ),
            Flexible(
              child: Text(
                neutral ? okText : (ok ? okText : badText),
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: neutral || ok ? p.ink2 : p.red,
                ),
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right_rounded, size: 16, color: p.ink3),
          ],
        ),
      ),
    );
  }
}
