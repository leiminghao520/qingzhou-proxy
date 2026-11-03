import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import '../domain/catalog.dart';

abstract class Runtime {
  Future<Json> capabilities();
  Future<void> validate(Json request);
  Future<void> start(Json request);
  Future<void> stop();
  Future<void> recover();
  Future<Json> status();
  Future<Json> query(String path);
  Future<void> select(String target);
  Future<int> delay(String tag);
  Future<int> probe(Json request);
}

class NativeRuntime implements Runtime {
  static const channel = MethodChannel('cn.qingzhou/runtime');
  final bool _windowsTransport;
  Json? _proxyNotification;
  NativeRuntime({bool? useWindowsTransport})
    : _windowsTransport = useWindowsTransport ?? Platform.isWindows;
  Future<T?> _call<T>(String method, [dynamic args]) async {
    if (!_windowsTransport) {
      final operation = channel.invokeMethod<T>(method, args);
      // VPN 系统授权由用户决定完成时间，不能超时后又在后台建立连接。
      if (method == 'start') return operation;
      return operation.timeout(const Duration(seconds: 45));
    }
    String? raw;
    try {
      raw = await channel
          .invokeMethod<String>(
            'rpc',
            jsonEncode({'method': method, 'arguments': args ?? ''}),
          )
          .timeout(const Duration(seconds: 45));
    } on PlatformException catch (error) {
      if (error.code != 'service') rethrow;
      throw FormatException(redact(error.message ?? 'Windows 服务通信失败'));
    }
    final envelope = jsonDecode(raw!) as Json;
    if (['start', 'stop', 'recover'].contains(method)) {
      // 广播失败不能掩盖服务错误，也不能把已启动的核心误报为启动失败。
      try {
        final value = await channel.invokeMapMethod<String, dynamic>(
          'notifyProxy',
        );
        _proxyNotification = value == null ? null : Map<String, dynamic>.from(value);
      } on MissingPluginException {
        _proxyNotification = {
          'state': 'unverified',
          'code': 'bridge_unsupported',
          'message': '当前客户端不支持代理设置刷新检测',
        };
      } on PlatformException {
        _proxyNotification = {
          'state': 'failed',
          'code': 'proxy_notify_failed',
          'message': 'Windows 代理设置刷新失败',
        };
      }
    }
    if (envelope['error'] != null) {
      throw FormatException(envelope['error'] as String);
    }
    if ([
      'capabilities',
      'status',
      'query',
      'delay',
      'probe',
    ].contains(method)) {
      return envelope['value'] as T;
    }
    return null;
  }

  Future<Json> _json(String method, [dynamic args]) async =>
      jsonDecode((await _call<String>(method, args))!) as Json;
  @override
  Future<Json> capabilities() => _json('capabilities');
  @override
  Future<void> validate(Json request) =>
      _call<void>('validate', jsonEncode(request));
  @override
  Future<void> start(Json request) => _call<void>('start', jsonEncode(request));
  @override
  Future<void> stop() => _call<void>('stop');
  @override
  Future<void> recover() => _call<void>('recover');
  @override
  Future<Json> status() async => _withWindowsDiagnostics(await _json('status'));
  @override
  Future<Json> query(String path) async {
    final report = await _json('query', path);
    if (path == '/diagnostics') return _withWindowsDiagnostics(report);
    return report;
  }

  Future<Json> _withWindowsDiagnostics(Json report) async {
    if (!_windowsTransport) return report;
    final diagnostics = Map<String, dynamic>.from(
      report['diagnostics'] as Map? ?? const {},
    );
    Json check = {
      'state': 'unverified',
      'code': 'not_applicable',
      'message': '当前模式或核心状态不适用系统代理检测',
    };
    final mode = report['captureMode'];
    final port = report['listenPort'];
    if (report['coreRunning'] == true &&
        (mode == 'systemProxy' || mode == 'compatible')) {
      check = {
        'state': 'unverified',
        'code': 'invalid_listen_port',
        'message': '尚无有效的本地代理端口',
      };
      if (port is int && port > 0 && port <= 65535) {
        try {
          final value = await channel.invokeMapMethod<String, dynamic>(
            'proxyStatus',
            port,
          );
          check = value == null
              ? {
                  'state': 'unverified',
                  'code': 'bridge_unsupported',
                  'message': '当前客户端不支持系统代理检测',
                }
              : Map<String, dynamic>.from(value);
        } on MissingPluginException {
          check = {
            'state': 'unverified',
            'code': 'bridge_unsupported',
            'message': '当前客户端不支持系统代理检测',
          };
        } on PlatformException {
          check = {
            'state': 'failed',
            'code': 'wininet_query_failed',
            'message': '无法读取当前用户的 Windows 代理设置',
          };
        }
      }
    }
    diagnostics['systemProxy'] = check;
    if (_proxyNotification != null) {
      diagnostics['proxyNotification'] = _proxyNotification;
    }
    return {...report, 'diagnostics': diagnostics};
  }
  @override
  Future<int> probe(Json request) async =>
      (await _json('probe', jsonEncode(request)))['milliseconds'] as int;
  @override
  Future<int> delay(String tag) async =>
      (await _json('delay', tag))['milliseconds'] as int;
  @override
  Future<void> select(String target) => _call<void>('select', target);
}

String redact(String input, [Iterable<String> secrets = const []]) {
  var value = input;
  for (final secret
      in secrets.where((s) => s.isNotEmpty).toList()
        ..sort((a, b) => b.length.compareTo(a.length))) {
    value = value.replaceAll(secret, '[已隐藏]');
  }
  value = value.replaceAll(
    RegExp(
      r'(?:https?|hy2|hysteria2|ss|trojan|vless)://[^\s"<>]+',
      caseSensitive: false,
    ),
    '[已隐藏]',
  );
  value = value.replaceAll(
    RegExp(
      r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}',
      caseSensitive: false,
    ),
    '[已隐藏]',
  );
  return value.length > 2048 ? value.substring(0, 2048) : value;
}
