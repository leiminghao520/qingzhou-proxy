import 'dart:convert';
import 'dart:io';
import 'package:yaml/yaml.dart';
import 'catalog.dart';

class RemoteRules {
  static List<Json> parse(String text) {
    if (utf8.encode(text).length > 2 * 1024 * 1024) {
      throw const FormatException('规则源超过 2 MiB');
    }
    List<String> lines;
    if (text.trimLeft().startsWith('payload:')) {
      final root = loadYaml(text) as YamlMap;
      if (root.keys.any((key) => key != 'payload')) {
        throw const FormatException('规则源含不支持字段');
      }
      lines = (root['payload'] as YamlList).cast<String>();
    } else {
      lines = const LineSplitter().convert(text);
    }
    final rules = <Json>[];
    for (var line in lines) {
      line = line.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final parts = line.split(',').map((s) => s.trim()).toList();
      String kind, value;
      bool noResolve = false;
      if (parts.length == 1) {
        value = line;
        if (value.startsWith('+.')) {
          kind = 'suffix';
          value = value.substring(2);
        } else if (value.startsWith('.')) {
          kind = 'suffix';
          value = value.substring(1);
        } else if (value.contains('/')) {
          kind = 'cidr';
        } else {
          kind = 'domain';
        }
      } else {
        kind =
            {
              'DOMAIN': 'domain',
              'DOMAIN-SUFFIX': 'suffix',
              'DOMAIN-KEYWORD': 'keyword',
              'IP-CIDR': 'cidr',
              'IP-CIDR6': 'cidr',
            }[parts[0]] ??
            '';
        value = parts[1];
        if (kind.isEmpty ||
            parts.length > 3 ||
            (parts.length == 3 && parts.last != 'no-resolve')) {
          throw const FormatException('规则源类型或参数不支持');
        }
        noResolve = parts.length == 3;
      }
      if (kind == 'cidr') {
        final p = value.split('/');
        final ip = InternetAddress.tryParse(p[0]);
        final bits = p.length == 2 ? int.tryParse(p[1]) : null;
        if (ip == null ||
            p.length != 2 ||
            bits == null ||
            bits < 0 ||
            bits > (ip.type == InternetAddressType.IPv4 ? 32 : 128)) {
          throw const FormatException('规则源 CIDR 无效');
        }
      } else if (value.isEmpty ||
          value.length > 253 ||
          value.contains(RegExp(r'\s'))) {
        throw const FormatException('规则源匹配内容无效');
      }
      rules.add({
        'id': ids.v4().toUpperCase(),
        'kind': kind,
        'value': value,
        'noResolve': noResolve,
        'action': 'proxy',
      });
      if (rules.length > 50000) throw const FormatException('规则源超过 50000 条');
    }
    if (rules.isEmpty) throw const FormatException('规则源为空');
    return rules;
  }
}
