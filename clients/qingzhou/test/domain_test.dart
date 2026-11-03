import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingzhou/domain/backup.dart';
import 'package:qingzhou/domain/catalog.dart';
import 'package:qingzhou/domain/importer.dart';

void main() {
  test('分享链接导入与重复参数拒绝', () {
    final c = Importer.node(
      'trojan://test-password@example.com:443?sni=edge.example.com#测试',
    );
    expect(c.node['kind'], 'trojan');
    expect(c.node['name'], '测试');
    expect(c.credentials.values.single, 'test-password');
    for (final text in [
      'trojan://x@example.com?sni=a&peer=b',
      'ss://YWVzLTI1Ni1nY206cA@example.com:443?plugin=evil',
      'trojan://x@example.com?insecure=maybe',
    ]) {
      expect(() => Importer.node(text), throwsFormatException);
    }
  });
  test('SS 两种编码及 Base64 订阅', () {
    for (final auth in [
      '${base64Encode(utf8.encode('aes-256-gcm:test-secret'))}@example.com:443',
      base64Encode(utf8.encode('aes-256-gcm:test-secret@example.com:443')),
    ]) {
      final node = Importer.node('ss://$auth');
      expect(node.credentials.values.single, 'test-secret');
      expect(node.node['parameters']['method'], 'aes-256-gcm');
    }
    expect(
      Importer.parse(
        base64Encode(utf8.encode('hy2://password@example.com')),
      ).candidates.length,
      1,
    );
  });
  test('YAML 策略与规则引用', () {
    final result = Importer.parse('''proxies:
  - {name: 测试线路, type: trojan, server: example.com, port: 443, password: test}
proxy-groups:
  - {name: 选择线路, type: select, proxies: [测试线路, DIRECT]}
rules:
  - DOMAIN-SUFFIX,example.org,DIRECT
  - MATCH,选择线路
''');
    expect(result.candidates.length, 1);
    expect(result.groups.length, 1);
    expect(result.rules.single['kind'], 'suffix');
    expect(referenceLabel(result.finalPolicy), 'group');
    expect(
      () => Importer.parse('proxies: []\nscript: evil'),
      throwsFormatException,
    );
  });
  test('Swift 枚举结构与运行请求转换', () {
    final c = Catalog.empty();
    final n = Importer.node('trojan://p@example.com');
    c.state['nodes'] = [n.node];
    c.state['selectedPolicy'] = reference('node', n.node['id'] as String);
    final r = c.runtime(n.credentials);
    expect(r['selected'], {'kind': 'node', 'id': n.node['id']});
    expect((r['nodes'] as List).single.containsKey('secret'), false);
  });
  test('备份加密、错误口令、篡改与凭据完整性', () async {
    final c = Catalog.empty();
    final n = Importer.node('hy2://only-test@example.com');
    c.state['nodes'] = [n.node];
    final snapshot = Snapshot(c, n.credentials);
    final bytes = await Backup.encrypt(snapshot, '测试口令');
    expect(utf8.decode(bytes).contains('only-test'), false);
    final restored = await Backup.decrypt(bytes, '测试口令');
    expect(restored.credentials, n.credentials);
    expect(restored.catalog.json, c.json);
    await expectLater(Backup.decrypt(bytes, '错误口令'), throwsFormatException);
    final envelope = jsonDecode(utf8.decode(bytes)) as Json;
    final sealed = base64Decode(envelope['sealed'] as String);
    sealed[13] ^= 1;
    envelope['sealed'] = base64Encode(sealed);
    await expectLater(
      Backup.decrypt(utf8.encode(jsonEncode(envelope)), '测试口令'),
      throwsFormatException,
    );
    expect(() => Snapshot(c, {}), throwsFormatException);
  });
  test('读取 Swift 生成的 AES-GCM 备份', () async {
    final file = File('test/fixtures/swift-backup.qzb.json');
    final snapshot = await Backup.decrypt(
      await file.readAsBytes(),
      'fixture-password',
    );
    expect(snapshot.catalog.profiles.single['name'], 'Swift 测试配置');
    expect(snapshot.credentials, isEmpty);
  });
}
