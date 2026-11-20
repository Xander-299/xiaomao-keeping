// 用 Dart VM service 的 WebSocket 接口 dump Flutter widget 树 / 渲染树。
//
// 为什么需要它：Flutter 只有开了无障碍语义才会把文案暴露给 `uiautomator`；
// 实测小米/模拟器上 `settings put secure accessibility_enabled 1` 写不进去，
// `uiautomator dump` 只能拿到容器节点。这个脚本走 **VM service 的调试扩展**，
// debug 构建里能直接读到 widget 树里的 `Text("…")` 与 RenderBox 的 offset/size。
//
// 用法（debug 包、App 正在运行）：
//   1) adb logcat -d | grep "Dart VM service"        # 取 http://127.0.0.1:PORT/TOKEN=/
//   2) adb forward tcp:PORT tcp:PORT
//   3) dart run tool/dump_widget_tree.dart ws://127.0.0.1:PORT/TOKEN=/ws
//      想读坐标/尺寸：在同一命令后加第二个参数 ext.flutter.debugDumpRenderTree
//
// 输出很大，建议重定向到文件后 grep：`grep -oE 'Text\("[^"]*"' tree.txt`。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final String wsUrl = args.isNotEmpty ? args[0] : '';
  final String ext = args.length > 1 ? args[1] : 'ext.flutter.debugDumpApp';
  if (wsUrl.isEmpty) {
    stderr.writeln('usage: dump_widget_tree.dart <ws-url> [service-extension]');
    exit(2);
  }
  final WebSocket ws = await WebSocket.connect(wsUrl);
  final StreamIterator<dynamic> it = StreamIterator<dynamic>(ws);
  int id = 0;

  Future<Map<String, dynamic>> call(String method, [Map<String, dynamic>? params]) async {
    final int myId = ++id;
    ws.add(jsonEncode(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': myId,
      'method': method,
      'params': params ?? const <String, dynamic>{},
    }));
    while (await it.moveNext()) {
      final dynamic msg = jsonDecode(it.current as String);
      if (msg is Map && msg['id'] == myId) {
        return Map<String, dynamic>.from(msg);
      }
    }
    throw StateError('connection closed');
  }

  final Map<String, dynamic> vm = await call('getVM');
  final List<dynamic> isolates =
      ((vm['result'] as Map?)?['isolates'] as List<dynamic>?) ?? const <dynamic>[];
  final String isolateId =
      isolates.isEmpty ? '' : (isolates.first as Map)['id'] as String;
  // 服务扩展本身就是 RPC 方法名（如 ext.flutter.debugDumpApp），参数只要 isolateId
  final Map<String, dynamic> res = await call(ext, <String, dynamic>{
    'isolateId': isolateId,
  });
  final Object? data = (res['result'] as Map?)?['data'];
  stdout.writeln(data ?? jsonEncode(res));
  await ws.close();
}
