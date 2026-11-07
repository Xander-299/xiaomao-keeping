/// 「自动记账」设置页（路由 `/autobook`，F7.15 SPEC §3.2 / §3.6）。
///
/// 职责：
/// 1. 显示**权限状态**（通知使用权 / 通知权限）并提供一键跳转 —— 通知使用权不弹系统对话框，
///    用户必须自己去系统设置开，所以这一页是**成败关键**；
/// 2. 「最近一次自动记账」+ 撤销（**不依赖通知**的兜底入口，通知被系统屏蔽时仍可用）；
/// 3. 说明识别范围、忽略规则与隐私（本 App 无 `INTERNET` 权限，数据只落本地）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yanxin/core/providers/data_epoch.dart';
import 'package:yanxin/core/theme/toon.dart';
import 'package:yanxin/core/utils/money.dart';
import 'package:yanxin/data/providers/database.dart';
import 'package:yanxin/features/autobook/application/auto_book_controller.dart';
import 'package:yanxin/features/autobook/application/auto_book_notice.dart';
import 'package:yanxin/features/autobook/data/auto_book_batches.dart';
import 'package:yanxin/features/autobook/data/auto_book_bridge.dart';
import 'package:yanxin/features/autobook/data/auto_book_diagnostics.dart';

part 'widgets/autobook_status_row.dart';
part 'widgets/autobook_blocks.dart';
part 'widgets/autobook_info_line.dart';

/// 「通知使用权」是否已开启（原生侧实时查系统设置）。
final autoBookListenerEnabledProvider = FutureProvider<bool>(
  (Ref ref) => ref.watch(autoBookBridgeProvider).listenerEnabled(),
);

/// 通知权限是否允许（Android 13+ 含 `POST_NOTIFICATIONS`）。
final autoBookNotificationsAllowedProvider = FutureProvider<bool>(
  (Ref ref) => ref.watch(autoBookBridgeProvider).notificationsAllowed(),
);

/// 最近一批自动记账（含跨启动的批次，来自 `schema_meta` KV）。
final autoBookLatestBatchProvider = FutureProvider<AutoBookBatch?>((Ref ref) {
  ref.watch(dataEpochProvider);
  return ref.watch(autoBookBatchStoreProvider).latest();
});

/// 原生侧活性诊断（服务是否被绑定 / 抓到过几条 / 上次 drain 情况）。
final autoBookDiagnosticsProvider = FutureProvider<AutoBookDiagnostics?>(
  (Ref ref) => ref.watch(autoBookBridgeProvider).diagnostics(),
);

/// 已捕获但还没入账的条数（原生落盘队列里剩余的）。
final autoBookPendingCountProvider = FutureProvider<int>(
  (Ref ref) => ref.watch(autoBookBridgeProvider).pendingCount(),
);

/// 最近一次检查结果（KV，跨启动可见）—— 让「上次到底干了什么」可查。
final autoBookLastRunProvider = FutureProvider<AutoBookLastRun?>((Ref ref) async {
  ref.watch(dataEpochProvider);
  final String? raw = await ref
      .watch(appMetaRepositoryProvider)
      .get(kAutoBookLastRunKey);
  return AutoBookLastRun.parse(raw);
});

class AutoBookPage extends ConsumerStatefulWidget {
  const AutoBookPage({super.key});

  @override
  ConsumerState<AutoBookPage> createState() => _AutoBookPageState();
}

class _AutoBookPageState extends ConsumerState<AutoBookPage>
    with WidgetsBindingObserver {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 从系统设置返回后自动刷新状态（用户不用手动刷新）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshStatus();
    }
  }

  void _refreshStatus() {
    ref.invalidate(autoBookListenerEnabledProvider);
    ref.invalidate(autoBookNotificationsAllowedProvider);
    ref.invalidate(autoBookLatestBatchProvider);
    ref.invalidate(autoBookDiagnosticsProvider);
    ref.invalidate(autoBookPendingCountProvider);
    ref.invalidate(autoBookLastRunProvider);
  }

  Future<void> _openSettings() async {
    await ref.read(autoBookBridgeProvider).openListenerSettings();
  }

  Future<void> _requestNotifications() async {
    await ref.read(autoBookBridgeProvider).requestNotificationPermission();
    _refreshStatus();
  }

  /// 手动跑一次 drain（走查用：`adb shell cmd notification post` 之后点这里）。
  Future<void> _checkNow() async {
    if (_busy) return;
    setState(() => _busy = true);
    final AutoBookDrainResult r = await ref
        .read(autoBookControllerProvider)
        .drain();
    _refreshStatus();
    if (!mounted) return;
    setState(() => _busy = false);
    final String msg;
    if (r.imported > 0) {
      msg = '新入账 ${r.imported} 笔';
    } else if (r.undone > 0) {
      msg = '已撤销 ${r.undone} 笔';
    } else if (r.restored) {
      msg = '暂时无法入账，已保留待下次重试';
    } else {
      msg = '没有新的支付通知';
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
      );
  }

  Future<void> _undoLatest(AutoBookBatch batch) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text('撤销这 ${batch.count} 笔？'),
        content: const Text('会自动删除这一批自动记账的流水，不影响你手工记的账。'),
        actions: <Widget>[
          ToonButton(
            small: true,
            kind: ToonButtonKind.ghost,
            label: '算了',
            onPressed: () => Navigator.of(dialogContext).pop(false),
          ),
          ToonButton(
            small: true,
            kind: ToonButtonKind.danger,
            label: '撤销',
            onPressed: () => Navigator.of(dialogContext).pop(true),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final ToonPalette palette = context.toon;
    final int deleted;
    try {
      deleted = await ref
          .read(autoBookNoticeProvider.notifier)
          .undo(batch.batchId);
    } catch (_) {
      showToonErrorOnMessenger(
        messenger: messenger,
        palette: palette,
        message: '撤销失败，已保留这一批，请重试',
      );
      return;
    }
    showToonFeedbackOnMessenger(
      messenger: messenger,
      palette: palette,
      message: deleted > 0 ? '已撤销 $deleted 笔' : '这批已撤销或不复存在',
      kind: deleted > 0 ? ToonFeedbackKind.success : ToonFeedbackKind.info,
    );
  }

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    final AsyncValue<bool> listener = ref.watch(autoBookListenerEnabledProvider);
    final AsyncValue<bool> notify = ref.watch(
      autoBookNotificationsAllowedProvider,
    );
    final AsyncValue<AutoBookBatch?> latest = ref.watch(
      autoBookLatestBatchProvider,
    );
    final AsyncValue<AutoBookDiagnostics?> diag = ref.watch(
      autoBookDiagnosticsProvider,
    );
    final AsyncValue<int> pending = ref.watch(autoBookPendingCountProvider);
    final AsyncValue<AutoBookLastRun?> lastRun = ref.watch(
      autoBookLastRunProvider,
    );

    final bool listenerOn = listener.value ?? false;

    return Scaffold(
      backgroundColor: p.paper,
      appBar: AppBar(
        title: const Text('自动记账'),
        actions: <Widget>[
          ToonIconButton(
            icon: Icons.refresh_rounded,
            tooltip: '检查一次',
            onPressed: _busy ? null : _checkNow,
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 28),
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: ToonCard(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _StatusRow(
                    icon: Icons.notifications_active_outlined,
                    title: '通知使用权',
                    ok: listenerOn,
                    okText: '已开启',
                    badText: listener.isLoading ? '检查中…' : '未开启',
                  ),
                  const ToonDashedLine(),
                  _StatusRow(
                    icon: Icons.chat_bubble_outline_rounded,
                    title: '通知权限',
                    ok: notify.value ?? false,
                    okText: '已允许',
                    badText: notify.isLoading ? '检查中…' : '未允许',
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: ToonButton(
                          small: true,
                          kind: listenerOn
                              ? ToonButtonKind.tonal
                              : ToonButtonKind.primary,
                          icon: Icons.settings_outlined,
                          label: listenerOn ? '重新设置' : '去开启',
                          onPressed: _openSettings,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ToonButton(
                          small: true,
                          kind: ToonButtonKind.ghost,
                          icon: Icons.notifications_none_rounded,
                          label: '通知权限',
                          onPressed: _requestNotifications,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    listenerOn
                        ? '已开启：微信 / 支付宝的支付通知会被识别，打开 App 时自动入账。'
                        : '未开启时不会有任何后台行为 —— 不会监听、不会记账。'
                              '开启后本 App 只读「支付通知」的文案，数据只落本机。',
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.5,
                      fontWeight: FontWeight.w600,
                      color: p.ink2,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const ToonSectionTitle(title: '最近一次自动记账'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: ToonCard(
              color: p.canvas2,
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
              child: _LatestBatchBlock(
                batch: latest.value,
                loading: latest.isLoading,
                onUndo: _undoLatest,
              ),
            ),
          ),
          const ToonSectionTitle(title: '诊断'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: ToonCard(
              color: p.canvas2,
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: _DiagnosticsBlock(
                listenerOn: listenerOn,
                diag: diag.value,
                pending: pending.value,
                lastRun: lastRun.value,
                loading: diag.isLoading || pending.isLoading,
              ),
            ),
          ),
          const ToonSectionTitle(title: '识别范围'),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: ToonCard(
              padding: EdgeInsets.fromLTRB(14, 4, 14, 4),
              child: Column(
                children: <Widget>[
                  _InfoLine('支持平台', '微信、支付宝（银行 / 云闪付等后续支持）'),
                  ToonDashedLine(),
                  _InfoLine('会记账', '支付成功、付款成功、扣款、消费、收款到账'),
                  ToonDashedLine(),
                  _InfoLine(
                    '会忽略',
                    '转账、红包、退款、优惠、充值成功、验证码、账单汇总、活动、积分、提醒',
                  ),
                  ToonDashedLine(),
                  _InfoLine('零权限兜底', '在微信 / 支付宝里「分享」账单文本到本 App 也能记'),
                ],
              ),
            ),
          ),
          const ToonSectionTitle(title: '隐私'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: ToonCard(
              color: p.brandTint,
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Text(
                '本 App 没有申请网络权限（Android 没有 INTERNET 权限就发不出任何数据）。'
                '通知文案、账单、流水全部只存在这台手机上，不上传、不联网。',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  fontWeight: FontWeight.w600,
                  color: p.brandInk,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '识别不准？自动记账的每一笔都能在首页提示条或上面这块「撤销」，'
              '也可以在流水里逐笔改分类。',
              style: TextStyle(
                fontSize: 11.5,
                height: 1.6,
                fontWeight: FontWeight.w600,
                color: p.ink3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
