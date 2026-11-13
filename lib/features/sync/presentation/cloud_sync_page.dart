/// 「云同步」页（路由 `/cloud-sync`，P6.2 账号）。
///
/// 只做账号：邮箱验证码登录、退出、注销、同步开关。
/// **P6.3 云备份尚未开放** —— 页面里不出现「立即同步 / 上传备份」，
/// 假入口比没有更糟（设置页既有注释同口径）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:yanxin/core/network/cloud_sync_gate.dart';
import 'package:yanxin/core/network/sync_api.dart';
import 'package:yanxin/core/security/token_store.dart';
import 'package:yanxin/core/theme/toon.dart';
import 'package:yanxin/features/sync/application/auth_controller.dart';

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
              '· 当前版本只做账号，云备份（P6.3）尚未开放',
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

  List<Widget> _signedInPanel(ToonPalette p, AuthState auth, bool enabled) =>
      <Widget>[
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
            '· 开关只决定「以后是否允许同步」；本版本还没有云备份\n'
            '· 退出登录不会删除本机账本',
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
        : '登录后可换机恢复（云备份 P6.3 尚未开放）';

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
