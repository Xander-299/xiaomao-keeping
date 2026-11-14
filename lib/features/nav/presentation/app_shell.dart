/// 底部导航壳：4 tab + 中央「记一笔」按钮（卡通风，对齐页面原型 `.tabbar`）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:yanxin/core/theme/tokens.dart';
import 'package:yanxin/core/theme/toon.dart';
import 'package:yanxin/features/autobook/application/auto_book_controller.dart';
import 'package:yanxin/features/ledger/presentation/widgets/book_drawer.dart';
import 'package:yanxin/features/onboarding/application/onboarding_prompt.dart';
import 'package:yanxin/features/sync/application/sync_trigger.dart';

/// 导航壳：持有抽屉（账本列表）+ 底栏。
///
/// F7.14 起兼任**新手引导的首启触发点**：首帧后查一次 [onboardingPromptProvider]，
/// 判定该弹就 push `/onboarding`。**不阻塞首帧** —— 首页照常构建，引导盖在其上。
///
/// F7.15 起兼任**自动记账队列的消费触发点**：首帧后 + 每次 `resumed` 各 drain 一次
/// （Kotlin 侧只落盘，入账必须回到 Dart —— drift 是唯一 DB writer）。
/// drain **失败静默**：它是锦上添花，绝不能阻断冷启动或前台切换。
///
/// P6.4b 起再加**自动同步**的触发点：首帧后一次（冷启动）+ 每次 `resumed` 一次。
/// 是否真的跑由 `SyncTrigger` 判定（5 分钟节流 / 仅 WiFi / 闸门），这里只负责「叫一声」；
/// 它同样静默失败，且**不阻塞首帧**。
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> with WidgetsBindingObserver {
  /// 只查一次（State 跨 tab 切换存活，不会因为切分支重复弹）。
  bool _checkedOnboarding = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback(
      (Duration _) => unawaited(_onFirstFrame()),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 从后台回到前台：把 App 外出期间捕获的支付通知补记上。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_drainAutoBook());
      unawaited(_autoSync('回前台'));
    }
  }

  Future<void> _onFirstFrame() async {
    await _maybeShowOnboarding();
    await _drainAutoBook();
    // 冷启动：先同步增量，再看要不要补一份全量备份（都静默、都不阻塞）
    await _autoSync('冷启动');
    unawaited(_autoBackup());
  }

  /// 自动同步（P6.4b）：是否真的跑交给 [SyncTrigger] 判定；异常一律吞掉。
  Future<void> _autoSync(String reason) async {
    if (!mounted) return;
    try {
      await ref.read(syncTriggerProvider).maybeSync(reason: reason);
    } catch (_) {
      // 自动同步失败绝不冒泡到 UI
    }
  }

  /// 自动备份（P6.4b D5）：只在冷启动调用。
  Future<void> _autoBackup() async {
    if (!mounted) return;
    try {
      await ref.read(syncTriggerProvider).maybeAutoBackup();
    } catch (_) {
      // 同上
    }
  }

  /// 消费自动记账队列（幂等 + 静默失败）。
  Future<void> _drainAutoBook() async {
    if (!mounted) return;
    try {
      await ref.read(autoBookControllerProvider).drain();
    } catch (_) {
      // 原生链路 / 解析异常都不得冒泡到 UI
    }
  }

  Future<void> _maybeShowOnboarding() async {
    if (_checkedOnboarding || !mounted) return;
    _checkedOnboarding = true;
    final bool shouldShow;
    try {
      shouldShow = await ref.read(onboardingPromptProvider.future);
    } catch (_) {
      // 读库失败不阻断冷启动（引导是锦上添花）
      return;
    }
    if (!shouldShow || !mounted) return;
    unawaited(context.push('/onboarding'));
  }

  @override
  Widget build(BuildContext context) {
    final StatefulNavigationShell shell = widget.navigationShell;
    return Scaffold(
      drawer: const BookDrawer(),
      body: shell,
      bottomNavigationBar: _BottomNav(
        currentIndex: shell.currentIndex,
        onTap: (int slot) {
          switch (slot) {
            case 0:
              shell.goBranch(0, initialLocation: true);
            case 1:
              shell.goBranch(1, initialLocation: true);
            case 2: // 中央 +：记一笔（保存后的首页刷新由记一笔页自己触发）
              context.push('/record');
            case 3:
              shell.goBranch(2, initialLocation: true);
            case 4:
              shell.goBranch(3, initialLocation: true);
          }
        },
      ),
    );
  }
}

class _BottomNav extends StatelessWidget {
  const _BottomNav({required this.currentIndex, required this.onTap});

  final int currentIndex;
  final ValueChanged<int> onTap;

  static const List<String> _labels = <String>['首页', '日历', '', '资产', '我的'];
  static const List<IconData> _icons = <IconData>[
    Icons.home_rounded,
    Icons.calendar_today_rounded,
    Icons.add,
    Icons.account_balance_wallet_rounded,
    Icons.person_rounded,
  ];

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    return Container(
      decoration: BoxDecoration(
        color: p.paper,
        border: Border(top: BorderSide(color: p.ink, width: Tok.bw)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 68,
          child: Row(
            children: <Widget>[
              for (int slot = 0; slot < 5; slot++)
                Expanded(
                  child: slot == 2
                      ? _CenterAddButton(onTap: () => onTap(2))
                      : _NavItem(
                          icon: _icons[slot],
                          label: _labels[slot],
                          selected: _branchIndex(slot) == currentIndex,
                          onTap: () => onTap(slot),
                        ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 槽位 → 分支 index（中央 + 不是分支）。
  static int _branchIndex(int slot) => slot < 2 ? slot : slot - 1;
}

/// 单个 tab：选中时图标变成一颗「品牌色 + 描边 + 硬阴影」的圆角方块。
class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    // 图标画在**品牌色块**上 → onBrand；
    // 但标签画在**纸底**上 —— 深色主题下纸底是近黑，用 onBrand 等于深棕压深黑（~1.1:1，看不见）。
    // 标签改用 brandInk：浅色下与 onBrand 同值（视觉不变），深色下是亮绿。
    final Color iconColor = selected ? p.onBrand : p.ink3;
    final Color labelColor = selected ? p.brandInk : p.ink3;
    return ToonPress(
      dx: 0,
      dy: 0,
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.all(3),
            decoration: selected
                ? BoxDecoration(
                    color: p.brand,
                    borderRadius: BorderRadius.circular(11),
                    // 实心底 → 描边跟着底色走（深色下 p.ink 是暖白，会整条消失）
                    border: p.inkBorder(w: 2, on: p.brand),
                    boxShadow: p.hard(d: 2),
                  )
                : BoxDecoration(
                    borderRadius: BorderRadius.circular(11),
                    border: Border.all(color: Colors.transparent, width: 2),
                  ),
            child: Icon(icon, size: 22, color: iconColor),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              height: 1,
              fontWeight: FontWeight.w700,
              color: labelColor,
            ),
          ),
        ],
      ),
    );
  }
}

/// 中央「记一笔」：品牌色圆角方块 + 描边 + 硬阴影，默认歪 4°（原型 `.tab.mid .fab`）。
class _CenterAddButton extends StatelessWidget {
  const _CenterAddButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    return Center(
      child: Tooltip(
        message: '记一笔',
        child: ToonPress(
          onTap: onTap,
          child: Transform.rotate(
            angle: -4 * 3.1415926535 / 180,
            child: Container(
              width: 54,
              height: 48,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: p.brand,
                borderRadius: BorderRadius.circular(17),
                // 同上：brand 底 → 描边跟着底色走
                border: p.inkBorder(on: p.brand),
                boxShadow: p.hard(d: 4),
              ),
              child: Icon(Icons.add, size: 27, color: p.onBrand),
            ),
          ),
        ),
      ),
    );
  }
}
