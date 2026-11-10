/// 搜索浮层：按**分类名 / 备注 / 金额**检索当前账本的全部流水，并支持类型筛选。
///
/// 入口：首页 header 的搜索图标 → [showSearchOverlay]（见 `docs/spec/SPEC-F7.5-search-overlay.md`）。
///
/// F7.5 起**不再是独立路由**（原 `/search` 已删除）：改为全屏 dialog，
/// 首页留在页面栈里当背景，提示块以下的毛玻璃透出首页 —— 视觉上不再像「换了个 App」。
/// dialog 内部 `ref` / `context.push` 均可用：浮层挂在 `ProviderScope` 与 `Router` 之下。
library;

import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:yanxin/core/db/database.dart';
import 'package:yanxin/core/providers/data_epoch.dart';
import 'package:yanxin/core/theme/tokens.dart';
import 'package:yanxin/core/theme/toon.dart';
import 'package:yanxin/core/utils/money.dart';
import 'package:yanxin/data/providers/database.dart';
import 'package:yanxin/data/repositories/transaction_repository.dart';
import 'package:yanxin/features/calendar/application/calendar_controller.dart';
import 'package:yanxin/features/ledger/application/ledger_controller.dart';
import 'package:yanxin/features/ledger/application/month_summary.dart';
import 'package:yanxin/features/ledger/presentation/tx_restore_message.dart';
import 'package:yanxin/features/ledger/presentation/widgets/tx_delete_dialog.dart';
import 'package:yanxin/features/ledger/presentation/widgets/tx_group_list.dart';
import 'package:yanxin/features/shared/write_failure.dart';
import 'package:yanxin/features/stats/application/stats_controller.dart';
import 'package:yanxin/ui_kit/app_page_state.dart';

import '../application/search_controller.dart';
import '../application/search_history.dart';
import '../application/search_query.dart';

part 'widgets/search_bar.dart';
part 'widgets/search_result_bar.dart';
part 'widgets/search_states.dart';

/// 单次展示的结果上限：超出只显示最近 N 条（列表太长反而不好找）。
const int kSearchResultLimit = 200;

/// 毛玻璃模糊强度（SPEC Q3：先给 12，真机看过再调）。
const double kSearchGlassSigma = 12;

/// 打开搜索浮层（覆盖在当前页之上，不新增路由）。
Future<void> showSearchOverlay(BuildContext context) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '搜索',
    // 遮罩自己画：要毛玻璃不要纯色，所以让 barrier 透明
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 150),
    // 浮层是独立路由，根 Scaffold 的 SnackBar 会被玻璃盖住（不可点）——
    // 路由内自带 ScaffoldMessenger + Scaffold，让删除反馈浮在玻璃之上。
    pageBuilder: (_, _, _) => const ScaffoldMessenger(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SearchOverlay(),
      ),
    ),
    transitionBuilder: (_, Animation<double> anim, _, Widget child) =>
        FadeTransition(opacity: anim, child: child),
  );
}

/// 搜索浮层主体。
class SearchOverlay extends ConsumerStatefulWidget {
  const SearchOverlay({super.key});

  @override
  ConsumerState<SearchOverlay> createState() => _SearchOverlayState();
}

class _SearchOverlayState extends ConsumerState<SearchOverlay> {
  final TextEditingController _input = TextEditingController();
  final FocusNode _focus = FocusNode();

  /// 日期区间档（F7.7 D 批）：默认「全部」。
  ///
  /// 与类型词不同，区间**不进输入框**（没有对应的可解析指令词，写进去只会让
  /// `parsePlan` 把它当普通关键词 → 恒搜不到），改为浮层单选状态 + chip 高亮可见。
  SearchRange _range = SearchRange.all;

  @override
  void initState() {
    super.initState();
    // 输入变化只影响浮层（关键词不进 provider），直接 setState 刷新结果
    _input.addListener(_onInputChanged);
  }

  @override
  void dispose() {
    _input.removeListener(_onInputChanged);
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onInputChanged() => setState(() {});

  /// 填入关键词并保持焦点（示例、chip、一键清空共用）。
  void _setKeyword(String value) {
    _input.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    _focus.requestFocus();
  }

  /// 一键清空：清掉输入并重新聚焦，可以马上接着敲下一个关键词。
  void _clear() => _setKeyword('');

  /// 记一条搜索历史（只记关键词；纯类型词 / 空串不记，见 `search_history.dart`）。
  void _remember(String raw) {
    final String keyword = stripTypeWords(raw).trim();
    if (keyword.isEmpty) return;
    unawaited(ref.read(searchHistoryProvider.notifier).remember(keyword));
  }

  /// 点历史词：填进输入框 + 提前到历史最前（最近用过的排前面）。
  void _pickHistory(String keyword) {
    _setKeyword(keyword);
    _remember(keyword);
  }

  void _pickRange(SearchRange range) {
    if (_range == range) return;
    setState(() => _range = range);
  }

  /// 点类型 chip：已选中的再点 = 取消；否则换成该类型，剩余关键词原样保留。
  ///
  /// 词是**真的填进输入框**（SPEC Q1）：条件始终可见、可编辑、可一键清空，
  /// chip 高亮由输入框内容推导 → 不会出现「chip 亮着但输入框是空的」这种双份状态。
  void _toggleType(String word) {
    final String? current = parsePlan(_input.text).type;
    final String rest = stripTypeWords(_input.text);
    final String next;
    if (current == kTypeDirectives[word]) {
      next = rest; // 取消筛选
    } else {
      // 选中时补一个**尾随空格**：用户接着敲关键词就是「仅支出 11」，分隔开才会
      // 被解析成「类型 + 关键词」；否则拼成「仅支出11」不认指令、恒为空（真机走查发现的）。
      next = rest.isEmpty ? '$word ' : '$word $rest';
    }
    _setKeyword(next);
  }

  void _close() => Navigator.of(context).maybePop();

  Future<void> _edit(TxRow tx) async {
    // 点了结果 = 这次搜索有用 → 记进历史（与回车、点历史 chip 同一套触发点）
    _remember(_input.text);
    await context.push('/record', extra: tx.id);
    if (!mounted) return;
    // 编辑可能改到金额 / 分类 / 备注，回来必须重查
    // （不依赖 .then：壳路由下回调不兑现，与 import_page 同一处理）
    await ref.read(searchProvider.notifier).refresh();
  }

  Future<void> _confirmDelete(TxRow tx) async {
    if (!await confirmDeleteTx(context)) return;
    final int changed;
    try {
      changed = await ref
          .read(transactionRepositoryProvider)
          .softDelete(tx.id);
      await ref.read(searchProvider.notifier).refresh();
    } catch (e) {
      if (mounted) {
        showToonError(context, writeFailureMessage(e, action: '删除'));
      }
      return;
    }
    // 首页 / 日历 / 统计是同屏数据的其它视图，常驻 Notifier 不会自己感知删除
    // （与 home_page 的删除链路保持一致）
    unawaited(ref.read(ledgerProvider.notifier).refresh());
    unawaited(ref.read(calendarProvider.notifier).refresh());
    unawaited(ref.read(statsProvider.notifier).refresh());
    ref.invalidate(yearDayIndexProvider);
    // 资产页 watch 数据版本号，bump 即重算
    ref.read(dataEpochProvider.notifier).bump();
    if (mounted) setState(() {});
    final BuildContext pageContext = context;
    if (!pageContext.mounted) return;
    // P3：0 行 = 这条已被别的入口删掉。不报「已删除」、也不给撤销（撤销语义是反的）。
    if (changed == 0) {
      showToonFeedback(pageContext, kTxAlreadyGoneMessage);
      return;
    }
    final String label = tx.note.isNotEmpty
        ? tx.note
        : '${centsToYuan(tx.amountCents, group: true)} 元';
    showToonUndo(
      pageContext,
      '已删除「$label」',
      onUndo: () async {
        final TxRestoreResult result;
        try {
          result = await ref.read(transactionRepositoryProvider).restoreTx(tx.id);
        } catch (e) {
          if (pageContext.mounted) {
            showToonError(pageContext, writeFailureMessage(e, action: '撤销'));
          }
          return;
        }
        if (!result.isRestored) {
          if (pageContext.mounted) {
            showToonError(pageContext, txRestoreFailureMessage(result));
          }
          return;
        }
        await ref.read(searchProvider.notifier).refresh();
        unawaited(ref.read(ledgerProvider.notifier).refresh());
        unawaited(ref.read(calendarProvider.notifier).refresh());
        unawaited(ref.read(statsProvider.notifier).refresh());
        ref.invalidate(yearDayIndexProvider);
        ref.read(dataEpochProvider.notifier).bump();
        if (mounted) setState(() {});
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    final AsyncValue<SearchState> async = ref.watch(searchProvider);
    final SearchPlan plan = parsePlan(_input.text);

    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: <Widget>[
          // 1) 毛玻璃铺满全屏；提示块遮住上半部分 → 视觉上「提示块以下才是玻璃」，
          //    比只给下半屏铺玻璃简单，也不会在提示块边缘出现接缝。
          //    点玻璃区即关闭（内容区里可交互的部件会先消费点击）。
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _close,
              child: BackdropFilter(
                filter: ImageFilter.blur(
                  sigmaX: kSearchGlassSigma,
                  sigmaY: kSearchGlassSigma,
                ),
                // 原型 `.glass`：暖白画布 55% + 11px 模糊
                child: ColoredBox(
                  color: p.canvas.withValues(alpha: 0.55),
                ),
              ),
            ),
          ),
          // 2) 提示块（不透明）+ 内容区（浮在玻璃之上）
          Positioned.fill(
            child: Column(
              children: <Widget>[
                _SearchBar(
                  controller: _input,
                  focusNode: _focus,
                  plan: plan,
                  range: _range,
                  onClose: _close,
                  onClear: _clear,
                  onToggleType: _toggleType,
                  onPickRange: _pickRange,
                  onSubmit: _remember,
                ),
                Expanded(
                  child: async.when(
                    skipLoadingOnReload: true,
                    loading: () =>
                        const AppPageLoading(),
                    error: (Object e, StackTrace _) =>
                        AppPageError(error: e),
                    data: (SearchState state) =>
                        _buildResults(state, plan, _range),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResults(SearchState state, SearchPlan plan, SearchRange range) {
    final List<String> history =
        ref.watch(searchHistoryProvider).value ?? const <String>[];

    // 没有任何条件（无类型词 / 无关键词 / 区间=全部）：给引导而不是「列出全部流水」
    if (!hasAnyFilter(plan, range)) {
      return _Intro(
        history: history,
        onPick: _setKeyword,
        onPickHistory: _pickHistory,
        onClearHistory: () =>
            ref.read(searchHistoryProvider.notifier).clear(),
      );
    }

    final String keyword = plan.text;
    final List<TxRow> hits = filterTx(
      items: state.items,
      categoryNameOf: state.nameOf,
      accountNameOf: state.nameOfAccount,
      query: _input.text,
      range: range,
    );
    if (hits.isEmpty) {
      return _NoResult(
        keyword: _input.text.trim(),
        range: range,
        onClear: _clear,
      );
    }

    final List<TxRow> shown = hits.length > kSearchResultLimit
        ? hits.sublist(0, kSearchResultLimit)
        : hits;

    return Column(
      children: <Widget>[
        _ResultBar(
          shown: shown.length,
          total: hits.length,
          summary: summarize(shown),
          range: range,
        ),
        Expanded(
          child: TxGroupList(
            items: shown,
            categoryNameOf: state.nameOf,
            // 高亮用的关键词：类型词已剥离（「仅支出」不该在行里被标黄）
            highlightQuery: keyword.isEmpty ? null : keyword,
            onEdit: _edit,
            onDelete: _confirmDelete,
          ),
        ),
      ],
    );
  }
}
