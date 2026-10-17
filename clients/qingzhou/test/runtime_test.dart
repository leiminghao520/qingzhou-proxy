import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingzhou/platform/runtime.dart';

void main() {
  testWidgets('Windows 桥接封装受限请求并在接管变化后广播', (tester) async {
    var running = false, notifications = 0;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(NativeRuntime.channel, (call) async {
      if (call.method == 'notifyProxy') {
        notifications++;
        return null;
      }
      expect(call.method, 'rpc');
      final request = jsonDecode(call.arguments as String) as Map;
      expect(request['arguments'], isA<String>());
      switch (request['method']) {
        case 'capabilities':
          return jsonEncode({
            'value': jsonEncode({
              'captureModes': ['systemProxy'],
            }),
          });
        case 'validate':
          expect(jsonDecode(request['arguments'] as String), {'mode': 'rule'});
          return '{}';
        case 'start':
          running = true;
          return '{}';
        case 'stop':
          running = false;
          return '{}';
        case 'status':
          return jsonEncode({
            'value': jsonEncode({
              'state': running ? 'connected' : 'disconnected',
            }),
          });
        case 'query':
          return jsonEncode({'error': '查询不支持'});
        default:
          fail('意外的桥接操作');
      }
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(NativeRuntime.channel, null),
    );
    final runtime = NativeRuntime(useWindowsTransport: true);
    expect((await runtime.capabilities())['captureModes'], ['systemProxy']);
    await runtime.validate({'mode': 'rule'});
    await runtime.start({'mode': 'rule'});
    expect((await runtime.status())['state'], 'connected');
    await expectLater(runtime.query('/configs'), throwsFormatException);
    expect(notifications, 1);
    await runtime.stop();
    expect((await runtime.status())['state'], 'disconnected');
    expect(notifications, 2);
  });
  testWidgets('系统 VPN 授权等待超过一分钟仍由用户完成', (tester) async {
    final consent = Completer<void>();
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(NativeRuntime.channel, (
      MethodCall call,
    ) async {
      expect(call.method, 'start');
      await consent.future;
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(NativeRuntime.channel, null),
    );
    var completed = false;
    final pending = NativeRuntime(
      useWindowsTransport: false,
    ).start({}).then((_) => completed = true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 65));
    expect(completed, false);
    consent.complete();
    await tester.pump();
    await pending;
    expect(completed, true);
  });
}
