import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import '../domain/backup.dart';
import '../domain/catalog.dart';

abstract class Repository {
  Future<Snapshot?> load();
  Future<void> save(Snapshot snapshot);
  Future<Json> preferences();
  Future<void> savePreferences(Json preferences);
}

class SecureRepository implements Repository {
  final FlutterSecureStorage storage;
  SecureRepository({this.storage = const FlutterSecureStorage()});
  static const _pointer = 'qingzhou.snapshot.current';
  static const _key = 'qingzhou.snapshot.key';
  Future<Directory> _directory() async {
    final root = await getApplicationSupportDirectory();
    final d = Directory('${root.path}/Qingzhou');
    await d.create(recursive: true);
    return d;
  }

  Future<SecretKey> _secret({bool create = false}) async {
    var value = await storage.read(key: _key);
    if (value == null) {
      if (!create) throw const FormatException('本地凭据密钥缺失，请从备份恢复');
      value = base64Encode(SecretKeyData.random(length: 32).bytes);
      if (Platform.isWindows) {
        final wrapped = await const MethodChannel(
          'cn.qingzhou/runtime',
        ).invokeMethod<Uint8List>('protectSecret', base64Decode(value));
        if (wrapped == null) throw const FormatException('DPAPI 密钥保护失败');
        value = 'dpapi-v1:${base64Encode(wrapped)}';
      }
      await storage.write(key: _key, value: value);
    }
    if (Platform.isWindows) {
      if (!value.startsWith('dpapi-v1:')) {
        throw const FormatException('DPAPI 密钥格式无效');
      }
      final key = await const MethodChannel('cn.qingzhou/runtime')
          .invokeMethod<Uint8List>(
            'unprotectSecret',
            base64Decode(value.substring(9)),
          );
      if (key == null || key.length != 32) {
        throw const FormatException('DPAPI 密钥不可用');
      }
      return SecretKey(key);
    }
    return SecretKey(base64Decode(value));
  }

  @override
  Future<Snapshot?> load() async {
    final pointer = await storage.read(key: _pointer);
    if (pointer == null) return null;
    if (!RegExp(r'^snapshot-[0-9a-f-]+\.qzs$').hasMatch(pointer)) {
      throw const FormatException('本地快照引用无效');
    }
    final file = File('${(await _directory()).path}/$pointer');
    if (await file.length() > 48 * 1024 * 1024) {
      throw const FormatException('本地快照过大');
    }
    final data = await file.readAsBytes();
    if (data.length < 28) throw const FormatException('本地快照损坏');
    final plain = await AesGcm.with256bits().decrypt(
      SecretBox(
        data.sublist(12, data.length - 16),
        nonce: data.sublist(0, 12),
        mac: Mac(data.sublist(data.length - 16)),
      ),
      secretKey: await _secret(),
      aad: utf8.encode('QingzhouLocal-v1'),
    );
    final json = jsonDecode(utf8.decode(plain)) as Json;
    if (json['version'] != 1) throw const FormatException('本地快照版本无效');
    return Snapshot(
      Catalog(json['catalog'] as Json),
      Map<String, String>.from(json['credentials'] as Map),
    );
  }

  @override
  Future<void> save(Snapshot snapshot) async {
    snapshot.catalog.validate();
    final plain = utf8.encode(jsonEncode(snapshot.toJson()));
    if (plain.length > 32 * 1024 * 1024) {
      throw const FormatException('本地数据超过 32 MiB');
    }
    final box = await AesGcm.with256bits().encrypt(
      plain,
      secretKey: await _secret(create: true),
      aad: utf8.encode('QingzhouLocal-v1'),
    );
    final d = await _directory();
    final name = 'snapshot-${ids.v4()}.qzs';
    final file = File('${d.path}/$name');
    final old = await storage.read(key: _pointer);
    await file.writeAsBytes([
      ...box.nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ], flush: true);
    // 先保存完整加密快照，再原子提交安全存储中的引用；失败保留上一版本。
    try {
      await storage.write(key: _pointer, value: name);
    } catch (_) {
      await file.delete();
      rethrow;
    }
    if (old != null && RegExp(r'^snapshot-[0-9a-f-]+\.qzs$').hasMatch(old)) {
      try {
        await File('${d.path}/$old').delete();
      } catch (_) {}
    }
  }

  @override
  Future<Json> preferences() async =>
      jsonDecode(await storage.read(key: 'qingzhou.preferences') ?? '{}')
          as Json;
  @override
  Future<void> savePreferences(Json preferences) => storage.write(
    key: 'qingzhou.preferences',
    value: jsonEncode(preferences),
  );
}
