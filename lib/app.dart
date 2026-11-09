/// 应用根。
///
/// 路由表在 State 里构建（每个 App 实例独立一份 GoRouter，测试互不串扰）：
/// - 壳路由（底部导航 4 tab）：`/` `/calendar` `/assets` `/profile`
/// - 全屏路由：`/record`（extra = 流水 id，`?date=` = 默认日期毫秒）、`/books`、
///   `/categories`、`/import`、`/month-picker`（日历的月份选择子页）、`/stats`（统计）、
///   `/reports`（报表，extra = [ReportsArgs]）、`/autobook`（自动记账）
///
/// 搜索不是路由：F7.5 起改为覆盖在首页之上的浮层（`showSearchOverlay`）。
///
/// 主题对齐页面原型（F7.6）：卡通 —— 暖白画布 + 白卡 + 2.5px 墨色描边 + 硬阴影。
/// F7.17 起再加一套「卡通夜灯」深色，`themeMode` 由「设置 → 外观」决定（默认跟随系统）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:yanxin/core/theme/palette.dart';
import 'package:yanxin/core/theme/theme_mode.dart';
import 'package:yanxin/core/theme/theme_seed.dart';
import 'package:yanxin/core/theme/tokens.dart';
import 'package:yanxin/features/assets/presentation/assets_page.dart';
import 'package:yanxin/features/autobook/presentation/auto_book_page.dart';
import 'package:yanxin/features/book/presentation/book_manage_page.dart';
import 'package:yanxin/features/calendar/presentation/calendar_page.dart';
import 'package:yanxin/features/calendar/presentation/month_picker_page.dart';
import 'package:yanxin/features/category/presentation/category_manage_page.dart';
import 'package:yanxin/features/chat/presentation/chat_page.dart';
import 'package:yanxin/features/import/presentation/import_page.dart';
import 'package:yanxin/features/ledger/presentation/dashboard/dashboard_layout_page.dart';
import 'package:yanxin/features/ledger/presentation/home_page.dart';
import 'package:yanxin/features/nav/presentation/app_shell.dart';
import 'package:yanxin/features/onboarding/presentation/onboarding_page.dart';
import 'package:yanxin/features/profile/presentation/profile_page.dart';
import 'package:yanxin/features/record/presentation/record_page.dart';
import 'package:yanxin/features/reports/application/reports_controller.dart';
import 'package:yanxin/features/reports/presentation/reports_page.dart';
import 'package:yanxin/features/settings/application/theme_controller.dart';
import 'package:yanxin/features/settings/presentation/settings_page.dart';
import 'package:yanxin/features/stats/presentation/stats_page.dart';

/// 应用根。
///
/// 路由表在 State 里构建（每个 App 实例独立一份 GoRouter，测试互不串扰）：
/// - 壳路由（底部导航 4 tab）：`/` `/calendar` `/assets` `/profile`
/// - 全屏路由：`/record`（extra = 流水 id，`?date=` = 默认日期毫秒）、`/books`、
///   `/categories`、`/import`、`/month-picker`（日历的月份选择子页）、`/stats`（统计）、
///   `/reports`（报表，extra = [ReportsArgs]）、`/autobook`（自动记账）、
///   `/settings`（设置，F7.17：外观三选一）
class YanxinApp extends ConsumerStatefulWidget {
  const YanxinApp({super.key});

  @override
  ConsumerState<YanxinApp> createState() => _YanxinAppState();
}

class _YanxinAppState extends ConsumerState<YanxinApp> {
  late final GoRouter _router = GoRouter(
    initialLocation: '/',
    routes: <RouteBase>[
      StatefulShellRoute.indexedStack(
        builder: (BuildContext _, GoRouterState _, StatefulNavigationShell shell) =>
            AppShell(navigationShell: shell),
        branches: <StatefulShellBranch>[
          StatefulShellBranch(
            routes: <RouteBase>[GoRoute(path: '/', builder: (_, _) => const HomePage())],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: '/calendar',
                builder: (_, _) => const CalendarPage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: '/assets',
                builder: (_, _) => const AssetsPage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: '/profile',
                builder: (_, _) => const ProfilePage(),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: '/record',
        builder: (_, GoRouterState state) => RecordPage(
          txId: state.extra as String?,
          // 日历页「记一笔」按选中日期带入：/record?date=<毫秒>
          occurredAtMs: int.tryParse(state.uri.queryParameters['date'] ?? ''),
        ),
      ),
      GoRoute(path: '/books', builder: (_, _) => const BookManagePage()),
      GoRoute(path: '/import', builder: (_, _) => const ImportPage()),
      GoRoute(path: '/month-picker', builder: (_, _) => const MonthPickerPage()),
      GoRoute(path: '/stats', builder: (_, _) => const StatsPage()),
      GoRoute(
        path: '/reports',
        // extra = ReportsArgs（档位 / 年月，可空：为空沿用 controller 当前状态）
        builder: (_, GoRouterState state) =>
            ReportsPage(args: state.extra as ReportsArgs?),
      ),
      GoRoute(
        path: '/categories',
        builder: (_, _) => const CategoryManagePage(),
      ),
      // 新手引导（F7.14）：首启由 AppShell 判定后 push；也可从「我的」随时重看
      GoRoute(path: '/onboarding', builder: (_, _) => const OnboardingPage()),
      // 自动记账（F7.15）：权限状态 / 去开启 / 最近一批撤销，入口在「我的」
      GoRoute(path: '/autobook', builder: (_, _) => const AutoBookPage()),
      // 设置（F7.17）：外观 = 浅色 / 深色 / 跟随系统（默认跟随系统）
      GoRoute(path: '/settings', builder: (_, _) => const SettingsPage()),
      // 首页布局（P3）：模块显示/隐藏 + 拖拽排序，入口在设置页
      GoRoute(
        path: '/dashboard-layout',
        builder: (_, _) => const DashboardLayoutPage(),
      ),
      // 记一笔 / 问一句（2026-10-28 改版）：文字问账本 + 发账单截图，合并成一条聊天流。
      // 旧的 `/assistant`（问账本）与 `/receipt`（截图记账）已并入这里，入口从首页进来。
      GoRoute(
        path: '/chat',
        builder: (_, GoRouterState state) =>
            ChatPage(launch: state.extra as ChatLaunch?),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    // 还没读出来时按默认「跟随系统」渲染（首帧前 main() 已预热，正常不会走到这里）
    final ToonThemeMode mode =
        ref.watch(themeModeProvider).value ?? ToonThemeMode.system;
    // 主题色（2026-10-29）：换 seed → 整套 M3 色板跟着换，页面代码一行不用动
    final ToonSeed seed = ref.watch(themeSeedProvider).value ?? ToonSeed.forest;
    return MaterialApp.router(
      title: '小耄记账',
      theme: buildToonTheme(
        ToonPalette.lightOf(seed),
        Brightness.light,
        seed: seed.seed,
      ),
      darkTheme: buildToonTheme(
        ToonPalette.darkOf(seed),
        Brightness.dark,
        seed: seed.seed,
      ),
      themeMode: mode.materialMode,
      routerConfig: _router,
    );
  }
}
