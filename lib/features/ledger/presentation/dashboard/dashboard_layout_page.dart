/// 「首页布局」设置页：模块树（展开/收起）+ 显示开关 + 拖拽排序。
///
/// 有内部组件的模块（如「本月预算 → 每天可花」）先折叠：点整行展开后
/// 才看到二级开关；二级开关与文字都比一级小一号，视觉上呈现树层级。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:yanxin/core/theme/toon.dart';
import 'package:yanxin/ui_kit/app_page_state.dart';

import 'dashboard_config.dart';
import 'dashboard_config_controller.dart';
import 'dashboard_module.dart';
import 'dashboard_param.dart';
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

class _LayoutList extends ConsumerStatefulWidget {
  const _LayoutList({required this.config});

  final DashboardConfig config;

  @override
  ConsumerState<_LayoutList> createState() => _LayoutListState();
}

class _LayoutListState extends ConsumerState<_LayoutList> {
  /// 展开的模块 id（有内部组件的模块默认折叠）。
  final Set<String> _expanded = <String>{};

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    final DashboardConfig config = widget.config;
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
            '拖动手柄调整顺序；开关控制是否在首页显示。'
            '带箭头的模块可展开控制内部组件；「本月收支」和「本月账单」为必选。',
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
              final bool hasChildren = module.childSpecs.isNotEmpty;
              final bool expanded = _expanded.contains(id);
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
                    child: Column(
                      children: <Widget>[
                        Row(
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
                            if (hasChildren)
                              IconButton(
                                key: ValueKey<String>('dashboard_expand_$id'),
                                visualDensity: VisualDensity.compact,
                                icon: Icon(
                                  expanded
                                      ? Icons.expand_less_rounded
                                      : Icons.expand_more_rounded,
                                  size: 20,
                                  color: p.ink2,
                                ),
                                tooltip: expanded ? '收起' : '展开内部组件',
                                onPressed: () => setState(() {
                                  if (expanded) {
                                    _expanded.remove(id);
                                  } else {
                                    _expanded.add(id);
                                  }
                                }),
                              )
                            else
                              const SizedBox(width: 40),
                            Switch(
                              key: ValueKey<String>('dashboard_switch_$id'),
                              value: on || !module.canHide,
                              onChanged: module.canHide
                                  ? (bool value) => unawaited(
                                      ref
                                          .read(
                                            dashboardConfigProvider.notifier,
                                          )
                                          .setEnabled(id, value),
                                    )
                                  : null,
                            ),
                          ],
                        ),
                        // 展开的内部组件：小号文字 + 小号开关（树层级视觉）
                        if (hasChildren && expanded && on)
                          for (final DashboardParamSpec spec
                              in module.childSpecs)
                            _ChildToggle(
                              key: ValueKey<String>(
                                'dashboard_child_${id}_${spec.id}',
                              ),
                              moduleId: id,
                              spec: spec,
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

/// 二级开关行：比一级小一号（文字 11.5 / 开关缩小 40%），带树形缩进。
class _ChildToggle extends ConsumerWidget {
  const _ChildToggle({
    super.key,
    required this.moduleId,
    required this.spec,
  });

  final String moduleId;
  final DashboardParamSpec spec;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ToonPalette p = context.toon;
    final DashboardConfig config =
        ref.watch(dashboardConfigProvider).value ?? DashboardConfig.defaults;
    final bool value = DashboardParamSpec.boolValue(
      paramsOf(config.params, moduleId),
      spec,
    );
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => unawaited(
        ref
            .read(dashboardConfigProvider.notifier)
            .setParam(moduleId, spec.id, !value),
      ),
      child: Padding(
        padding: const EdgeInsets.only(left: 30, top: 2, bottom: 2, right: 4),
        child: Row(
          children: <Widget>[
            Icon(
              Icons.subdirectory_arrow_right_rounded,
              size: 13,
              color: p.ink3,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                spec.title,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: p.ink2,
                ),
              ),
            ),
            SizedBox(
              height: 26,
              width: 38,
              child: FittedBox(
                fit: BoxFit.contain,
                child: Switch(
                  key: ValueKey<String>(
                    'dashboard_param_${moduleId}_${spec.id}',
                  ),
                  value: value,
                  onChanged: (bool v) => unawaited(
                    ref
                        .read(dashboardConfigProvider.notifier)
                        .setParam(moduleId, spec.id, v),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
