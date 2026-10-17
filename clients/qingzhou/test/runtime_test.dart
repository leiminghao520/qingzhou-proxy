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
  for (final mode in ['systemProxy', 'compatible', 'tun']) {
    testWidgets('Windows $mode 分离核心和登录用户的系统代理检测', (tester) async {
      var proxyQueries = 0;
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(NativeRuntime.channel, (call) async {
        if (call.method == 'proxyStatus') {
          proxyQueries++;
          expect(call.arguments, 2080);
          return {
            'state': 'unverified',
            'code': 'automatic_proxy_enabled',
            'message': '已启用自动代理，尚不能确认应用实际采用的代理',
          };
        }
        final request = jsonDecode(call.arguments as String) as Map;
        expect(['status', 'query'], contains(request['method']));
        if (request['method'] == 'query') {
          expect(request['arguments'], '/diagnostics');
        }
        return jsonEncode({
          'value': jsonEncode({
            'state': 'connected',
            'coreRunning': true,
            'captureMode': mode,
            'listenPort': 2080,
            'diagnostics': {
              'core': {'state': 'passed'},
              'https': {'state': 'unverified'},
              'systemProxy': {'state': 'passed'},
            },
          }),
        });
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(NativeRuntime.channel, null),
      );
      final runtime = NativeRuntime(useWindowsTransport: true);
      for (final report in [
        await runtime.status(),
        await runtime.query('/diagnostics'),
      ]) {
        expect(report['state'], 'connected');
        expect(report['diagnostics']['core']['state'], 'passed');
        expect(report['diagnostics']['https']['state'], 'unverified');
        expect(
          report['diagnostics']['systemProxy']['state'],
          'unverified',
        );
      }
      expect(proxyQueries, mode == 'tun' ? 0 : 2);
    });
  }
  testWidgets('旧 Windows 桥接保持检测未验证并保留服务错误', (tester) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(NativeRuntime.channel, (call) async {
      if (call.method != 'rpc') throw MissingPluginException();
      final request = jsonDecode(call.arguments as String) as Map;
      if (request['method'] == 'start') {
        return jsonEncode({'error': 'core_start_failed'});
      }
      return jsonEncode({
        'value': jsonEncode({
          'coreRunning': true,
          'captureMode': 'systemProxy',
          'listenPort': 2080,
        }),
      });
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(NativeRuntime.channel, null),
    );
    final runtime = NativeRuntime(useWindowsTransport: true);
    expect((await runtime.status())['diagnostics']['systemProxy'], {
      'state': 'unverified',
      'code': 'bridge_unsupported',
      'message': '当前客户端不支持系统代理检测',
    });
    await expectLater(
      runtime.start({}),
      throwsA(isA<FormatException>().having(
        (error) => error.message,
        '服务错误',
        'core_start_failed',
      )),
    );
  });
  testWidgets('Windows 通信失败保留阶段和 Win32 错误码', (tester) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(NativeRuntime.channel, (call) async {
      throw PlatformException(
        code: 'service',
        message: 'Windows 服务通信失败 (wait_pipe, Win32 2)',
        details: {'stage': 'wait_pipe', 'win32Error': 2},
      );
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(NativeRuntime.channel, null),
    );
    await expectLater(
      NativeRuntime(useWindowsTransport: true).status(),
      throwsA(isA<FormatException>().having(
        (error) => error.message,
        '服务通信阶段',
        'Windows 服务通信失败 (wait_pipe, Win32 2)',
      )),
    );
  });
  testWidgets('Windows 广播失败不误报核心启动失败', (tester) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(NativeRuntime.channel, (call) async {
      if (call.method == 'notifyProxy') {
        return {'state': 'failed', 'code': 'proxy_notify_5'};
      }
      final request = jsonDecode(call.arguments as String) as Map;
      if (request['method'] == 'start') return '{}';
      return jsonEncode({
        'value': jsonEncode({'coreRunning': false}),
      });
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(NativeRuntime.channel, null),
    );
    final runtime = NativeRuntime(useWindowsTransport: true);
    await runtime.start({});
    final diagnostics = (await runtime.status())['diagnostics'];
    expect(diagnostics['proxyNotification']['code'], 'proxy_notify_5');
    expect(diagnostics['systemProxy']['state'], 'unverified');
  });
}
