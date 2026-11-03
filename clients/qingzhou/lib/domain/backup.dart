import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'catalog.dart';

class Snapshot {
  final Catalog catalog;
  final Map<String, String> credentials;
  Snapshot(this.catalog, this.credentials) {
    if (!catalog.credentialRefs.every(credentials.containsKey)) {
      throw const FormatException('备份凭据缺失');
    }
  }
  Json toJson() => {
    'version': 1,
    'catalog': catalog.json,
    'credentials': credentials,
  };
}

class Backup {
  static final _cipher = AesGcm.with256bits();
  static Future<SecretKey> _key(String password, List<int> salt) {
    if (password.isEmpty ||
        utf8.encode(password).length > 4096 ||
        salt.length != 16) {
      throw const FormatException('备份口令或盐无效');
    }
    return Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: 600000,
      bits: 256,
    ).deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);
  }

  static Future<Uint8List> encrypt(Snapshot snapshot, String password) async {
    final plaintext = utf8.encode(jsonEncode(snapshot.toJson()));
    if (plaintext.length > 32 * 1024 * 1024) {
      throw const FormatException('备份超过 32 MiB');
    }
    final salt = SecretKeyData.random(length: 16).bytes;
    final box = await _cipher.encrypt(
      plaintext,
      secretKey: await _key(password, salt),
      aad: utf8.encode('QingzhouBackup-v1'),
    );
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'version': 1,
          'rounds': 600000,
          'salt': base64Encode(salt),
          'sealed': base64Encode([
            ...box.nonce,
            ...box.cipherText,
            ...box.mac.bytes,
          ]),
        }),
      ),
    );
  }

  static Future<Snapshot> decrypt(List<int> data, String password) async {
    if (data.length > 48 * 1024 * 1024) {
      throw const FormatException('备份超过 48 MiB');
    }
    try {
      final envelope = jsonDecode(utf8.decode(data)) as Json;
      if (envelope['version'] != 1 || envelope['rounds'] != 600000) {
        throw const FormatException();
      }
      final sealed = base64Decode(envelope['sealed'] as String);
      if (sealed.length < 28) throw const FormatException();
      final box = SecretBox(
        sealed.sublist(12, sealed.length - 16),
        nonce: sealed.sublist(0, 12),
        mac: Mac(sealed.sublist(sealed.length - 16)),
      );
      final plain = await _cipher.decrypt(
        box,
        secretKey: await _key(
          password,
          base64Decode(envelope['salt'] as String),
        ),
        aad: utf8.encode('QingzhouBackup-v1'),
      );
      if (plain.length > 32 * 1024 * 1024) throw const FormatException();
      final value = jsonDecode(utf8.decode(plain)) as Json;
      if (value['version'] != 1 ||
          (value['credentials'] as Map).length > 150000) {
        throw const FormatException();
      }
      return Snapshot(
        Catalog(value['catalog'] as Json),
        Map<String, String>.from(value['credentials'] as Map),
      );
    } catch (_) {
      throw const FormatException('备份口令错误、文件损坏或版本不支持');
    }
  }
}
