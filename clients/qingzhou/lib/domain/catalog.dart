import 'dart:convert';
import 'package:uuid/uuid.dart';

const ids = Uuid();
typedef Json = Map<String, dynamic>;
Json copyJson(Json value) => jsonDecode(jsonEncode(value)) as Json;
Json reference(String kind, [String? id]) => {
  kind: id == null ? <String, dynamic>{} : {'_0': id},
};
Json runtimeReference(dynamic value) {
  final map = Map<String, dynamic>.from(value as Map);
  if (map.length != 1) throw const FormatException('策略引用无效');
  final kind = map.keys.single;
  return {
    'kind': kind,
    if (kind == 'node' || kind == 'group') 'id': (map[kind] as Map)['_0'],
  };
}

String referenceLabel(dynamic value) =>
    runtimeReference(value)['kind'] as String;

class Catalog {
  final Json json;
  Catalog(this.json) {
    validate();
  }
  factory Catalog.empty({bool mobile = true}) {
    final id = ids.v4().toUpperCase();
    return Catalog({
      'schemaVersion': 3,
      'currentProfileID': id,
      'backupIndex': <dynamic>[],
      'profiles': [
        {'id': id, 'name': '默认配置', 'configuration': emptyState(mobile: mobile)},
      ],
    });
  }
  static Json emptyState({bool mobile = true}) => {
    'schemaVersion': 2,
    'nodes': <dynamic>[],
    'groups': <dynamic>[],
    'rules': <dynamic>[],
    'subscriptions': <dynamic>[],
    'remoteRules': <dynamic>[],
    'favorites': <dynamic>[],
    'notes': <String, dynamic>{},
    'recentUse': <String, dynamic>{},
    'latency': <String, dynamic>{},
    'mode': 'rule',
    'listenPort': 7890,
    'captureMode': mobile ? 'tun' : 'systemProxy',
    'dnsPreference': 'httpsProxy',
    'autoConnect': false,
    'loginAtStartup': false,
    'httpCompatibilityEnabled': false,
    'protectedDomains': <dynamic>[],
    'tunExcludedCIDRs': <dynamic>[],
  };
  List<Json> get profiles => (json['profiles'] as List).cast<Json>();
  Json get state =>
      profiles.firstWhere(
            (p) => p['id'] == json['currentProfileID'],
          )['configuration']
          as Json;
  List<Json> get nodes => (state['nodes'] as List? ?? []).cast<Json>();
  Set<String> get credentialRefs {
    final result = <String>{};
    for (final profile in profiles) {
      final s = profile['configuration'] as Json;
      for (final n in s['nodes'] as List? ?? []) {
        result.add(n['credentialRef'] as String);
        if ((n['parameters'] as Map?)?['obfs'] != null) {
          result.add('${n['credentialRef']}.obfs');
        }
      }
      for (final source in [
        ...s['subscriptions'] as List? ?? [],
        ...s['remoteRules'] as List? ?? [],
      ]) {
        result.add(source['sourceRef'] as String);
      }
    }
    return result;
  }

  void validate() {
    if (json['schemaVersion'] != 3 ||
        profiles.isEmpty ||
        profiles.length > 30 ||
        profiles.map((p) => p['id']).toSet().length != profiles.length ||
        !profiles.any((p) => p['id'] == json['currentProfileID'])) {
      throw const FormatException('配置集合版本或内容无效');
    }
    for (final p in profiles) {
      if (p['name'] is! String ||
          (p['name'] as String).trim().isEmpty ||
          (p['name'] as String).length > 100 ||
          p['configuration'] is! Map ||
          p['configuration']['schemaVersion'] != 2) {
        throw const FormatException('配置名称或版本无效');
      }
      final s = p['configuration'] as Json;
      final ns = s['nodes'] as List? ?? [];
      if (ns.length > 2000 ||
          ns.map((n) => n['id']).toSet().length != ns.length ||
          (s['rules'] as List? ?? []).length > 50000) {
        throw const FormatException('配置数量或节点标识无效');
      }
    }
    for (final profile in profiles) {
      final s = profile['configuration'] as Json;
      final nodes = (s['nodes'] as List? ?? []).cast<Json>();
      final groups = (s['groups'] as List? ?? []).cast<Json>();
      if (groups.length > 2000 ||
          groups.map((g) => g['id']).toSet().length != groups.length) {
        throw const FormatException('策略组标识或数量无效');
      }
      bool exists(dynamic value) {
        final r = runtimeReference(value);
        return switch (r['kind']) {
          'node' => nodes.any((n) => n['id'] == r['id']),
          'group' => groups.any((g) => g['id'] == r['id']),
          'automatic' => nodes.isNotEmpty,
          'selected' || 'direct' || 'reject' => true,
          _ => false,
        };
      }

      final visiting = <String>{}, finished = <String>{};
      void visit(Json group) {
        final id = group['id'] as String;
        if (finished.contains(id)) return;
        if (!visiting.add(id)) throw const FormatException('策略组存在循环');
        final members = group['members'] as List;
        if (members.isEmpty) throw const FormatException('策略组不能为空');
        for (final member in members) {
          if (!exists(member) ||
              ['selected', 'reject'].contains(referenceLabel(member))) {
            throw const FormatException('策略组引用失效');
          }
          if (group['kind'] == 'fallback' && referenceLabel(member) != 'node') {
            throw const FormatException('优先回退仅接受节点');
          }
          if (referenceLabel(member) == 'group') {
            visit(
              groups.firstWhere(
                (g) => g['id'] == runtimeReference(member)['id'],
              ),
            );
          }
        }
        if (group['selected'] != null &&
            !members.any(
              (v) => jsonEncode(v) == jsonEncode(group['selected']),
            )) {
          throw const FormatException('策略组选择不在成员内');
        }
        visiting.remove(id);
        finished.add(id);
      }

      for (final g in groups) {
        visit(g);
      }
      for (final r in (s['rules'] as List? ?? []).cast<Json>()) {
        if (r['target'] != null && !exists(r['target'])) {
          throw const FormatException('规则引用失效');
        }
      }
      for (final r in (s['remoteRules'] as List? ?? []).cast<Json>()) {
        if (!exists(r['target'])) throw const FormatException('远程规则引用失效');
      }
      final current =
          s['selectedPolicy'] ??
          (s['selectedID'] != null
              ? reference('node', s['selectedID'] as String)
              : null);
      if (current != null &&
          (!exists(current) ||
              ['selected', 'reject'].contains(referenceLabel(current)))) {
        throw const FormatException('当前选择失效');
      }
      if (s['ruleFinal'] != null && !exists(s['ruleFinal'])) {
        throw const FormatException('最终策略失效');
      }
    }
    if (credentialRefs.length > 150000) {
      throw const FormatException('凭据数量过多');
    }
  }

  Json runtime(Map<String, String> credentials, {String? capture}) {
    final s = state;
    if ((s['protectedDomains'] as List? ?? []).isNotEmpty ||
        (s['tunExcludedCIDRs'] as List? ?? []).isNotEmpty) {
      throw const FormatException('此配置含尚未适配的企业保护或自定义绕行配置，请复制配置后调整');
    }
    final rules = <Json>[];
    Json render(Json r, [dynamic override]) => {
      'kind': r['kind'],
      'value': r['value'],
      'noResolve': r['noResolve'] == true,
      'target': runtimeReference(
        override ??
            r['target'] ??
            reference(
              r['action'] == 'proxy' ? 'selected' : r['action'] as String,
            ),
      ),
    };
    for (final r in (s['rules'] as List? ?? []).cast<Json>()) {
      rules.add(render(r));
    }
    for (final source in (s['remoteRules'] as List? ?? []).cast<Json>()) {
      for (final r in (source['rules'] as List? ?? []).cast<Json>()) {
        rules.add(render(r, source['target']));
      }
    }
    return {
      'nodes': nodes
          .map(
            (n) => {
              for (final k in [
                'id',
                'name',
                'kind',
                'server',
                'port',
                'parameters',
                'credentialRef',
              ])
                k: n[k],
            },
          )
          .toList(),
      'groups': (s['groups'] as List? ?? [])
          .map(
            (g) => {
              'id': g['id'],
              'name': g['name'],
              'kind': g['kind'],
              'members': (g['members'] as List).map(runtimeReference).toList(),
              if (g['selected'] != null)
                'selected': runtimeReference(g['selected']),
            },
          )
          .toList(),
      'rules': rules,
      'selected': runtimeReference(
        s['selectedPolicy'] ??
            (s['selectedID'] != null
                ? reference('node', s['selectedID'] as String)
                : reference(nodes.isEmpty ? 'direct' : 'automatic')),
      ),
      'final': runtimeReference(s['ruleFinal'] ?? reference('selected')),
      'mode': s['mode'] ?? 'rule',
      'capture': capture ?? s['captureMode'] ?? 'tun',
      'dns': s['dnsPreference'] ?? 'httpsProxy',
      'ipv6':
          s['addressFamilyPolicy'] != null &&
          s['addressFamilyPolicy'] != 'ipv4Only',
      'port': s['listenPort'] ?? 7890,
      'credentials': {
        for (final n in nodes)
          n['credentialRef'] as String: credentials[n['credentialRef']] ?? '',
        for (final n in nodes.where(
          (n) => (n['parameters'] as Map?)?['obfs'] != null,
        ))
          '${n['credentialRef']}.obfs':
              credentials['${n['credentialRef']}.obfs'] ?? '',
      },
      'httpCompatibility': s['httpCompatibilityEnabled'] == true,
      if (s['shadowrocket'] != null)
        'compatibility': {
          'rewrites': s['shadowrocket']['rewrites'] ?? [],
          'assets': s['shadowrocket']['assets'] ?? {},
          'general': s['shadowrocket']['general'] ?? {},
        },
    };
  }
}
