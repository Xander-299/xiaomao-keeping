/// 云同步的**网络闸门**（P6.1）。
///
/// 为什么要一个专门的闸门：加了 `INTERNET` 权限之后，「本 App 不会偷偷联网」这句话就不能再靠
/// 清单文件撑着了，必须落到代码里、且**只有一个入口**。任何要发请求的地方都得先问它：
///
/// ```dart
/// final CloudSyncDenial? denial = gate.denialFor(uri);
/// if (denial != null) return; // 连 socket 都不建
/// ```
///
/// 拒绝的四种原因各自对应一个用户可理解的状态，界面上不要统一说成「同步失败」：
/// - [CloudSyncDenial.signedOut] —— 没登录（默认态，**老用户永远不会看到任何请求**）；
/// - [CloudSyncDenial.disabledByUser] —— 登录了但把同步开关关了；
/// - [CloudSyncDenial.notConfigured] —— 构建期没配服务器地址（开发包常见）；
/// - [CloudSyncDenial.insecureEndpoint] —— 地址不是 HTTPS（拒绝，不给「仅本次允许」）；
/// - [CloudSyncDenial.hostNotAllowlisted] —— 主机不在白名单（防配置被改后把账本导去别处）。
library;

import 'package:yanxin/core/network/sync_endpoints.dart';

/// 拒绝原因（null = 放行）。
enum CloudSyncDenial {
  signedOut,
  disabledByUser,
  notConfigured,
  insecureEndpoint,
  hostNotAllowlisted,
}

extension CloudSyncDenialText on CloudSyncDenial {
  /// 给设置页 / 日志用的一句话（不用于弹窗打扰）。
  String get label => switch (this) {
    CloudSyncDenial.signedOut => '未登录',
    CloudSyncDenial.disabledByUser => '同步已关闭',
    CloudSyncDenial.notConfigured => '未配置服务器地址',
    CloudSyncDenial.insecureEndpoint => '服务器地址必须使用 HTTPS',
    CloudSyncDenial.hostNotAllowlisted => '服务器地址不在白名单内',
  };
}

/// 闸门：**纯判断，不做 IO**，可以在任何地方同步调用。
class CloudSyncGate {
  const CloudSyncGate({
    required this.signedIn,
    required this.userEnabled,
  });

  /// 是否已登录（P6.2 接账号体系；当前恒为 false）。
  final bool signedIn;

  /// 用户是否在设置里打开了「云同步」（默认关）。
  final bool userEnabled;

  /// 为什么不让发请求；null = 可以发。
  CloudSyncDenial? denialFor(Uri uri) {
    if (!signedIn) return CloudSyncDenial.signedOut;
    if (!userEnabled) return CloudSyncDenial.disabledByUser;
    if (!SyncEndpoints.isConfigured) return CloudSyncDenial.notConfigured;
    if (uri.scheme != 'https') return CloudSyncDenial.insecureEndpoint;
    if (!SyncEndpoints.allowlistedHosts.contains(uri.host)) {
      return CloudSyncDenial.hostNotAllowlisted;
    }
    return null;
  }

  bool allows(Uri uri) => denialFor(uri) == null;

  /// 当前是否处于「可以联网」的状态（设置页显示状态用）。
  bool get isOpen => denialFor(SyncEndpoints.resolve('/')) == null;
}

/// 默认闸门：**什么都没开通**。
///
/// P6.2 接上账号后，把这个换成读 `authProvider` / `syncSettingsProvider` 的实现；
/// 在那之前它是常量 —— 也就是说即使包里带了 `INTERNET`，也一条请求都发不出去。
const CloudSyncGate kClosedCloudSyncGate = CloudSyncGate(
  signedIn: false,
  userEnabled: false,
);
