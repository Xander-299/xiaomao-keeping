/// 云同步的账号状态（P6.2）。
///
/// 分工：
/// - 本文件只管「谁登录了、token 在哪、开关开没开」，**不碰账本**；
/// - 真正发请求的是 [SyncApi]（`lib/core/network/sync_api.dart`），
///   每次请求前都要过 [CloudSyncGate]（不变量 #8）；
/// - 登录态只存本机：token 进 Keystore 通道，邮箱与开关进 `schema_meta`
///   （都不进备份 JSON）。
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:yanxin/core/network/cloud_sync_gate.dart';
import 'package:yanxin/core/network/sync_api.dart';
import 'package:yanxin/core/network/sync_endpoints.dart';
import 'package:yanxin/core/security/token_store.dart';
import 'package:yanxin/data/providers/database.dart';
import 'package:yanxin/features/sync/application/backup_bytes.dart';

/// 登录态在安全存储里的键（值 = [AuthSession.toStorageJson]）。
const String kSyncSessionKey = 'sync_session';

/// 上次登录的邮箱（**不是**敏感凭据；用于下次登录预填）。
const String kSyncEmailKey = 'sync_email';

/// 「云同步」用户开关在 `schema_meta` 里的键。缺省 / 脏值 = 关。
const String kCloudSyncEnabledKey = 'cloud_sync_enabled';

/// 安全存储（生产 = Keystore 通道；测试覆盖成内存实现）。
final tokenStoreProvider = Provider<TokenStore>((Ref ref) => KeystoreTokenStore());

/// HTTP 传输（测试覆盖成假实现，不建真 socket）。
final syncTransportProvider = Provider<SyncTransport>((Ref ref) {
  final HttpSyncTransport transport = HttpSyncTransport();
  ref.onDispose(transport.close);
  return transport;
});

/// 端点是否已配置（生产 = [SyncEndpoints.isConfigured]）。
///
/// 单独抽成 provider 只为一个目的：单测里把「占位域名 = 未配置」这一关打开，
/// 否则所有登录相关用例都会停在 `notConfigured`。
final syncEndpointConfiguredProvider = Provider<bool>(
  (Ref ref) => SyncEndpoints.isConfigured,
);

/// 云同步 API。
final syncApiProvider = Provider<SyncApi>(
  (Ref ref) => SyncApi(
    transport: ref.watch(syncTransportProvider),
    // 用 read 而不是 watch：闸门随登录态变化，但 API 实例不该因此重建
    gate: () => ref.read(cloudSyncGateProvider),
  ),
);

/// 当前登录态。
class AuthState {
  const AuthState({this.session, this.email});

  final AuthSession? session;

  /// 上次登录 / 当前登录的邮箱（未登录时也可能有值，用于预填）。
  final String? email;

  bool get signedIn => session != null;

  AuthState copyWith({AuthSession? session, String? email}) => AuthState(
    session: session ?? this.session,
    email: email ?? this.email,
  );
}

/// 账号控制器。
final authControllerProvider =
    AsyncNotifierProvider<AuthController, AuthState>(AuthController.new);

/// 「云同步」用户开关（本机偏好，默认关）。
final cloudSyncEnabledProvider =
    AsyncNotifierProvider<CloudSyncEnabledController, bool>(
      CloudSyncEnabledController.new,
    );

/// 当前闸门：由「已登录 + 用户开关 + 端点是否配置」派生。
///
/// 默认（未登录 / 没开 / 没配域名）**一律拒绝**，与 [kClosedCloudSyncGate] 语义一致。
final cloudSyncGateProvider = Provider<CloudSyncGate>((Ref ref) {
  final bool signedIn = ref.watch(
    authControllerProvider.select(
      (AsyncValue<AuthState> v) => v.value?.signedIn ?? false,
    ),
  );
  final bool enabled = ref.watch(cloudSyncEnabledProvider).value ?? false;
  return CloudSyncGate(
    signedIn: signedIn,
    userEnabled: enabled,
    endpointConfigured: ref.watch(syncEndpointConfiguredProvider),
  );
});

class AuthController extends AsyncNotifier<AuthState> {
  /// 邮箱形状校验（纯函数，服务端仍会再校验一次）。
  static bool isValidEmail(String value) {
    final String v = value.trim();
    final int at = v.indexOf('@');
    if (at <= 0 || at == v.length - 1) return false;
    final String domain = v.substring(at + 1);
    return domain.contains('.') &&
        !domain.startsWith('.') &&
        !domain.endsWith('.') &&
        !domain.contains('@');
  }

  /// 冷启动只读本机，**不发网络**（避免启动即联网 / 启动被网络卡住）。
  @override
  Future<AuthState> build() async {
    final TokenStore store = ref.watch(tokenStoreProvider);
    try {
      final String? raw = await store.read(kSyncSessionKey);
      final String? email = await store.read(kSyncEmailKey);
      return AuthState(session: AuthSession.tryParse(raw), email: email);
    } on SecureStoreException {
      // 读不出来 = 未登录，不能让一个坏 key 把 App 拦在启动页
      return const AuthState();
    }
  }

  /// 发验证码。
  Future<void> requestCode(String email) async {
    if (!isValidEmail(email)) {
      throw const SyncApiException('invalidInput', message: '邮箱格式不对');
    }
    await ref.read(syncApiProvider).requestCode(email.trim());
  }

  /// 校验验证码并登录。
  Future<void> signIn({required String email, required String code}) async {
    final String normalized = email.trim();
    if (!isValidEmail(normalized)) {
      throw const SyncApiException('invalidInput', message: '邮箱格式不对');
    }
    final AuthSession session = await ref
        .read(syncApiProvider)
        .verify(normalized, code.trim());
    await _save(session, normalized);
  }

  /// 退出登录：**本地优先** —— 即使服务端吊销失败，本机也必须退出去。
  Future<void> signOut() async {
    final AuthSession? session = state.value?.session;
    if (session != null) {
      try {
        await ref.read(syncApiProvider).logout(
          accessToken: session.accessToken,
          refreshToken: session.refreshToken,
        );
      } on Object {
        // 网络不通 / 服务器没配置 / 401 都不该阻止用户退出
      }
    }
    await _clearSession();
  }

  /// 注销账号：云端硬删成功后才清本机（失败要把异常交给 UI）。
  Future<void> deleteAccount() async {
    await _withAuth(
      (String token) => ref.read(syncApiProvider).deleteAccount(token),
    );
    await ref.read(cloudSyncEnabledProvider.notifier).setEnabled(false);
    await _clearSession();
  }

  // ── 云备份（P6.3）────────────────────────────────────────────────

  /// 上传当前账本备份到云端（覆盖「最新备份」）。
  Future<BackupInfo> uploadCurrentBackup() async {
    final Uint8List bytes = await ref.read(currentBackupBytesProvider.future);
    return _withAuth(
      (String token) => ref.read(syncApiProvider).uploadLatestBackup(
        accessToken: token,
        bytes: bytes,
      ),
    );
  }

  /// 云端最新备份的元数据；没有备份返回 null。
  Future<BackupInfo?> latestBackup() async {
    final List<BackupInfo> list = await _withAuth(
      (String token) => ref.read(syncApiProvider).listBackups(token),
    );
    return list.isEmpty ? null : list.first;
  }

  /// 下载云端最新备份原文。
  Future<Uint8List> downloadLatestBackup() => _withAuth(
    (String token) => ref.read(syncApiProvider).downloadLatestBackup(token),
  );

  /// 供同步引擎复用「401 自动续期」。
  Future<T> authorized<T>(Future<T> Function(String accessToken) run) =>
      _withAuth(run);

  /// 带一次 401 续期的调用：refresh 成功 → 落新 token → 重放一次。
  Future<T> _withAuth<T>(Future<T> Function(String token) run) async {
    final AuthState? current = state.value;
    final AuthSession? session = current?.session;
    if (session == null) {
      throw const SyncApiException('unauthorized', statusCode: 401);
    }

    try {
      return await run(session.accessToken);
    } on SyncApiException catch (e) {
      if (e.code != 'unauthorized') rethrow;

      AuthSession? refreshed;
      try {
        refreshed = await ref
            .read(syncApiProvider)
            .refresh(session.refreshToken);
      } on Object {
        refreshed = null;
      }
      if (refreshed == null) {
        await _clearSession();
        rethrow;
      }
      await _save(refreshed, current?.email ?? '');
      return run(refreshed.accessToken);
    }
  }

  Future<void> _save(AuthSession session, String email) async {
    final TokenStore store = ref.read(tokenStoreProvider);
    // token 先落盘：写失败就让登录失败，不能只改内存状态
    await store.write(kSyncSessionKey, session.toStorageJson());
    await store.write(kSyncEmailKey, email);
    state = AsyncData(AuthState(session: session, email: email));
  }

  Future<void> _clearSession() async {
    final TokenStore store = ref.read(tokenStoreProvider);
    try {
      await store.delete(kSyncSessionKey);
    } on SecureStoreException {
      // 删不掉也只能当作已退出；下次启动若还能读出来，用户再点一次退出
    }
    state = AsyncData(AuthState(email: state.value?.email));
  }
}

class CloudSyncEnabledController extends AsyncNotifier<bool> {
  @override
  Future<bool> build() async {
    try {
      final String? raw = await ref
          .watch(appMetaRepositoryProvider)
          .get(kCloudSyncEnabledKey);
      return raw == '1';
    } catch (_) {
      return false;
    }
  }

  /// 切换开关：先切 UI 再写库（写失败本次会话仍生效，与主题控制器同口径）。
  Future<void> setEnabled(bool value) async {
    state = AsyncData<bool>(value);
    try {
      await ref
          .read(appMetaRepositoryProvider)
          .set(kCloudSyncEnabledKey, value ? '1' : '0');
    } catch (_) {
      // 低风险偏好，不打断用户
    }
  }
}
