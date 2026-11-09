/// 「首页布局」设置页：显示/隐藏 + 拖拽排序。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:yanxin/core/theme/toon.dart';
import 'package:yanxin/ui_kit/app_page_state.dart';

import 'dashboard_config.dart';
import 'dashboard_config_controller.dart';
import 'dashboard_module.dart';
import 'dashboard_registry.dart';

class DashboardLayoutPage extends ConsumerWidget {
  const DashboardLayoutPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ToonPalette p = context.toon;
    final AsyncValue<DashboardConfig> configAsync = ref.watch(
      dashboardConfigProvider,
    );

    return Scaffold(
      backgroundColor: p.paper,
      appBar: AppBar(
        title: const Text('首页布局'),
        actions: <Widget>[
          TextButton(
            onPressed: () async {
              await ref.read(dashboardConfigProvider.notifier).reset();
              if (context.mounted) {
                showToonSuccess(context, '已恢复默认首页布局');
              }
            },
            child: const Text('恢复默认'),
          ),
        ],
      ),
      body: configAsync.when(
        loading: () => const AppPageLoading(),
        error: (Object e, StackTrace _) => AppPageError(error: e),
        data: (DashboardConfig config) => _LayoutList(config: config),
      ),
    );
  }
}

class _LayoutList extends ConsumerWidget {
  const _LayoutList({required this.config});

  final DashboardConfig config;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ToonPalette p = context.toon;
    final List<String> order = DashboardRegistry.effectiveOrderIds(config);
    final Set<String> enabled = DashboardRegistry.effectiveEnabledIds(config);
    final Map<String, DashboardModule> byId = <String, DashboardModule>{
      for (final DashboardModule m in DashboardRegistry.modules) m.id: m,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
          child: Text(
            '拖动手柄调整顺序；开关控制是否在首页显示。「本月收支」和「本月账单」为必选。',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: p.ink2,
              height: 1.5,
            ),
          ),
        ),
        Expanded(
          child: ReorderableListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            buildDefaultDragHandles: false,
            itemCount: order.length,
            onReorderItem: (int oldIndex, int newIndex) {
              final List<String> next = <String>[...order];
              final String moved = next.removeAt(oldIndex);
              next.insert(newIndex, moved);
              unawaited(
                ref.read(dashboardConfigProvider.notifier).reorder(next),
              );
            },
            itemBuilder: (BuildContext context, int index) {
              final String id = order[index];
              final DashboardModule? module = byId[id];
              if (module == null) return const SizedBox.shrink();
              final bool on = enabled.contains(id);
              return Padding(
                key: ValueKey<String>('dashboard_module_$id'),
                padding: const EdgeInsets.only(bottom: 8),
                child: Opacity(
                  opacity: on ? 1 : 0.55,
                  child: ToonCard(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    child: Row(
                      children: <Widget>[
                        ReorderableDragStartListener(
                          index: index,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 8,
                            ),
                            child: Icon(
                              Icons.drag_indicator_rounded,
                              size: 20,
                              color: p.ink3,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                module.title,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                module.canHide
                                    ? module.description
                                    : '${module.description} · 必选',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                  color: p.ink2,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Switch(
                          key: ValueKey<String>('dashboard_switch_$id'),
                          value: on || !module.canHide,
                          onChanged: module.canHide
                              ? (bool value) => unawaited(
                                  ref
                                      .read(dashboardConfigProvider.notifier)
                                      .setEnabled(id, value),
                                )
                              : null,
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
