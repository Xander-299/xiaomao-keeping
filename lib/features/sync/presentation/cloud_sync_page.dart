/// 「云同步」页：账号 + 云备份 + 账本同步（P6.2 / P6.3 / P6.4）。
///
/// 布局原则：**一屏三块**——账号卡、功能卡（开关 / 云备份 / 账本同步）、账号操作。
/// 不再写长段说明；每项只保留一行状态文案，操作按钮缩成小号放在行尾。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:yanxin/core/network/cloud_sync_gate.dart';
import 'package:yanxin/core/network/sync_api.dart';
import 'package:yanxin/core/providers/account_scope.dart';
import 'package:yanxin/core/providers/data_epoch.dart';
import 'package:yanxin/core/security/token_store.dart';
import 'package:yanxin/core/theme/toon.dart';
import 'package:yanxin/data/providers/database.dart';
import 'package:yanxin/features/import/application/backup_restore.dart';
import 'package:yanxin/features/import/presentation/backup_settings_dialog.dart';
import 'package:yanxin/features/ledger/application/ledger_controller.dart';
import 'package:yanxin/features/ledger/presentation/dashboard/dashboard_config_controller.dart';
import 'package:yanxin/features/settings/application/theme_controller.dart';
import 'package:yanxin/features/stats/application/stats_controller.dart';
import 'package:yanxin/features/sync/application/account_switch.dart';
import 'package:yanxin/features/sync/application/auth_controller.dart';
import 'package:yanxin/features/sync/application/sync_conflicts.dart';
import 'package:yanxin/features/sync/application/sync_engine.dart';
import 'package:yanxin/features/sync/presentation/conflicts_page.dart';

/// 云端最新备份（未登录 / 开关关闭时不发请求，返回 null）。
final cloudBackupInfoProvider = FutureProvider<BackupInfo?>((Ref ref) async {
  final AuthState? auth = ref.watch(authControllerProvider).value;
  final bool enabled = ref.watch(cloudSyncEnabledProvider).value ?? false;
  if (auth?.signedIn != true || !enabled) return null;
  return ref.read(authControllerProvider.notifier).latestBackup();
});

/// 邮箱验证码登录 / 账号态。
class CloudSyncPage extends ConsumerStatefulWidget {
  const CloudSyncPage({super.key});

  @override
  ConsumerState<CloudSyncPage> createState() => _CloudSyncPageState();
}

class _CloudSyncPageState extends ConsumerState<CloudSyncPage> {
  final TextEditingController _email = TextEditingController();
  final TextEditingController _code = TextEditingController();
  Timer? _cooldownTimer;
  int _cooldown = 0;
  bool _busy = false;

  /// 有已保存账号时默认展示账号列表；点「使用其他账号」才展开邮箱表单。
  bool _showEmailForm = false;

  @override
  void initState() {
    super.initState();
    _email.text = ref.read(authControllerProvider).value?.email ?? '';
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  void _startCooldown() {
    _cooldownTimer?.cancel();
    setState(() => _cooldown = 60);
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (Timer t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() {
        _cooldown -= 1;
        if (_cooldown <= 0) t.cancel();
      });
    });
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  /// 把三类异常翻译成人话；未知异常不把堆栈甩给用户。
  String _describe(Object error) => switch (error) {
    SyncDeniedException(:final CloudSyncDenial denial) => denial.label,
    SyncApiException(:final String userMessage) => userMessage,
    SecureStoreException(:final String message) => message,
    _ => '操作失败，请稍后重试',
  };

  Future<void> _sendCode() async {
    final String email = _email.text.trim();
    if (!AuthController.isValidEmail(email)) {
      _toast('请输入正确的邮箱');
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(authControllerProvider.notifier).requestCode(email);
      _startCooldown();
      _toast('验证码已发送，请查收邮箱');
    } on Object catch (e) {
      _toast(_describe(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signIn() async {
    final String email = _email.text.trim();
    final String code = _code.text.trim();
    if (!AuthController.isValidEmail(email)) {
      _toast('请输入正确的邮箱');
      return;
    }
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      _toast('请输入 6 位验证码');
      return;
    }
    setState(() => _busy = true);
    try {
      await ref
          .read(authControllerProvider.notifier)
          .signIn(email: email, code: code);
      if (mounted) {
        _code.clear();
        _toast('已登录');
      }
    } on Object catch (e) {
      _toast(_describe(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signOut() async {
    setState(() => _busy = true);
    try {
      await ref.read(authControllerProvider.notifier).signOut();
      if (mounted) _toast('已退出登录');
    } on Object catch (e) {
      _toast(_describe(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteAccount() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('注销账号？'),
        content: const Text('云端备份会被永久删除，无法恢复。本机账本不受影响。'),
        actions: <Widget>[
          ToonButton(
            label: '取消',
            kind: ToonButtonKind.ghost,
            small: true,
            onPressed: () => Navigator.of(ctx).pop(false),
          ),
          ToonButton(
            label: '注销',
            kind: ToonButtonKind.danger,
            small: true,
            onPressed: () => Navigator.of(ctx).pop(true),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _busy = true);
    try {
      await ref.read(authControllerProvider.notifier).deleteAccount();
      if (mounted) _toast('账号已注销');
    } on Object catch (e) {
      _toast(_describe(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── 云备份（P6.3）────────────────────────────────────────────────

  Future<void> _uploadBackup() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final BackupInfo info = await ref
          .read(authControllerProvider.notifier)
          .uploadCurrentBackup();
      if (!mounted) return;
      ref.invalidate(cloudBackupInfoProvider);
      _toast('已备份到云端（${info.sizeLabel}）');
    } on Object catch (e) {
      _toast(_describe(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restoreBackup() async {
    if (_busy) return;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('从云端恢复？'),
        content: const Text(
          '备份会合并进当前账本：按流水指纹去重，不会删除现有数据。\n'
          '如果备份里带外观 / 布局，下一步会问你恢复不恢复。',
        ),
        actions: <Widget>[
          ToonButton(
            label: '取消',
            kind: ToonButtonKind.ghost,
            small: true,
            onPressed: () => Navigator.of(ctx).pop(false),
          ),
          ToonButton(
            label: '恢复',
            small: true,
            onPressed: () => Navigator.of(ctx).pop(true),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _busy = true);
    try {
      final Uint8List bytes = await ref
          .read(authControllerProvider.notifier)
          .downloadLatestBackup();
      var restoreSettings = true;
      if (backupHasSettings(bytes)) {
        if (!mounted) return;
        restoreSettings = await askRestoreBackupSettings(context);
        if (!mounted) return;
      }
      final BackupRestoreReport report = await restoreBackupJson(
        ref.read(appDatabaseProvider),
        bytes: bytes,
        createBook: false,
        restoreSettings: restoreSettings,
      );
      await ref.read(ledgerProvider.notifier).refresh();
      unawaited(ref.read(statsProvider.notifier).refresh());
      if (report.settingsRestored > 0) {
        ref.invalidate(themeSeedProvider);
        ref.invalidate(themeModeProvider);
        ref.invalidate(dashboardConfigProvider);
      }
      ref.read(dataEpochProvider.notifier).bump();
      if (!mounted) return;
      _toast('已恢复 ${report.imported} 笔（跳过重复 ${report.duplicates}）');
    } on FormatException catch (e) {
      _toast(e.message);
    } on Object catch (e) {
      _toast(_describe(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _two(int value) => value.toString().padLeft(2, '0');

  String _stamp(DateTime t) =>
      '${t.year}-${_two(t.month)}-${_two(t.day)} '
      '${_two(t.hour)}:${_two(t.minute)}';

  Future<void> _syncNow() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref.read(syncStatusProvider.notifier).syncNow();
      if (!mounted) return;
      final SyncStatusState? state = ref.read(syncStatusProvider).value;
      final String? error = state?.error;
      if (error != null) {
        _toast(error);
      } else if (state?.last != null) {
        final SyncResult r = state!.last!;
        final String extra = r.conflicts > 0 ? ' · 冲突 ${r.conflicts}' : '';
        _toast('同步完成：上行 ${r.pushed} / 下行 ${r.pulled}$extra');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _backupText(AsyncValue<BackupInfo?> info, bool enabled) {
    if (!enabled) return '未开启';
    return info.when(
      loading: () => '读取中…',
      error: (Object e, StackTrace _) => '读取失败',
      data: (BackupInfo? b) => b == null
          ? '还没有备份'
          : '上次 ${_stamp(b.createdAt)} · ${b.sizeLabel}',
    );
  }

  String _syncText(SyncStatusState state) {
    if (state.syncing) return '同步中…';
    if (state.error != null) return '同步失败';
    if (state.lastSyncAt == null) return '还没同步过';
    final SyncResult? r = state.last;
    final String stamp = _stamp(state.lastSyncAt!);
    return r == null
        ? '上次 $stamp'
        : '上次 $stamp · ↑${r.pushed} ↓${r.pulled}';
  }

  Widget _rowDivider(ToonPalette p) => Divider(height: 1, color: p.line);

  TextStyle _statusStyle(ToonPalette p) => TextStyle(
    fontSize: 11.5,
    fontWeight: FontWeight.w600,
    color: p.ink2,
    height: 1.5,
  );

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    final AuthState auth =
        ref.watch(authControllerProvider).value ?? const AuthState();
    final bool enabled = ref.watch(cloudSyncEnabledProvider).value ?? false;

    return Scaffold(
      backgroundColor: p.paper,
      appBar: AppBar(title: const Text('云同步')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(0, 14, 0, 24),
        children: <Widget>[
          if (!auth.signedIn)
            ...(auth.accounts.isEmpty || _showEmailForm
                ? _signedOutForm(p)
                : _accountPicker(p, auth)),
          if (auth.signedIn) ..._signedInPanel(p, auth, enabled),
        ],
      ),
    );
  }

  // ── 多账号（P6.5）：已保存账号列表 / 切号 / 移除 ─────────────────────

  List<Widget> _accountPicker(ToonPalette p, AuthState auth) {
    return <Widget>[
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(
          '选择账号',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w800,
            color: p.ink,
          ),
        ),
      ),
      const SizedBox(height: 4),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(
          '切号会先把当前账号备份到云端，再把所选账号的数据装回本机。',
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: p.ink2,
          ),
        ),
      ),
      const SizedBox(height: 10),
      for (final SavedAccount account in auth.accounts)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: ToonCard(
            padding: EdgeInsets.zero,
            child: InkWell(
              key: ValueKey<String>('account-${account.email}'),
              borderRadius: BorderRadius.circular(18),
              onTap: () => _switchTo(account),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            account.email,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            account.lastUsedAt == 0
                                ? '未使用过'
                                : '上次使用 ${_stamp(DateTime.fromMillisecondsSinceEpoch(account.lastUsedAt))}',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: p.ink2,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      key: ValueKey<String>('account-remove-${account.email}'),
                      tooltip: '移除账号',
                      icon: Icon(Icons.close_rounded, size: 18, color: p.ink2),
                      onPressed: () => _removeAccount(account),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: ToonButton(
          key: const ValueKey<String>('cloudSyncUseOther'),
          label: '使用其他账号',
          kind: ToonButtonKind.ghost,
          block: true,
          onPressed: () => setState(() => _showEmailForm = true),
        ),
      ),
      const SizedBox(height: 10),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(
          '移除账号只清掉本机的登录状态，账本会保留（同一邮箱再登录就回来）。',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: p.ink2,
          ),
        ),
      ),
    ];
  }

  Future<void> _switchTo(SavedAccount account) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('切换到该账号？'),
        content: Text(
          '会先把当前账号的数据备份到云端，再把 ${account.email} 的数据装回本机。\n'
          '过程中不要退出 App。',
        ),
        actions: <Widget>[
          ToonButton(
            label: '取消',
            kind: ToonButtonKind.ghost,
            small: true,
            onPressed: () => Navigator.of(ctx).pop(false),
          ),
          ToonButton(
            label: '切换',
            small: true,
            onPressed: () => Navigator.of(ctx).pop(true),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final ValueNotifier<AccountSwitchStage> stage =
        ValueNotifier<AccountSwitchStage>(AccountSwitchStage.backingUp);
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('正在切换账号'),
          content: ValueListenableBuilder<AccountSwitchStage>(
            valueListenable: stage,
            builder: (BuildContext context, AccountSwitchStage value, Widget? _) =>
                Text(_stageText(value)),
          ),
        ),
      ),
    ));

    String? failure;
    try {
      await ref
          .read(accountSwitcherProvider)
          .switchTo(account.email, onStage: (AccountSwitchStage s) => stage.value = s);
    } on Object catch (e) {
      failure = _describe(e);
    } finally {
      stage.dispose();
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }
    if (!mounted) return;
    setState(() => _showEmailForm = false);
    if (failure != null) _toast('切换失败：$failure');
  }

  String _stageText(AccountSwitchStage stage) => switch (stage) {
    AccountSwitchStage.backingUp => '正在备份当前账号…',
    AccountSwitchStage.switching => '正在切换账号…',
    AccountSwitchStage.restoring => '正在下载该账号的云端备份…',
    AccountSwitchStage.pulling => '正在补齐云端改动…',
  };

  Future<void> _removeAccount(SavedAccount account) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('移除这个账号？'),
        content: Text(
          '${account.email}\n\n'
          '云端数据不会被删除；本机属于它的账本会保留但隐藏，'
          '下次用同一邮箱登录就会回来。',
        ),
        actions: <Widget>[
          ToonButton(
            label: '取消',
            kind: ToonButtonKind.ghost,
            small: true,
            onPressed: () => Navigator.of(ctx).pop(false),
          ),
          ToonButton(
            label: '移除',
            kind: ToonButtonKind.danger,
            small: true,
            onPressed: () => Navigator.of(ctx).pop(true),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await ref
        .read(authControllerProvider.notifier)
        .removeAccount(account.email);
    if (!mounted) return;
    setState(() {
      if (ref.read(authControllerProvider).value?.accounts.isEmpty ?? false) {
        _showEmailForm = false;
      }
    });
  }

  List<Widget> _signedOutForm(ToonPalette p) => <Widget>[
    Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: ToonCard(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Text(
              '登录账号',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            Text('未登录 · 邮箱验证码登录', style: _statusStyle(p)),
            const SizedBox(height: 14),
            TextField(
              key: const ValueKey<String>('cloudSyncEmail'),
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const <String>[AutofillHints.email],
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: '邮箱',
                hintText: 'you@example.com',
              ),
            ),
            const SizedBox(height: 10),
            ToonButton(
              key: const ValueKey<String>('cloudSyncSendCode'),
              label: _cooldown > 0 ? '${_cooldown}s 后可重发' : '发送验证码',
              kind: ToonButtonKind.ghost,
              block: true,
              onPressed: _busy || _cooldown > 0 ? null : _sendCode,
            ),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey<String>('cloudSyncCode'),
              controller: _code,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.done,
              maxLength: 6,
              decoration: const InputDecoration(
                labelText: '验证码',
                hintText: '6 位数字',
                counterText: '',
              ),
              onSubmitted: (_) {
                if (!_busy) _signIn();
              },
            ),
            const SizedBox(height: 8),
            ToonButton(
              key: const ValueKey<String>('cloudSyncSignIn'),
              label: _busy ? '请稍候…' : '登录',
              block: true,
              onPressed: _busy ? null : _signIn,
            ),
          ],
        ),
      ),
    ),
  ];

  List<Widget> _signedInPanel(ToonPalette p, AuthState auth, bool enabled) {
    final AsyncValue<BackupInfo?> backup = ref.watch(cloudBackupInfoProvider);
    final SyncStatusState sync =
        ref.watch(syncStatusProvider).value ?? const SyncStatusState();
    // 本机被云端覆盖的行数（只在 >0 时出现在同步行下面）。
    final int conflicts = ref.watch(syncConflictCountProvider).value ?? 0;
    final bool hasBackup = backup.value != null;

    return <Widget>[
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: _StatusCard(auth: auth),
      ),
      const SizedBox(height: 12),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: ToonCard(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          clip: true,
          child: Column(
            children: <Widget>[
              ToonField(
                label: '云同步',
                value: enabled ? '已开启' : '已关闭',
                trailing: Switch(
                  key: const ValueKey<String>('cloudSyncSwitch'),
                  value: enabled,
                  onChanged: _busy
                      ? null
                      : (bool v) => ref
                            .read(cloudSyncEnabledProvider.notifier)
                            .setEnabled(v),
                ),
              ),
              if (!enabled)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('打开后可备份与同步', style: _statusStyle(p)),
                  ),
                ),
              _rowDivider(p),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        const Text(
                          '云备份',
                          style: TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Spacer(),
                        ToonButton(
                          key: const ValueKey<String>('cloudBackupUpload'),
                          label: '备份',
                          small: true,
                          onPressed: enabled && !_busy ? _uploadBackup : null,
                        ),
                        const SizedBox(width: 8),
                        ToonButton(
                          key: const ValueKey<String>('cloudBackupRestore'),
                          label: '恢复',
                          small: true,
                          kind: ToonButtonKind.ghost,
                          onPressed: enabled && hasBackup && !_busy
                              ? _restoreBackup
                              : null,
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(_backupText(backup, enabled), style: _statusStyle(p)),
                  ],
                ),
              ),
              _rowDivider(p),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        const Text(
                          '账本同步',
                          style: TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Spacer(),
                        ToonButton(
                          key: const ValueKey<String>('cloudSyncNow'),
                          label: '同步',
                          small: true,
                          onPressed: enabled && !_busy ? _syncNow : null,
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(_syncText(sync), style: _statusStyle(p)),
                    if (conflicts > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: InkWell(
                          key: const ValueKey<String>('cloudSyncConflicts'),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const SyncConflictsPage(),
                            ),
                          ),
                          child: Text(
                            '$conflicts 条被云端覆盖 ›',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w800,
                              color: p.brandInk,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: <Widget>[
            Expanded(
              child: ToonButton(
                key: const ValueKey<String>('cloudSyncSignOut'),
                label: '退出登录',
                kind: ToonButtonKind.ghost,
                small: true,
                block: true,
                onPressed: _busy ? null : _signOut,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: ToonButton(
                key: const ValueKey<String>('cloudSyncDelete'),
                label: '注销账号',
                kind: ToonButtonKind.danger,
                small: true,
                block: true,
                onPressed: _busy ? null : _deleteAccount,
              ),
            ),
          ],
        ),
      ),
    ];
  }
}
class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.auth});

  final AuthState auth;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    final String title = auth.signedIn ? (auth.email ?? '已登录') : '未登录';
    // 开关状态在下方功能卡里已有，这里不再重复
    final String subtitle = auth.signedIn ? '已登录' : '未登录';

    return ToonCard(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: <Widget>[
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: auth.signedIn ? p.brandTint : p.canvas2,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(
              auth.signedIn
                  ? Icons.cloud_done_rounded
                  : Icons.cloud_off_rounded,
              color: auth.signedIn ? p.brandDeep : p.ink3,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: p.ink,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: p.ink2,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
