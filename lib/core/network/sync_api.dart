/// 云同步 HTTP 客户端（P6.2：账号 + 续期；P6.3 再补备份接口）。
///
/// 三条硬约束：
/// 1. **每个请求都必须先过 [CloudSyncGate]** —— 这是「不偷偷联网」的唯一入口，
///    不变量 #8 不放；
/// 2. 认证接口（发码 / 校验 / 续期 / 退出 / 注销）在「未登录 / 用户关了开关」时也放行，
///    否则登录本身会被闸门按「未登录」拒掉；
/// 3. 传输层可注入（[SyncTransport]），单测不建真 socket。
///
/// 协议见 `docs/spec/SPEC-P6-cloud-sync.md` §9。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'cloud_sync_gate.dart';
import 'sync_endpoints.dart';

/// 登录态（两个 token 都是服务端签发的，客户端不解析 JWT 内容）。
class AuthSession {
  const AuthSession({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
  });

  /// `POST /v1/auth/verify` 与 `/v1/auth/refresh` 的响应。
  ///
  /// `expiresIn` 单位是秒；缺失或脏值按 900 s（与 SPEC 一致）回落，不抛错 ——
  /// 过期只影响主动刷新，不影响「已登录」这个事实。
  factory AuthSession.fromJson(Map<String, Object?> json, {DateTime? now}) {
    final Object? access = json['accessToken'];
    final Object? refresh = json['refreshToken'];
    if (access is! String || access.isEmpty) {
      throw const SyncApiException('invalidResponse', message: '缺少 accessToken');
    }
    if (refresh is! String || refresh.isEmpty) {
      throw const SyncApiException('invalidResponse', message: '缺少 refreshToken');
    }
    final Object? rawExpires = json['expiresIn'];
    final int seconds = rawExpires is num && rawExpires > 0
        ? rawExpires.toInt()
        : 900;
    return AuthSession(
      accessToken: access,
      refreshToken: refresh,
      expiresAt: (now ?? DateTime.now()).add(Duration(seconds: seconds)),
    );
  }

  /// 从本机存储恢复；坏数据返回 null（= 未登录），不让 App 起不来。
  static AuthSession? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) return null;
      final Object? access = decoded['accessToken'];
      final Object? refresh = decoded['refreshToken'];
      final Object? expires = decoded['expiresAtMs'];
      if (access is! String ||
          access.isEmpty ||
          refresh is! String ||
          refresh.isEmpty ||
          expires is! int) {
        return null;
      }
      return AuthSession(
        accessToken: access,
        refreshToken: refresh,
        expiresAt: DateTime.fromMillisecondsSinceEpoch(expires),
      );
    } on FormatException {
      return null;
    }
  }

  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;

  /// 过期判定留 30 s 余量，避免「刚好在请求途中过期」。
  bool get isExpired =>
      DateTime.now().isAfter(expiresAt.subtract(const Duration(seconds: 30)));

  String toStorageJson() => jsonEncode(<String, Object>{
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'expiresAtMs': expiresAt.millisecondsSinceEpoch,
  });
}

/// 云端备份的一条元数据（上传响应 / 列表项）。
class BackupInfo {
  const BackupInfo({
    this.id,
    required this.size,
    this.sha256,
    required this.createdAt,
  });

  factory BackupInfo.fromJson(Map<String, Object?> json) {
    final Object? rawSize = json['size'];
    final Object? rawCreated = json['createdAt'];
    final Object? rawId = json['id'];
    final Object? rawSha = json['sha256'];
    final int size = rawSize is num ? rawSize.toInt() : 0;
    final DateTime createdAt =
        (rawCreated is String ? DateTime.tryParse(rawCreated) : null)
            ?.toLocal() ??
        DateTime.fromMillisecondsSinceEpoch(0);
    return BackupInfo(
      id: rawId is String && rawId.isNotEmpty ? rawId : null,
      size: size,
      sha256: rawSha is String && rawSha.isNotEmpty ? rawSha : null,
      createdAt: createdAt,
    );
  }

  /// 列表接口返回；上传响应没有 id。
  final String? id;
  final int size;
  final String? sha256;
  final DateTime createdAt;

  String get sizeLabel {
    if (size >= 1024 * 1024) {
      return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (size >= 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '$size B';
  }
}

/// 一次请求（传输层只认这个，不认业务语义）。
class SyncRequest {
  const SyncRequest({
    required this.method,
    required this.uri,
    this.headers = const <String, String>{},
    this.body,
    this.bodyBytes,
  });

  final String method;
  final Uri uri;
  final Map<String, String> headers;

  /// 文本体（JSON 请求用）。
  final String? body;

  /// 二进制体（云备份上传用）；与 [body] 二选一。
  final Uint8List? bodyBytes;
}

/// 一次响应。
class SyncResponse {
  const SyncResponse({required this.statusCode, required this.body});

  final int statusCode;
  final String body;

  bool get isSuccess => statusCode >= 200 && statusCode < 300;
}

/// 传输抽象：单测注入假实现，生产走 [HttpSyncTransport]。
abstract class SyncTransport {
  Future<SyncResponse> send(SyncRequest request);
}

/// `dart:io` 实现（不引第三方 HTTP 包 —— 依赖是锁死的）。
class HttpSyncTransport implements SyncTransport {
  HttpSyncTransport({
    HttpClient? client,
    this.timeout = const Duration(seconds: 15),
  }) : _client = client ?? HttpClient();

  final HttpClient _client;
  final Duration timeout;

  @override
  Future<SyncResponse> send(SyncRequest request) async {
    final HttpClientRequest req = await _client
        .openUrl(request.method, request.uri)
        .timeout(timeout);
    request.headers.forEach(req.headers.set);
    if (request.bodyBytes != null) {
      req.add(request.bodyBytes!);
    } else if (request.body != null) {
      req.write(request.body!);
    }
    final HttpClientResponse res = await req.close().timeout(timeout);
    final String body = await res
        .transform(utf8.decoder)
        .join()
        .timeout(timeout);
    return SyncResponse(statusCode: res.statusCode, body: body);
  }

  /// 关掉底层连接池（Provider 卸载时调用）。
  void close() => _client.close(force: true);
}

/// 闸门拒绝（**没建连**）。
class SyncDeniedException implements Exception {
  const SyncDeniedException(this.denial);

  final CloudSyncDenial denial;

  @override
  String toString() => 'SyncDeniedException(${denial.name})';
}

/// 业务错误：`code` 是稳定的机器码，`userMessage` 是给用户的一句话。
class SyncApiException implements Exception {
  const SyncApiException(this.code, {this.statusCode, this.message});

  /// network / timeout / unauthorized / rateLimited / server / invalidResponse /
  /// invalidCode / invalidInput / mailNotConfigured
  final String code;
  final int? statusCode;

  /// 调试用摘要（**不要直接展示给用户**，更不许带 token）。
  final String? message;

  String get userMessage => switch (code) {
    'network' => '网络不可用，请检查连接后重试',
    'timeout' => '服务器响应超时，请稍后再试',
    'unauthorized' => '登录已过期，请重新登录',
    'rateLimited' => '操作太频繁，请稍后再试',
    'invalidCode' => '验证码不正确或已过期，请重新获取',
    'invalidInput' => '输入有误，请检查邮箱与验证码',
    'mailNotConfigured' => '服务器还没配置发信服务，请稍后再试',
    'notFound' => '云端还没有备份',
    'tooLarge' => '备份超过 20 MB，无法上传',
    'server' => '服务器出错了，请稍后再试',
    'invalidResponse' => '服务器返回了无法识别的数据',
    _ => '同步失败，请稍后重试',
  };

  @override
  String toString() =>
      'SyncApiException($code${statusCode == null ? '' : ' $statusCode'})';
}

/// 云同步 API（P6.2 只有认证五接口）。
class SyncApi {
  SyncApi({required this.transport, required this.gate});

  final SyncTransport transport;
  final CloudSyncGate Function() gate;

  /// 发验证码。服务端无论邮箱是否存在都回 204（防枚举）。
  Future<void> requestCode(String email) async {
    await _send(
      'POST',
      '/v1/auth/request-code',
      body: <String, Object>{'email': email},
      auth: true,
    );
  }

  /// 校验验证码换 token。
  Future<AuthSession> verify(String email, String code) async {
    final SyncResponse res = await _send(
      'POST',
      '/v1/auth/verify',
      body: <String, Object>{'email': email, 'code': code},
      auth: true,
    );
    return AuthSession.fromJson(_jsonObject(res));
  }

  /// 续期（服务端会轮换 refresh token，两个都要换）。
  Future<AuthSession> refresh(String refreshToken) async {
    final SyncResponse res = await _send(
      'POST',
      '/v1/auth/refresh',
      body: <String, Object>{'refreshToken': refreshToken},
      auth: true,
    );
    return AuthSession.fromJson(_jsonObject(res));
  }

  /// 吊销 refresh token（服务端 204）。
  ///
  /// ⚠️ 服务端认的是**请求体里的 `refreshToken`**（`server/src/node/app.ts` 的
  /// `POST /v1/auth/logout`），只带 Bearer 会「看起来成功但没吊销」—— 这里两个都带。
  Future<void> logout({
    required String accessToken,
    required String refreshToken,
  }) async {
    await _send(
      'POST',
      '/v1/auth/logout',
      body: <String, Object>{'refreshToken': refreshToken},
      bearer: accessToken,
      auth: true,
    );
  }

  /// 注销：云端硬删用户与其备份（服务端 204）。
  Future<void> deleteAccount(String accessToken) async {
    await _send(
      'DELETE',
      '/v1/account',
      bearer: accessToken,
      auth: true,
    );
  }

  // ── 云备份（P6.3）────────────────────────────────────────────────

  /// 上传当前账本的备份 JSON（覆盖云端「最新备份」）。
  Future<BackupInfo> uploadLatestBackup({
    required String accessToken,
    required List<int> bytes,
  }) async {
    final SyncResponse res = await _send(
      'PUT',
      '/v1/backups/latest',
      bearer: accessToken,
      bodyBytes: Uint8List.fromList(bytes),
      auth: false,
    );
    return BackupInfo.fromJson(_jsonObject(res));
  }

  /// 下载云端最新备份原文。
  Future<Uint8List> downloadLatestBackup(String accessToken) async {
    final SyncResponse res = await _send(
      'GET',
      '/v1/backups/latest',
      bearer: accessToken,
      auth: false,
    );
    return Uint8List.fromList(utf8.encode(res.body));
  }

  /// 列出历史快照（最近 N 份）。
  Future<List<BackupInfo>> listBackups(String accessToken) async {
    final SyncResponse res = await _send(
      'GET',
      '/v1/backups',
      bearer: accessToken,
      auth: false,
    );
    final Object? decoded = jsonDecode(res.body);
    if (decoded is! List<Object?>) {
      throw const SyncApiException('invalidResponse');
    }
    return <BackupInfo>[
      for (final Object? item in decoded)
        if (item is Map<String, Object?>) BackupInfo.fromJson(item),
    ];
  }

  Future<SyncResponse> _send(
    String method,
    String path, {
    Map<String, Object>? body,
    Uint8List? bodyBytes,
    String? bearer,
    required bool auth,
  }) async {
    final Uri uri = SyncEndpoints.resolve(path);
    final CloudSyncDenial? denial = gate().denialFor(uri, auth: auth);
    if (denial != null) throw SyncDeniedException(denial);

    final Map<String, String> headers = <String, String>{
      'accept': 'application/json',
      if (body != null || bodyBytes != null) 'content-type': 'application/json',
      if (bearer != null) 'authorization': 'Bearer $bearer',
    };

    final SyncResponse res;
    try {
      res = await transport.send(
        SyncRequest(
          method: method,
          uri: uri,
          headers: headers,
          body: body == null ? null : jsonEncode(body),
          bodyBytes: bodyBytes,
        ),
      );
    } on TimeoutException {
      throw const SyncApiException('timeout');
    } on SocketException catch (e) {
      throw SyncApiException('network', message: e.message);
    } on HttpException catch (e) {
      throw SyncApiException('network', message: e.message);
    } on HandshakeException catch (e) {
      throw SyncApiException('network', message: e.message);
    } on SyncApiException {
      rethrow;
    } catch (e) {
      // 传输层是注入的：别让它的私有异常穿透到 UI
      throw SyncApiException('network', message: '$e');
    }

    if (res.statusCode == 401) {
      throw const SyncApiException('unauthorized', statusCode: 401);
    }
    if (res.statusCode == 429) {
      throw const SyncApiException('rateLimited', statusCode: 429);
    }
    if (res.statusCode == 404) {
      throw const SyncApiException('notFound', statusCode: 404);
    }
    if (res.statusCode == 413) {
      throw const SyncApiException('tooLarge', statusCode: 413);
    }
    if (!res.isSuccess) {
      throw SyncApiException(
        _mapServerCode(_errorCode(res.body)),
        statusCode: res.statusCode,
        message: _shortBody(res.body),
      );
    }
    return res;
  }

  /// 服务端的 4xx 是**有语义的**（`code_mismatch` / `code_expired` / …），
  /// 不能一律说成「服务器出错了」—— 用户会把验证码敲错当成服务挂了。
  String _mapServerCode(String? serverCode) => switch (serverCode) {
    'code_mismatch' || 'code_expired' => 'invalidCode',
    'invalid_input' => 'invalidInput',
    'mail_not_configured' => 'mailNotConfigured',
    'too_many_attempts' => 'rateLimited',
    'invalid_refresh_token' || 'unauthorized' => 'unauthorized',
    _ => 'server',
  };

  String? _errorCode(String body) {
    try {
      final Object? decoded = jsonDecode(body);
      if (decoded is Map<String, Object?>) {
        final Object? error = decoded['error'];
        if (error is String && error.isNotEmpty) return error;
      }
    } on FormatException {
      // 非 JSON 响应体：交给默认映射
    }
    return null;
  }

  Map<String, Object?> _jsonObject(SyncResponse res) {
    try {
      final Object? decoded = jsonDecode(res.body);
      if (decoded is Map<String, Object?>) return decoded;
    } on FormatException {
      // 落到下面统一的 invalidResponse
    }
    throw const SyncApiException('invalidResponse');
  }

  /// 日志/异常里只留一小段响应体，避免把大段内容带进 UI。
  String _shortBody(String body) =>
      body.length <= 160 ? body : '${body.substring(0, 160)}…';
}
