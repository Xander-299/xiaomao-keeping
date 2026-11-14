/// 设置页：外观 / 首页布局 / 云同步，收进**一张卡的三行**。
///
/// 2026-11-14：三张独立卡片 + 三段解释文案太碎；合并成一张卡、等距三行、
/// 只保留一句脚注（「只影响本机」与「云同步默认关闭」）。视觉仍用 Toon/M3 体系。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:yanxin/core/theme/theme_mode.dart';
import 'package:yanxin/core/theme/theme_seed.dart';
import 'package:yanxin/core/theme/toon.dart';
import 'package:yanxin/features/settings/application/theme_controller.dart';
import 'package:yanxin/features/settings/presentation/look_and_feel_page.dart';
import 'package:yanxin/features/sync/application/auth_controller.dart';
import 'package:yanxin/features/sync/presentation/cloud_sync_page.dart';
import 'package:yanxin/ui_kit/app_settings_tile.dart';

/// 设置。
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ToonPalette p = context.toon;
    // 还没读出来时按默认「浅色」显示选中态（与 MaterialApp 的回落一致）
    final ToonThemeMode mode =
        ref.watch(themeModeProvider).value ?? ToonThemeMode.light;
    final ToonSeed seed =
        ref.watch(themeSeedProvider).value ?? ToonSeed.amber;
    // 云同步：副标题只给「登录 + 开关」两个状态，账号详情进子页看
    final AuthState auth =
        ref.watch(authControllerProvider).value ?? const AuthState();
    final bool syncOn = ref.watch(cloudSyncEnabledProvider).value ?? false;
    final String cloudSubtitle = auth.signedIn
        ? (syncOn ? '已登录 · 同步已开启' : '已登录 · 同步已关闭')
        : '未登录';

    return Scaffold(
      // 设置页用纯卡片底色（与「我的」一致），不是全局暖白画布
      backgroundColor: p.paper,
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: ToonCard(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              clip: true,
              child: Column(
                children: <Widget>[
                  AppSettingsTile(
                    icon: Icons.palette_rounded,
                    title: '界面外观',
                    subtitle: '${mode.label} · ${seed.label}',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const LookAndFeelPage(),
                      ),
                    ),
                  ),
                  _SettingsDivider(color: p.line),
                  AppSettingsTile(
                    icon: Icons.dashboard_customize_rounded,
                    title: '首页布局',
                    subtitle: '模块显示与排序',
                    onTap: () => context.push('/dashboard-layout'),
                  ),
                  _SettingsDivider(color: p.line),
                  AppSettingsTile(
                    icon: Icons.cloud_sync_rounded,
                    title: '云同步',
                    subtitle: cloudSubtitle,
                    // 测试里没有 GoRouter → 与外观子页同款，用 Navigator.push
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const CloudSyncPage(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Text(
              '· 云同步默认关闭，不登录不发请求',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: p.ink2,
                height: 1.6,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 行间分隔线：与图标右缘对齐（不穿过图标），比整块卡片切三份更轻。
class _SettingsDivider extends StatelessWidget {
  const _SettingsDivider({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) =>
      Divider(height: 1, indent: 64, color: color);
}
