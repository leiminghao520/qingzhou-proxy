import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:yaml/yaml.dart';
import 'catalog.dart';

class Candidate {
  final Json node;
  final Map<String, String> credentials;
  Candidate(this.node, this.credentials);
}

class ImportResult {
  final List<Candidate> candidates;
  final List<Json> groups;
  final List<Json> rules;
  final Json? finalPolicy;
  final Json? shadowrocket;
  final String? revision;
  ImportResult(
    this.candidates, {
    this.groups = const [],
    this.rules = const [],
    this.finalPolicy,
    this.shadowrocket,
    this.revision,
  });
}

class Importer {
  static String decode64(String value) => utf8.decode(
    base64.decode(
      base64.normalize(value.replaceAll('-', '+').replaceAll('_', '/')),
    ),
  );
  static Candidate node(String input) {
    if (utf8.encode(input).length > 16384) {
      throw const FormatException('节点链接过长');
    }
    var raw = input.trim();
    if (raw.startsWith('ss://')) {
      final body = raw.substring(5).split('#').first;
      if (!body.contains('@')) {
        raw =
            'ss://${decode64(body)}${raw.contains('#') ? '#${raw.split('#').skip(1).join('#')}' : ''}';
      }
    }
    final uri = Uri.parse(raw);
    final kind = {
      'hy2': 'hysteria2',
      'hysteria2': 'hysteria2',
      'ss': 'shadowsocks',
      'trojan': 'trojan',
      'vless': 'vless',
    }[uri.scheme];
    if (kind == null ||
        uri.host.isEmpty ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw const FormatException('节点协议、地址或路径无效');
    }
    final port = uri.hasPort
        ? uri.port
        : ['hysteria2', 'trojan'].contains(kind)
        ? 443
        : 0;
    if (port < 1 || port > 65535 || uri.userInfo.isEmpty) {
      throw const FormatException('端口或认证信息无效');
    }
    final allowed = <String, Set<String>>{
      'hysteria2': {
        'sni',
        'peer',
        'insecure',
        'allowInsecure',
        'obfs',
        'obfs-password',
        'mport',
        'upmbps',
        'downmbps',
        'alpn',
      },
      'shadowsocks': {},
      'trojan': {
        'sni',
        'peer',
        'insecure',
        'allowInsecure',
        'security',
        'type',
        'alpn',
      },
      'vless': {
        'sni',
        'peer',
        'insecure',
        'allowInsecure',
        'security',
        'type',
        'path',
        'host',
        'flow',
        'pbk',
        'sid',
        'fp',
        'alpn',
        'encryption',
      },
    };
    final p = <String, String>{};
    String? obfs;
    final seen = <String>{};
    for (final entry in uri.queryParametersAll.entries) {
      final key = entry.key == 'peer'
          ? 'sni'
          : entry.key == 'allowInsecure'
          ? 'insecure'
          : entry.key;
      if (!allowed[kind]!.contains(entry.key) ||
          entry.value.length != 1 ||
          entry.value.single.isEmpty ||
          !seen.add(key)) {
        throw const FormatException('节点含未知、重复或空参数');
      }
      if (key == 'obfs-password') {
        obfs = entry.value.single;
      } else {
        p[key] = entry.value.single;
      }
    }
    if (p.containsKey('insecure')) {
      if (!['1', '0', 'true', 'false'].contains(p['insecure']!.toLowerCase())) {
        throw const FormatException('证书参数无效');
      }
      p['insecure'] = ['1', 'true'].contains(p['insecure']!.toLowerCase())
          ? '1'
          : '0';
    }
    var secret = Uri.decodeComponent(uri.userInfo);
    if (kind == 'shadowsocks') {
      final auth = secret.contains(':') ? secret : decode64(secret);
      final colon = auth.indexOf(':');
      if (colon < 1) throw const FormatException('SS 认证无效');
      p['method'] = auth.substring(0, colon);
      secret = auth.substring(colon + 1);
      if (![
        'aes-128-gcm',
        'aes-256-gcm',
        'chacha20-ietf-poly1305',
      ].contains(p['method'])) {
        throw const FormatException('SS 加密方式不支持');
      }
    }
    if (secret.isEmpty) throw const FormatException('凭据为空');
    if (kind == 'hysteria2' &&
        ((p['obfs'] != null) != (obfs != null) ||
            (p['obfs'] != null && p['obfs'] != 'salamander'))) {
      throw const FormatException('混淆参数无效');
    }
    final ref = ids.v4().toUpperCase();
    return Candidate(
      {
        'id': ids.v4().toUpperCase(),
        'name': uri.fragment.isEmpty
            ? uri.host
            : Uri.decodeComponent(uri.fragment),
        'kind': kind,
        'server': uri.host.replaceAll('[', '').replaceAll(']', ''),
        'port': port,
        'parameters': p,
        'credentialRef': ref,
      },
      {ref: secret, '$ref.obfs': ?obfs},
    );
  }

  static ImportResult parse(String input) {
    if (utf8.encode(input).length > 2 * 1024 * 1024) {
      throw const FormatException('导入超过 2 MiB');
    }
    var text = input.trim();
    if (text.startsWith('{')) {
      final envelope = jsonDecode(text) as Json;
      if (envelope['format'] != 'qingzhou.subscription' ||
          envelope['version'] != 1) {
        throw const FormatException('完整订阅格式或版本不支持');
      }
      final configuration = envelope['configurationJSON'] as String;
      if (utf8.encode(configuration).length > 1024 * 1024 ||
          sha256.convert(utf8.encode(configuration)).toString() !=
              envelope['revision']) {
        throw const FormatException('完整订阅摘要不匹配');
      }
      final shadow = jsonDecode(configuration) as Json;
      if (shadow['version'] != 1 || shadow['sourceMode'] != 'Config') {
        throw const FormatException('HTTP 高级配置版本或模式不支持');
      }
      final rows = (shadow['rules'] as List).cast<Json>();
      if (rows.isEmpty ||
          rows.length > 50000 ||
          rows.last['kind'] != 'FINAL' ||
          rows.where((r) => r['kind'] == 'FINAL').length != 1) {
        throw const FormatException('FINAL 规则必须唯一且位于末尾');
      }
      final rules = <Json>[];
      Json? finalPolicy;
      for (final r in rows) {
        final kind = {
          'DOMAIN': 'domain',
          'DOMAIN-SUFFIX': 'suffix',
          'DOMAIN-KEYWORD': 'keyword',
          'IP-CIDR': 'cidr',
          'IP-CIDR6': 'cidr',
          'GEOIP': 'geoip',
          'IP-ASN': 'asn',
          'USER-AGENT': 'userAgent',
          'FINAL': 'match',
        }[r['kind']];
        final target = {
          'DIRECT': reference('direct'),
          'PROXY': reference('selected'),
          'REJECT': reference('reject'),
        }[r['policy']];
        if (kind == null || target == null) {
          throw const FormatException('完整订阅存在不支持的规则或策略');
        }
        if (kind == 'match') {
          finalPolicy = target;
        } else {
          rules.add({
            'id': ids.v4().toUpperCase(),
            'kind': kind,
            'value': r['value'],
            'target': target,
            'action': 'proxy',
            'noResolve': r['noResolve'] == true,
          });
        }
      }
      final hosts = shadow['hosts'] as Map? ?? {};
      if (hosts.entries.any(
        (e) => e.key != 'localhost' || e.value != '127.0.0.1',
      )) {
        throw const FormatException('只支持 localhost 静态 Host');
      }
      final links = (envelope['nodes'] as List).cast<String>();
      if (links.isEmpty || links.length > 2000) {
        throw const FormatException('节点数量无效');
      }
      return ImportResult(
        links.map(node).toList(),
        rules: rules,
        finalPolicy: finalPolicy,
        shadowrocket: shadow,
        revision: envelope['revision'] as String,
      );
    }

    if (text.contains('proxies:')) return _yaml(text);
    if (!text.contains('://')) {
      text = decode64(text);
    }
    final lines = const LineSplitter()
        .convert(text)
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty && !s.startsWith('#'))
        .toList();
    if (lines.isEmpty || lines.length > 2000) {
      throw const FormatException('节点数量必须为 1–2000');
    }
    return ImportResult(lines.map(node).toList());
  }

  static ImportResult _yaml(String text) {
    final root = jsonDecode(jsonEncode(loadYaml(text))) as Json;
    const allowed = {
      'proxies',
      'proxy-groups',
      'rules',
      'mode',
      'port',
      'socks-port',
      'mixed-port',
      'allow-lan',
      'bind-address',
      'log-level',
      'external-controller',
      'secret',
      'dns',
      'tun',
      'ipv6',
      'unified-delay',
    };
    if (root.keys.any((k) => !allowed.contains(k))) {
      throw const FormatException('配置含脚本、提供器或其他不支持内容');
    }
    final candidates = <Candidate>[];
    final names = <String, Json>{
      'DIRECT': reference('direct'),
      'REJECT': reference('reject'),
    };
    for (final v in (root['proxies'] as List? ?? []).cast<Json>()) {
      final scheme = {
        'ss': 'ss',
        'trojan': 'trojan',
        'vless': 'vless',
        'hysteria2': 'hy2',
        'hy2': 'hy2',
      }[v['type']];
      if (scheme == null) throw const FormatException('YAML 节点协议不支持');
      const keys = {
        'name',
        'type',
        'server',
        'port',
        'password',
        'uuid',
        'cipher',
        'sni',
        'servername',
        'skip-cert-verify',
        'tls',
        'network',
        'ws-opts',
        'reality-opts',
        'client-fingerprint',
        'flow',
        'alpn',
        'obfs',
        'obfs-password',
        'up',
        'down',
        'udp',
      };
      if (v.keys.any((k) => !keys.contains(k))) {
        throw const FormatException('YAML 节点含未知参数');
      }
      final p = <String, String>{};
      for (final entry in {
        'sni': 'sni',
        'servername': 'sni',
        'flow': 'flow',
        'client-fingerprint': 'fp',
        'obfs': 'obfs',
        'obfs-password': 'obfs-password',
        'network': 'type',
      }.entries) {
        if (v[entry.key] != null) p[entry.value] = '${v[entry.key]}';
      }
      if (v['skip-cert-verify'] != null) {
        p['insecure'] = v['skip-cert-verify'] == true ? '1' : '0';
      }
      if (v['tls'] == true) p['security'] = 'tls';
      if (v['alpn'] != null) p['alpn'] = (v['alpn'] as List).join(',');
      if (v['ws-opts'] != null) {
        final ws = v['ws-opts'] as Json;
        if (ws.keys.any((k) => !['path', 'headers'].contains(k))) {
          throw const FormatException('WS 参数不支持');
        }
        p['type'] = 'ws';
        if (ws['path'] != null) p['path'] = '${ws['path']}';
        final headers = ws['headers'] as Json?;
        if (headers != null) {
          if (headers.keys.any((k) => k != 'Host')) {
            throw const FormatException('WS 头不支持');
          }
          if (headers['Host'] != null) p['host'] = '${headers['Host']}';
        }
      }
      if (v['reality-opts'] != null) {
        final reality = v['reality-opts'] as Json;
        if (reality.keys.any((k) => !['public-key', 'short-id'].contains(k))) {
          throw const FormatException('Reality 参数不支持');
        }
        p['security'] = 'reality';
        p['pbk'] = '${reality['public-key']}';
        if (reality['short-id'] != null) p['sid'] = '${reality['short-id']}';
      }
      for (final k in ['up', 'down']) {
        if (v[k] != null) {
          final value = '${v[k]}';
          if (!RegExp(r'^\d+$').hasMatch(value)) {
            throw const FormatException('HY2 带宽只接受整数 Mbps');
          }
          p[k == 'up' ? 'upmbps' : 'downmbps'] = value;
        }
      }
      final auth = scheme == 'ss'
          ? base64Encode(utf8.encode('${v['cipher']}:${v['password']}'))
          : '${v[scheme == 'vless' ? 'uuid' : 'password'] ?? ''}';
      final uri = Uri(
        scheme: scheme,
        userInfo: auth,
        host: '${v['server']}',
        port: v['port'] as int,
        queryParameters: p.isEmpty ? null : p,
        fragment: '${v['name']}',
      );
      final candidate = node(uri.toString());
      if (names.containsKey(candidate.node['name'])) {
        throw const FormatException('节点或策略名称重复');
      }
      names[candidate.node['name'] as String] = reference(
        'node',
        candidate.node['id'] as String,
      );
      candidates.add(candidate);
    }
    final rawGroups = (root['proxy-groups'] as List? ?? []).cast<Json>();
    for (final g in rawGroups) {
      final name = g['name'] as String;
      if (names.containsKey(name)) throw const FormatException('策略名称重复');
      names[name] = reference('group', ids.v4().toUpperCase());
    }
    final groups = <Json>[];
    for (final g in rawGroups) {
      if (g.keys.any(
        (k) => ![
          'name',
          'type',
          'proxies',
          'url',
          'interval',
          'tolerance',
          'lazy',
        ].contains(k),
      )) {
        throw const FormatException('策略组含不支持参数');
      }
      final kind = {
        'select': 'select',
        'url-test': 'urltest',
        'fallback': 'fallback',
      }[g['type']];
      if (kind == null) throw const FormatException('策略类型不支持');
      final members = (g['proxies'] as List).map((n) {
        if (!names.containsKey(n)) throw const FormatException('策略成员缺失');
        return names[n]!;
      }).toList();
      groups.add({
        'id': runtimeReference(names[g['name']])['id'],
        'name': g['name'],
        'kind': kind,
        'members': members,
      });
    }
    final rules = <Json>[];
    Json? finalPolicy;
    for (final line in root['rules'] as List? ?? []) {
      final parts = (line as String).split(',').map((s) => s.trim()).toList();
      final match = parts.first == 'MATCH';
      if (parts.length < (match ? 2 : 3) || parts.length > (match ? 2 : 4)) {
        throw const FormatException('规则格式无效');
      }
      final target = names[parts[match ? 1 : 2]];
      if (target == null) throw const FormatException('规则策略缺失');
      if (match) {
        finalPolicy = target;
        continue;
      }
      final kind = {
        'DOMAIN': 'domain',
        'DOMAIN-SUFFIX': 'suffix',
        'DOMAIN-KEYWORD': 'keyword',
        'IP-CIDR': 'cidr',
        'IP-CIDR6': 'cidr',
      }[parts.first];
      if (kind == null) throw const FormatException('规则类型不支持');
      if (parts.length == 4 && parts.last != 'no-resolve') {
        throw const FormatException('规则参数不支持');
      }
      rules.add({
        'id': ids.v4().toUpperCase(),
        'kind': kind,
        'value': parts[1],
        'target': target,
        'action': 'proxy',
        'noResolve': parts.length == 4,
      });
    }
    if (candidates.isEmpty ||
        candidates.length > 2000 ||
        rules.length > 50000) {
      throw const FormatException('配置数量无效');
    }
    return ImportResult(
      candidates,
      groups: groups,
      rules: rules,
      finalPolicy: finalPolicy,
    );
  }
}
