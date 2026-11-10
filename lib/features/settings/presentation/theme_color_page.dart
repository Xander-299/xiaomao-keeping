/// 「主题色」子页：五色单选（琥珀默认排第一）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:yanxin/core/theme/theme_seed.dart';
import 'package:yanxin/core/theme/toon.dart';
import 'package:yanxin/features/settings/application/theme_controller.dart';

class ThemeColorPage extends ConsumerWidget {
  const ThemeColorPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ToonPalette p = context.toon;
    final ToonSeed seed =
        ref.watch(themeSeedProvider).value ?? ToonSeed.amber;

    return Scaffold(
      backgroundColor: p.paper,
      appBar: AppBar(title: const Text('主题色')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
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
              '· 默认「琥珀」（排第一，与启动图标橙底对齐）\n'
              '· 只换品牌色系，版式不变；选择会记住',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: p.ink2,
                height: 1.7,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 单个主题色圆点 + 名称；选中带对勾。
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
      child: ToonPress(
        key: ValueKey<String>('themeSeed_${seed.name}'),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Column(
            children: <Widget>[
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: seed.seed,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected ? p.ink : Colors.transparent,
                    width: 2,
                  ),
                  boxShadow: selected ? p.hard(d: 2.5) : null,
                ),
                child: selected
                    ? Icon(Icons.check_rounded, size: 22, color: p.paper)
                    : null,
              ),
              const SizedBox(height: 6),
              Text(
                seed.label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
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
