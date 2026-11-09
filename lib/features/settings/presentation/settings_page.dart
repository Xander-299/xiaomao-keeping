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
import 'package:yanxin/core/theme/tokens.dart';
import 'package:yanxin/core/theme/toon.dart';
import 'package:yanxin/features/settings/application/theme_controller.dart';
import 'package:yanxin/ui_kit/app_settings_tile.dart';

/// 设置。
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ToonPalette p = context.toon;
    // 还没读出来时按默认「跟随系统」显示选中态（与 MaterialApp 的回落一致）
    final ToonThemeMode mode =
        ref.watch(themeModeProvider).value ?? ToonThemeMode.system;
    final ToonSeed seed =
        ref.watch(themeSeedProvider).value ?? ToonSeed.forest;

    return Scaffold(
      // 设置页用纯卡片底色（与「我的」一致），不是全局暖白画布
      backgroundColor: p.paper,
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: <Widget>[
          const ToonSectionTitle(title: '外观'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
            child: ToonCard(
              padding: const EdgeInsets.all(6),
              clip: true,
              child: Column(
                children: <Widget>[
                  for (final ToonThemeMode m in ToonThemeMode.values)
                    _ModeRow(
                      mode: m,
                      selected: m == mode,
                      onTap: () =>
                          ref.read(themeModeProvider.notifier).select(m),
                    ),
                ],
              ),
            ),
          ),
          const ToonSectionTitle(title: '主题色'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
            child: ToonCard(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                runSpacing: 10,
                children: <Widget>[
                  for (final ToonSeed s in ToonSeed.values)
                    _SeedSwatch(
                      seed: s,
                      selected: s == seed,
                      onTap: () =>
                          ref.read(themeSeedProvider.notifier).select(s),
                    ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
            child: Text(
              '· 默认「跟随系统」：手机切到深色，App 立刻跟着变\n'
              '· 主题色只换品牌色系（按钮 / 选中态 / 图表），版式不变\n'
              '· 选择会记住，下次打开还是这一项\n'
              '· 只影响本机外观，不影响账本数据',
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
        ],
      ),
    );
  }
}

/// 单个外观选项行：图标 + 标题 / 说明 + 右侧选中态。
class _ModeRow extends StatelessWidget {
  const _ModeRow({
    required this.mode,
    required this.selected,
    required this.onTap,
  });

  final ToonThemeMode mode;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    return Semantics(
      button: true,
      selected: selected,
      child: ToonPress(
        // 标题与副标题文本会互相包含（「深色」也是「一直使用深色」的子串），
        // 测试靠这个 key 定位行，不靠文本。
        key: ValueKey<String>('themeMode_${mode.name}'),
        dx: 2,
        dy: 2,
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.only(top: 4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            color: selected ? p.brandTint : Colors.transparent,
            borderRadius: BorderRadius.circular(Tok.rMd),
            border: Border.all(
              color: selected ? p.ink : Colors.transparent,
              width: 2,
            ),
            boxShadow: selected ? p.hard(d: 2.5) : null,
          ),
          child: Row(
            children: <Widget>[
              Icon(
                mode.icon,
                size: 22,
                color: selected ? p.brandDeep : p.ink2,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      mode.label,
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w800,
                        color: p.ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      mode.hint,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: p.ink2,
                      ),
                    ),
                  ],
                ),
              ),
              // 选中态不只靠颜色：实心对勾 + 空心圆，语义上也带 selected
              Icon(
                selected
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 22,
                color: selected ? p.brandDeep : p.ink3,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 一个主题色圆点：色块 + 名称，选中加墨圈与对勾。
///
/// 只换 seed（不预览整页），所以这里直接铺 `seed.seed` 那个原始色 ——
/// 它和 `ColorScheme.fromSeed` 派生出的 primary 有色差，但作为「选哪个种子」的示意更直观。
class _SeedSwatch extends StatelessWidget {
  const _SeedSwatch({
    required this.seed,
    required this.selected,
    required this.onTap,
  });

  final ToonSeed seed;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    return Semantics(
      button: true,
      selected: selected,
      label: seed.label,
      child: InkWell(
        // 测试按 key 定位（中文名在别处也可能出现）
        key: ValueKey<String>('themeSeed_${seed.name}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(Tok.rMd),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: seed.seed,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected ? p.ink : p.line,
                    width: selected ? 2.5 : 1,
                  ),
                ),
                child: selected
                    ? Icon(
                        Icons.check_rounded,
                        size: 19,
                        color: p.inkOn(seed.seed),
                      )
                    : null,
              ),
              const SizedBox(height: 6),
              Text(
                seed.label,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  color: selected ? p.ink : p.ink2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
