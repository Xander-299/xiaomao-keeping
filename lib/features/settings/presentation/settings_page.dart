/// 设置页（F7.17 起）：外观 = 浅色 / 深色 / 跟随系统。
///
/// 本批**只做外观**：「默认账户 / 货币单位」尚未实现，就不放占位行（假入口比没有更糟）。
/// 视觉沿用 F7.6 卡通语言：`ToonCard` 包三行单选，选中行 = 品牌浅底 + 墨色描边 + 硬阴影。
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
    // 云同步（P6.2）：未登录也可能有上次的邮箱，副标题必须说清当前状态
    final AuthState auth =
        ref.watch(authControllerProvider).value ?? const AuthState();
    final bool syncOn =
        ref.watch(cloudSyncEnabledProvider).value ?? false;
    final String cloudSubtitle = auth.signedIn
        ? '已登录${auth.email == null ? '' : ' ${auth.email}'} · '
              '${syncOn ? '同步已开启' : '同步已关闭'}'
        : '未登录 · 登录后可备份 / 换机恢复';

    return Scaffold(
      // 设置页用纯卡片底色（与「我的」一致），不是全局暖白画布
      backgroundColor: p.paper,
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: <Widget>[
          // 不另加分区标题：卡片本身就叫「界面外观」，再加一行是重复
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: ToonCard(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              clip: true,
              child: AppSettingsTile(
                icon: Icons.palette_rounded,
                title: '界面外观',
                // 副标题直接给出当前两项的值，不用点进去才知道
                subtitle: '${mode.label} · ${seed.label} 主题色',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const LookAndFeelPage()),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Text(
              '· 默认「浅色」+「琥珀」\n'
              '· 主题色只换品牌色系（按钮 / 选中态 / 图表），版式不变\n'
              '· 选择会记住；只影响本机外观，不动账本数据',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: p.ink2,
                height: 1.7,
              ),
            ),
          ),
          const ToonSectionTitle(title: '首页'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
            child: ToonCard(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              clip: true,
              child: AppSettingsTile(
                icon: Icons.dashboard_customize_rounded,
                title: '首页布局',
                subtitle: '显示 / 隐藏与排序首页模块',
                onTap: () => context.push('/dashboard-layout'),
              ),
            ),
          ),
          const ToonSectionTitle(title: '数据'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
            child: ToonCard(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              clip: true,
              child: AppSettingsTile(
                icon: Icons.cloud_sync_rounded,
                title: '云同步',
                subtitle: cloudSubtitle,
                // 测试里没有 GoRouter → 与外观子页同款，用 Navigator.push
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const CloudSyncPage()),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
