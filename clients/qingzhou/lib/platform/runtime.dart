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
  NativeRuntime({bool? useWindowsTransport})
    : _windowsTransport = useWindowsTransport ?? Platform.isWindows;
  Future<T?> _call<T>(String method, [dynamic args]) async {
    if (!_windowsTransport) {
      final operation = channel.invokeMethod<T>(method, args);
      // VPN 系统授权由用户决定完成时间，不能超时后又在后台建立连接。
      if (method == 'start') return operation;
      return operation.timeout(const Duration(seconds: 45));
    }
    final raw = await channel
        .invokeMethod<String>(
          'rpc',
          jsonEncode({'method': method, 'arguments': args ?? ''}),
        )
        .timeout(const Duration(seconds: 45));
    final envelope = jsonDecode(raw!) as Json;
    if (['start', 'stop', 'recover'].contains(method)) {
      await channel.invokeMethod<void>('notifyProxy');
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
  Future<Json> status() => _json('status');
  @override
  Future<Json> query(String path) => _json('query', path);
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
