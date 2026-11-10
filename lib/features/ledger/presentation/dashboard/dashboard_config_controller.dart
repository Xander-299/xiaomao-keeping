/// 首页模块配置的读写：`schema_meta.dashboard_config`（JSON，KV 零迁移）。
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:yanxin/data/providers/database.dart';

import 'dashboard_config.dart';
import 'dashboard_param.dart';
import 'dashboard_registry.dart';

/// `schema_meta` 里的 key；不存在 = 全默认。
const String kDashboardConfigKey = 'dashboard_config';

final dashboardConfigProvider =
    AsyncNotifierProvider<DashboardConfigController, DashboardConfig>(
      DashboardConfigController.new,
    );

class DashboardConfigController extends AsyncNotifier<DashboardConfig> {
  @override
  Future<DashboardConfig> build() async {
    try {
      final String? raw = await ref
          .watch(appMetaRepositoryProvider)
          .get(kDashboardConfigKey);
      if (raw == null || raw.trim().isEmpty) {
        return DashboardConfig.defaults;
      }
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) return DashboardConfig.defaults;
      return DashboardRegistry.sanitize(
        DashboardConfig.fromJson(Map<String, Object?>.from(decoded)),
      );
    } catch (_) {
      // 脏数据 / 读库失败都不能把首页打空：回落默认全量。
      return DashboardConfig.defaults;
    }
  }

  /// 先更新 UI 再写库；写失败本次会话仍生效（低风险偏好）。
  Future<void> save(DashboardConfig config) async {
    final DashboardConfig next = DashboardRegistry.sanitize(config);
    state = AsyncData<DashboardConfig>(next);
    try {
      await ref
          .read(appMetaRepositoryProvider)
          .set(kDashboardConfigKey, jsonEncode(next.toJson()));
    } catch (_) {
      // 静默：首页布局不阻断记账
    }
  }

  Future<void> reset() async {
    state = const AsyncData<DashboardConfig>(DashboardConfig.defaults);
    try {
      await ref.read(appMetaRepositoryProvider).remove(kDashboardConfigKey);
    } catch (_) {
      // 静默
    }
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final DashboardConfig current = state.value ?? DashboardConfig.defaults;
    final Set<String> ids = <String>{
      ...DashboardRegistry.effectiveEnabledIds(current),
    };
    if (enabled) {
      ids.add(id);
    } else {
      ids.remove(id);
    }
    await save(
      DashboardConfig(
        enabledIds: ids,
        orderIds: DashboardRegistry.effectiveOrderIds(current),
      ),
    );
  }

  Future<void> reorder(List<String> order) async {
    final DashboardConfig current = state.value ?? DashboardConfig.defaults;
    await save(
      DashboardConfig(
        enabledIds: DashboardRegistry.effectiveEnabledIds(current),
        orderIds: order,
        params: current.params,
      ),
    );
  }

  /// 设置某个模块参数（bool / choice / count 统一走这里）。
  ///
  /// 写入前按参数声明归一：值不在选项里、越界、类型不对 —— 一律**回落默认**再写，
  /// 绝不把脏值落库（否则下次启动读回来还是脏的）。未知参数（模块或参数已被删）直接忽略。
  Future<void> setParam(String moduleId, String paramId, Object value) async {
    final DashboardParamSpec? spec = DashboardRegistry.specOf(moduleId, paramId);
    if (spec == null) return;
    final Object normalized = spec.coerce(value);
    final DashboardConfig current = state.value ?? DashboardConfig.defaults;
    final DashboardParams next = <String, Map<String, Object?>>{
      ...?current.params,
      moduleId: <String, Object?>{
        ...?current.params?[moduleId],
        paramId: normalized,
      },
    };
    await save(
      DashboardConfig(
        enabledIds: DashboardRegistry.effectiveEnabledIds(current),
        orderIds: DashboardRegistry.effectiveOrderIds(current),
        params: next,
      ),
    );
  }
}
