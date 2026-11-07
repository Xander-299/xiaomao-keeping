part of '../toon.dart';

// ────────────────────────────── 交互反馈 ──────────────────────────────

/// 轻提示语义。只区分用户需要理解的状态，不做大面积色块强调。
enum ToonFeedbackKind { info, success, error }

const Duration _toonShortFeedback = Duration(seconds: 2);
const Duration _toonLongFeedback = Duration(seconds: 4);

Duration _toonFeedbackDuration(ToonFeedbackKind kind) => switch (kind) {
      ToonFeedbackKind.success || ToonFeedbackKind.info => _toonShortFeedback,
      ToonFeedbackKind.error => _toonLongFeedback,
    };

/// 生成统一样式的 SnackBar。
///
/// 弹层关闭后仍要发提示的页面可先持有 `ScaffoldMessengerState`，再用这里返回的
/// SnackBar 展示；普通页面优先用 [showToonFeedback]。
SnackBar toonFeedbackSnackBar(
  ToonPalette p,
  String message, {
  ToonFeedbackKind kind = ToonFeedbackKind.info,
  Duration? duration,
  SnackBarAction? action,
}) {
  final (IconData icon, Color color) = switch (kind) {
    ToonFeedbackKind.success => (Icons.check_circle_outline_rounded, p.green),
    ToonFeedbackKind.error => (Icons.error_outline_rounded, p.red),
    ToonFeedbackKind.info => (Icons.info_outline_rounded, p.blue),
  };
  return SnackBar(
    content: Row(
      children: <Widget>[
        Icon(icon, size: 18, color: color),
        const SizedBox(width: Tok.s8),
        Expanded(child: Text(message)),
      ],
    ),
    duration: duration ?? _toonFeedbackDuration(kind),
    action: action,
  );
}

/// 弹层关闭后不能用 [BuildContext] 发反馈时，走这个 messenger-safe 入口。
void showToonFeedbackOnMessenger({
  required ScaffoldMessengerState messenger,
  required ToonPalette palette,
  required String message,
  ToonFeedbackKind kind = ToonFeedbackKind.info,
  Duration? duration,
  SnackBarAction? action,
}) {
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      toonFeedbackSnackBar(
        palette,
        message,
        kind: kind,
        duration: duration,
        action: action,
      ),
    );
}

/// 成功反馈：保存 / 新增 / 删除等短提示。
void showToonSuccess(
  BuildContext context,
  String message, {
  Duration? duration,
  SnackBarAction? action,
}) => showToonFeedback(
      context,
      message,
      kind: ToonFeedbackKind.success,
      duration: duration,
      action: action,
    );

/// 错误反馈：默认展示更久，让用户来得及读完原因。
void showToonError(BuildContext context, String message) =>
    showToonFeedback(context, message, kind: ToonFeedbackKind.error);

/// 可撤销操作反馈；Undo 的业务恢复由调用方提供。
void showToonUndo(
  BuildContext context,
  String message, {
  required VoidCallback onUndo,
}) => showToonFeedback(
      context,
      message,
      kind: ToonFeedbackKind.success,
      duration: _toonLongFeedback,
      action: SnackBarAction(label: '撤销', onPressed: onUndo),
    );

/// messenger-safe 的错误反馈。
void showToonErrorOnMessenger({
  required ScaffoldMessengerState messenger,
  required ToonPalette palette,
  required String message,
}) => showToonFeedbackOnMessenger(
      messenger: messenger,
      palette: palette,
      message: message,
      kind: ToonFeedbackKind.error,
    );

/// 统一轻提示：替换各页手写 `ScaffoldMessenger.showSnackBar` 的重复样板。
void showToonFeedback(
  BuildContext context,
  String message, {
  ToonFeedbackKind kind = ToonFeedbackKind.info,
  Duration? duration,
  SnackBarAction? action,
}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      toonFeedbackSnackBar(
        context.toon,
        message,
        kind: kind,
        duration: duration ?? _toonFeedbackDuration(kind),
        action: action,
      ),
    );
}
