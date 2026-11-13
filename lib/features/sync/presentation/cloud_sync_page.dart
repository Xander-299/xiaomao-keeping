/// 「云同步」页（路由 `/cloud-sync`）：P6.2 账号 + P6.3 云备份。
///
/// 账号：邮箱验证码登录、退出、注销、同步开关。
/// 云备份：手动上传当前账本备份 / 从云端恢复（合并 + 指纹去重）。
/// **P6.4 双向同步未做**，页面里不出现「自动同步 / 实时同步」。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:yanxin/core/network/cloud_sync_gate.dart';
import 'package:yanxin/core/network/sync_api.dart';
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
import 'package:yanxin/features/sync/application/auth_controller.dart';

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

  Widget _backupStatus(ToonPalette p, AsyncValue<BackupInfo?> info, bool enabled) {
    final String text;
    if (!enabled) {
      text = '打开上方「云同步」开关后，才能备份 / 恢复';
    } else {
      text = info.when(
        loading: () => '正在读取云端备份…',
        error: (Object e, StackTrace _) => '读取失败：${_describe(e)}',
        data: (BackupInfo? b) => b == null
            ? '云端还没有备份'
            : '上次备份：${_stamp(b.createdAt)} · ${b.sizeLabel}',
      );
    }
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: p.ink2,
        height: 1.7,
      ),
    );
  }

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
        padding: const EdgeInsets.only(bottom: 28),
        children: <Widget>[
          const ToonSectionTitle(title: '账号'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
            child: _StatusCard(auth: auth, enabled: enabled),
          ),
          if (!auth.signedIn) ..._signedOutForm(),
          if (auth.signedIn) ..._signedInPanel(p, auth, enabled),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
            child: Text(
              '· 默认关闭：未登录 / 未开启时一个字节都不会发出去\n'
              '· 只走 HTTPS；地址写死在代码里，不做动态下发\n'
              '· 云备份手动触发；P6.4 双向同步尚未开放',
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

  List<Widget> _signedOutForm() => <Widget>[
    const ToonSectionTitle(title: '登录'),
    Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
      child: ToonCard(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
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
            const SizedBox(height: 12),
            ToonButton(
              key: const ValueKey<String>('cloudSyncSendCode'),
              label: _cooldown > 0 ? '${_cooldown}s 后可重发' : '发送验证码',
              kind: ToonButtonKind.ghost,
              block: true,
              onPressed: _busy || _cooldown > 0 ? null : _sendCode,
            ),
            const SizedBox(height: 12),
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
    final bool hasBackup = backup.value != null;
    return <Widget>[
        const ToonSectionTitle(title: '同步'),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
          child: ToonCard(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            clip: true,
            child: ToonField(
              label: '云同步',
              value: enabled ? '已开启' : '已关闭',
              trailing: Switch(
                key: const ValueKey<String>('cloudSyncSwitch'),
                value: enabled,
                onChanged: _busy
                    ? null
                    : (bool v) =>
                          ref.read(cloudSyncEnabledProvider.notifier).setEnabled(v),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
          child: Text(
            '· 开关决定是否允许云备份请求；关掉后备份 / 恢复会置灰\n'
            '· 退出登录不会删除本机账本',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: p.ink2,
              height: 1.7,
            ),
          ),
        ),
        const ToonSectionTitle(title: '云备份'),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
          child: ToonCard(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _backupStatus(p, backup, enabled),
                const SizedBox(height: 12),
                ToonButton(
                  key: const ValueKey<String>('cloudBackupUpload'),
                  label: _busy ? '请稍候…' : '立即备份到云端',
                  block: true,
                  onPressed: enabled && !_busy ? _uploadBackup : null,
                ),
                const SizedBox(height: 8),
                ToonButton(
                  key: const ValueKey<String>('cloudBackupRestore'),
                  label: '从云端恢复',
                  kind: ToonButtonKind.ghost,
                  block: true,
                  onPressed: enabled && hasBackup && !_busy
                      ? _restoreBackup
                      : null,
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
          child: Text(
            '· 手动触发，不会后台上传；只存最近几份快照\n'
            '· 恢复是合并 + 指纹去重，不删除现有数据',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: p.ink2,
              height: 1.7,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: ToonButton(
            key: const ValueKey<String>('cloudSyncSignOut'),
            label: '退出登录',
            kind: ToonButtonKind.ghost,
            block: true,
            onPressed: _busy ? null : _signOut,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: ToonButton(
            key: const ValueKey<String>('cloudSyncDelete'),
            label: '注销账号（云端硬删）',
            kind: ToonButtonKind.danger,
            block: true,
            onPressed: _busy ? null : _deleteAccount,
          ),
        ),
      ];
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.auth, required this.enabled});

  final AuthState auth;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final ToonPalette p = context.toon;
    final String title = auth.signedIn ? (auth.email ?? '已登录') : '未登录';
    final String subtitle = auth.signedIn
        ? (enabled ? '同步已开启' : '同步已关闭')
        : '登录后可备份到云端 / 换机恢复';

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
