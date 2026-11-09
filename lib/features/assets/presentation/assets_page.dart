/// 资产页：净资产卡 + 账户余额列表（底栏第 4 个 tab）。
///
/// 数据源全部真实（账户表 + 全量流水），口径见 `docs/spec/SPEC-F7.5-assets.md` §3.2：
/// 余额 = 初始余额 + Σ收入 − Σ支出，transfer 不计。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:yanxin/core/theme/tokens.dart';
import 'package:yanxin/core/theme/toon.dart';
import 'package:yanxin/core/utils/money.dart';
import 'package:yanxin/ui_kit/app_page_state.dart';

import '../application/account_meta.dart';
import '../application/asset_aggregate.dart';
import '../application/assets_controller.dart';
import 'widgets/account_form_sheet.dart';

/// 资产页。
class AssetsPage extends ConsumerWidget {
  const AssetsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ToonPalette p = context.toon;
    final AsyncValue<AssetSummary> async = ref.watch(assetsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('资产'),
        actions: <Widget>[
          ToonIconButton(
            icon: Icons.add,
            tooltip: '新增账户',
            onPressed: () => showAccountFormSheet(context, ref),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: async.when(
        loading: () => const AppPageLoading(),
        error: (Object e, StackTrace _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Text(
                  '加载失败',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 6),
                Text(
                  '$e',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: p.ink2,
                  ),
                ),
                const SizedBox(height: 16),
                ToonButton(
                  label: '重试',
                  icon: Icons.refresh,
                  small: true,
                  onPressed: () => ref.invalidate(assetsProvider),
                ),
              ],
            ),
          ),
        ),
        data: (AssetSummary summary) {
          if (summary.items.isEmpty) return _EmptyState(ref: ref);
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: <Widget>[
              _NetWorthCard(summary: summary),
              const SizedBox(height: 12),
              for (final AssetItem item in summary.items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _AccountTile(item: item, ref: ref),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
                child: Text(
                  '余额 = 初始余额 + Σ收入 − Σ支出（转账不计入）',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: p.ink2,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 净资产卡：品牌浅底（原型 `.networth`）+ 大号金额 + 账户数。
class _NetWorthCard extends StatelessWidget {
  const _NetWorthCard({required this.summary});

  final AssetSummary summary;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    final bool negative = summary.netCents < 0;
    final Color color = negative ? p.red : p.brandDeep;
    return Card(
      color: p.brandTint,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '净资产',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: p.ink2,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '¥ ${centsToYuan(summary.netCents, group: true)}',
              style: TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.w900,
                height: 1.1,
                letterSpacing: -1,
                color: color,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '${summary.count} 个账户 · 全时间累计',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: p.ink2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 账户一行：图标 + 名称/类型 + 余额（+ 累计收支小字）。
class _AccountTile extends StatelessWidget {
  const _AccountTile({required this.item, required this.ref});

  final AssetItem item;
  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    final bool negative = item.balanceCents < 0;
    // 正余额用墨色（此前误用深色主题的 #E8E8E8，白卡上等于隐形）
    final Color balanceColor = negative ? p.red : p.ink;
    // 自选颜色是**用户数据**（不受主题影响），所以前景色按底色亮度选，
    // 不能直接用 p.ink —— 深色主题下 p.ink 是暖白，铺在亮粉/亮蓝上读不清。
    final Color avatarBg = accountAvatarColor(item.account.color, p);
    final Color avatarFg = p.inkOn(avatarBg);

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: p.cardDeco(),
      child: ToonPress(
        dx: 2,
        dy: 2,
        onTap: () => showAccountFormSheet(context, ref, account: item.account),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Row(
            children: <Widget>[
              // 原型 `.acct .a-ic`：品牌浅底 + 墨色描边 + 硬阴影
              Container(
                width: 42,
                height: 42,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  // 自选颜色优先；空串 / 非法值 = 类型默认底色（老数据行为不变）
                  color: avatarBg,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: p.ink, width: 2),
                  boxShadow: p.hard(d: 2),
                ),
                child: Icon(
                  accountIcon(item.account.icon, item.account.type),
                  size: 21,
                  color: avatarFg,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      item.account.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${accountTypeLabel(item.account.type)} · '
                      '收 ${centsToYuan(item.incomeCents)} / '
                      '支 ${centsToYuan(item.expenseCents)}',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: p.ink2,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Text(
                centsToYuan(item.balanceCents, group: true),
                style: TextStyle(
                  fontSize: 16.5,
                  fontWeight: FontWeight.w900,
                  color: balanceColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 空态：一个账户都没有。
class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.ref});

  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    // F7.6 P3：与日历空态统一成卡通空态（虚线圆 + 小猪 + 胶囊按钮），
    // 不再用 Material 图标 + FilledButton。
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 26),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ToonDashedBorder(
              circle: true,
              color: p.ink,
              thickness: Tok.bw,
              dash: 7,
              gap: 5,
              background: p.brandTint,
              child: SizedBox(
                width: 76,
                height: 76,
                child: Center(
                  child: Icon(Icons.account_balance_wallet_outlined, size: 34, color: p.brandInk),
                ),
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              '还没有账户',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Text(
              '建一个账户（现金 / 储蓄卡 / 支付宝…），就能看到净资产分布',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: p.ink2,
              ),
            ),
            const SizedBox(height: 16),
            ToonButton(
              label: '新建账户',
              icon: Icons.add,
              onPressed: () => showAccountFormSheet(context, ref),
            ),
          ],
        ),
      ),
    );
  }
}
