import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'domain/backup.dart';
import 'domain/catalog.dart';
import 'domain/importer.dart';
import 'domain/subscription.dart';
import 'domain/remote_rules.dart';
import 'platform/repository.dart';
import 'platform/runtime.dart';

class ImportPreview {
  final ImportResult result;
  final String? subscriptionID;
  final int added, removed, changed;
  final bool securityReduced, currentRemoved;
  ImportPreview(
    this.result,
    this.subscriptionID,
    this.added,
    this.removed,
    this.changed,
    this.securityReduced,
    this.currentRemoved,
  );
}

class AppModel extends ChangeNotifier {
  final Runtime runtime;
  final Repository repository;
  Catalog catalog;
  Map<String, String> credentials = {};
  Json preferences = {};
  Json capabilities = {};
  Json status = {'state': 'disconnected'};
  Json? connections;
  final List<String> logs = [];
  final List<Json> samples = [];
  bool busy = false, ready = false;
  String? error;
  Timer? _timer;
  bool _polling = false;
  bool _disposed = false;
  DateTime? _lastSchedule;
  AppModel(this.runtime, this.repository, {Catalog? initial})
    : catalog = initial ?? Catalog.empty(mobile: !Platform.isWindows);
  bool get connected => status['state'] == 'connected';
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    try {
      final value = await repository.load();
      if (value != null) {
        catalog = value.catalog;
        credentials = value.credentials;
      }
      preferences = await repository.preferences();
      ready = true;
      try {
        capabilities = await runtime.capabilities();
        status = await runtime.status();
      } catch (_) {
        error = '平台运行组件尚未就绪，请检查核心与服务安装';
      }
      _timer = Timer.periodic(const Duration(seconds: 2), (_) => poll());
    } catch (_) {
      error = '本地数据无法读取；为保留原数据，已禁止覆盖，请检查安全存储或恢复备份';
    }
    _notify();
  }

  Future<void> action(
    Future<void> Function() operation, {
    bool allowRecovery = false,
  }) async {
    if (busy || (!ready && !allowRecovery)) return;
    busy = true;
    error = null;
    _notify();
    try {
      await operation();
    } catch (e) {
      error = e is FormatException ? e.message : '操作失败，请查看脱敏诊断';
      logs.add(redact(error!, credentials.values));
      if (logs.length > 500) logs.removeAt(0);
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> commit(Catalog next, Map<String, String> secrets) async {
    next.validate();
    secrets = Map.of(secrets)
      ..removeWhere((key, _) => !next.credentialRefs.contains(key));
    final wasConnected = connected;
    final previous = catalog;
    final oldSecrets = credentials;
    if (wasConnected) {
      await runtime.validate(next.runtime(secrets));
      await runtime.stop();
      try {
        await runtime.start(next.runtime(secrets));
      } catch (_) {
        try {
          await runtime.start(previous.runtime(oldSecrets));
        } catch (_) {
          status = {'state': 'error'};
        }
        rethrow;
      }
    }
    try {
      await repository.save(Snapshot(next, secrets));
    } catch (_) {
      if (wasConnected) {
        await runtime.stop();
        try {
          await runtime.start(previous.runtime(oldSecrets));
        } catch (_) {
          status = {'state': 'error'};
        }
      }
      rethrow;
    }
    catalog = next;
    credentials = secrets;
    connections = null;
    samples.clear();
  }

  Future<void> change(void Function(Catalog) edit) async {
    final next = Catalog(copyJson(catalog.json));
    edit(next);
    await commit(next, Map.of(credentials));
  }

  Future<void> toggle() async {
    if (connected) {
      await runtime.stop();
      status = {'state': 'disconnected'};
      samples.clear();
      connections = null;
    } else {
      final request = catalog.runtime(credentials);
      await runtime.validate(request);
      await runtime.start(request);
      status = await runtime.status();
    }
  }

  Future<void> recover() async {
    await runtime.recover();
    status = await runtime.status();
  }

  Future<void> poll() async {
    if (_polling || !ready) return;
    _polling = true;
    try {
      final latest = await runtime.status();
      // 操作或确认框打开期间仍发送心跳，避免服务误判界面退出。
      if (busy) return;
      status = latest;
      if (connected) {
        connections = await runtime.query('/connections');
        samples.add({
          'at': DateTime.now().millisecondsSinceEpoch,
          'upload': connections?['uploadTotal'],
          'download': connections?['downloadTotal'],
        });
        while (samples.length > 900) {
          samples.removeAt(0);
        }
      } else {
        connections = null;
        samples.clear();
      }
    } catch (_) {
      if (!busy) {
        connections = null;
        status = {'state': 'unavailable'};
      }
    } finally {
      _polling = false;
      _notify();
    }
    if (!_disposed &&
        (_lastSchedule == null ||
            DateTime.now().difference(_lastSchedule!) >=
                const Duration(minutes: 1))) {
      _lastSchedule = DateTime.now();
      await scheduledUpdates();
    }
  }

  String _identity(Json n) =>
      '${n['kind']}|${(n['server'] as String).toLowerCase()}|${n['port']}';
  ImportPreview preview(ImportResult result, {String? subscriptionID}) {
    final old = subscriptionID == null
        ? <Json>[]
        : catalog.nodes
              .where((n) => n['subscriptionID'] == subscriptionID)
              .toList();
    final incoming = result.candidates.map((c) => _identity(c.node)).toSet();
    final oldIDs = old.map(_identity).toSet();
    var changed = 0;
    var reduced = false;
    for (final c in result.candidates) {
      final matches = old
          .where((n) => _identity(n) == _identity(c.node))
          .toList();
      if (matches.isEmpty && (c.node['parameters'] as Map)['insecure'] == '1') {
        reduced = true;
      }
      if (matches.length == 1) {
        final n = matches.single;
        if (n['parameters'].toString() != c.node['parameters'].toString() ||
            n['name'] != c.node['name'] ||
            credentials[n['credentialRef']] !=
                c.credentials[c.node['credentialRef']] ||
            credentials['${n['credentialRef']}.obfs'] !=
                c.credentials['${c.node['credentialRef']}.obfs']) {
          changed++;
        }
        if ((n['parameters'] as Map?)?['insecure'] != '1' &&
            (c.node['parameters'] as Map)['insecure'] == '1') {
          reduced = true;
        }
      }
    }
    final removed = old.where((n) => !incoming.contains(_identity(n))).toList();
    return ImportPreview(
      result,
      subscriptionID,
      incoming.difference(oldIDs).length,
      removed.length,
      changed,
      reduced,
      removed.any((n) => n['id'] == catalog.state['selectedID']),
    );
  }

  Future<void> applyImport(
    ImportPreview preview, {
    String? source,
    String? sourceName,
  }) async {
    final next = Catalog(copyJson(catalog.json));
    final secrets = Map<String, String>.of(credentials);
    final state = next.state;
    final subID =
        preview.subscriptionID ??
        (source != null ? ids.v4().toUpperCase() : null);
    final old = subID == null
        ? <Json>[]
        : next.nodes.where((n) => n['subscriptionID'] == subID).toList();
    final result = <Json>[];
    final remap = <String, String>{};
    final claimed = <String>{};
    for (final candidate in preview.result.candidates) {
      final n = copyJson(candidate.node);
      final matches = old.where((v) => _identity(v) == _identity(n)).toList();
      if (matches.length == 1 && claimed.add(matches.single['id'] as String)) {
        remap[n['id'] as String] = matches.single['id'] as String;
        n['id'] = matches.single['id'];
        final candidateRef = n['credentialRef'] as String;
        final previousRef = matches.single['credentialRef'] as String;
        n['credentialRef'] = previousRef;
        secrets[previousRef] = candidate.credentials[candidateRef]!;
        if (candidate.credentials['$candidateRef.obfs'] != null) {
          secrets['$previousRef.obfs'] =
              candidate.credentials['$candidateRef.obfs']!;
        }
      }
      if (subID != null) n['subscriptionID'] = subID;
      result.add(n);
      secrets.addAll(candidate.credentials);
    }
    state['nodes'] = [
      ...next.nodes.where((n) => subID == null || n['subscriptionID'] != subID),
      ...result,
    ];
    final groupRemap = <String, String>{};
    for (final group in preview.result.groups) {
      final matches = (state['groups'] as List? ?? [])
          .where(
            (old) =>
                old['name'] == group['name'] && old['kind'] == group['kind'],
          )
          .toList();
      if (matches.length == 1) {
        groupRemap[group['id'] as String] = matches.single['id'] as String;
      }
    }
    dynamic mapReferences(dynamic v) {
      if (v is Map) {
        if (v.length == 1 && v.containsKey('node')) {
          final id = (v['node'] as Map)['_0'];
          if (remap.containsKey(id)) return reference('node', remap[id]);
        }
        if (v.length == 1 && v.containsKey('group')) {
          final id = (v['group'] as Map)['_0'];
          if (groupRemap.containsKey(id)) {
            return reference('group', groupRemap[id]);
          }
        }
        return <String, dynamic>{
          for (final entry in v.entries)
            entry.key as String: mapReferences(entry.value),
        };
      }
      if (v is List) return v.map(mapReferences).toList();
      return v;
    }

    if (preview.result.shadowrocket != null) {
      state['shadowrocket'] = copyJson(preview.result.shadowrocket!);
      state['httpCompatibilityEnabled'] = false;
    }
    final replacesProfile =
        preview.result.groups.isNotEmpty ||
        preview.result.rules.isNotEmpty ||
        preview.result.finalPolicy != null ||
        preview.result.shadowrocket != null;
    if (replacesProfile) {
      state['groups'] = mapReferences(
        preview.result.groups
            .map(
              (group) => {
                ...group,
                'id': groupRemap[group['id']] ?? group['id'],
              },
            )
            .toList(),
      );
      state['rules'] = mapReferences(preview.result.rules);
      if (preview.result.finalPolicy != null) {
        state['ruleFinal'] = mapReferences(preview.result.finalPolicy);
      }
    }
    if (subID != null) {
      final subs = (state['subscriptions'] as List? ?? []).cast<Json>();
      final index = subs.indexWhere((s) => s['id'] == subID);
      final ref = index < 0
          ? ids.v4().toUpperCase()
          : subs[index]['sourceRef'] as String;
      if (source != null) secrets[ref] = source;
      final entry = {
        'id': subID,
        'name': sourceName ?? (index < 0 ? '订阅' : subs[index]['name']),
        'sourceRef': ref,
        'updatedAt': DateTime.now().millisecondsSinceEpoch / 1000 - 978307200,
        'autoUpdate': true,
        'scope': replacesProfile ? 'profile' : 'nodes',
        'pendingReview': false,
        'retryCount': 0,
        if (preview.result.revision != null)
          'revision': preview.result.revision,
      };
      if (index < 0) {
        subs.add(entry);
      } else {
        subs[index] = entry;
      }
      state['subscriptions'] = subs;
    }
    final existing = (state['nodes'] as List).map((n) => n['id']).toSet();
    if (!existing.contains(state['selectedID'])) {
      state.remove('selectedID');
      if (state['selectedPolicy'] != null &&
          referenceLabel(state['selectedPolicy']) == 'node') {
        state.remove('selectedPolicy');
      }
    }
    state['favorites'] = (state['favorites'] as List? ?? [])
        .where(existing.contains)
        .toList();
    final used = next.credentialRefs;
    secrets.removeWhere((key, _) => !used.contains(key));
    await commit(next, secrets);
  }

  Future<void> restore(Snapshot snapshot) async {
    final next = Catalog(copyJson(snapshot.catalog.json));
    for (final p in next.profiles) {
      p['configuration']['autoConnect'] = false;
      p['configuration']['loginAtStartup'] = false;
    }
    await commit(next, snapshot.credentials);
    ready = true;
  }

  Future<void> setPreference(String key, dynamic value) async {
    final next = {...preferences, key: value};
    await repository.savePreferences(next);
    preferences = next;
    _notify();
  }

  Future<ImportPreview> fetchSubscription(Json subscription) async {
    final address = credentials[subscription['sourceRef']];
    if (address == null) throw const FormatException('订阅地址凭据缺失');
    final text = await SubscriptionFetcher().fetch(address);
    return preview(
      Importer.parse(text),
      subscriptionID: subscription['id'] as String,
    );
  }

  Future<int> measure(Json node) async {
    final tag = 'node-${(node['id'] as String).toLowerCase()}';
    int ms;
    if (connected) {
      ms = await runtime.delay(tag);
    } else {
      final request = catalog.runtime(credentials);
      request['nodes'] = [
        {
          for (final k in [
            'id',
            'name',
            'kind',
            'server',
            'port',
            'parameters',
            'credentialRef',
          ])
            k: node[k],
        },
      ];
      request['groups'] = <dynamic>[];
      request['rules'] = <dynamic>[];
      request['selected'] = {'kind': 'node', 'id': node['id']};
      request['final'] = {'kind': 'selected'};
      request['httpCompatibility'] = false;
      request.remove('compatibility');
      ms = await runtime.probe(request);
    }
    final parameters = Map<String, String>.from(node['parameters'] as Map);
    final keys = parameters.keys.toList()..sort();
    final text =
        "${node['kind']}|${(node['server'] as String).toLowerCase()}|${node['port']}|${keys.map((k) => '$k=${parameters[k]}').join('&')}";
    final key = sha256.convert(utf8.encode(text)).toString();
    await metadata((c) {
      c.state['latency'] = {
        ...c.state['latency'] as Map? ?? {},
        key: {
          'milliseconds': ms,
          'testedAt': DateTime.now().millisecondsSinceEpoch / 1000 - 978307200,
        },
      };
    });
    return ms;
  }

  Future<void> metadata(void Function(Catalog) edit) async {
    final next = Catalog(copyJson(catalog.json));
    edit(next);
    next.validate();
    await repository.save(Snapshot(next, credentials));
    catalog = next;
  }

  Future<void> scheduledUpdates() async {
    if (busy || !ready || _disposed) return;
    final now = DateTime.now().millisecondsSinceEpoch / 1000 - 978307200;
    for (final kind in ['subscriptions', 'remoteRules']) {
      for (final source
          in (catalog.state[kind] as List? ?? []).cast<Json>().toList()) {
        if (source['autoUpdate'] != true || source['pendingReview'] == true) {
          continue;
        }
        final retry = source['retryCount'] as int? ?? 0;
        if (retry > 0) {
          if (source['retryAfter'] == null ||
              (source['retryAfter'] as num) > now) {
            continue;
          }
        } else if (source['updatedAt'] != null &&
            now - (source['updatedAt'] as num) < 86400) {
          continue;
        }
        await action(() async {
          try {
            final address = credentials[source['sourceRef']];
            if (address == null) throw const FormatException('更新地址凭据缺失');
            final text = await SubscriptionFetcher().fetch(address);
            if (kind == 'subscriptions') {
              final p = preview(
                Importer.parse(text),
                subscriptionID: source['id'] as String,
              );
              if (p.securityReduced ||
                  p.currentRemoved ||
                  p.result.groups.isNotEmpty ||
                  p.result.rules.isNotEmpty ||
                  p.result.finalPolicy != null ||
                  p.result.shadowrocket != null) {
                await metadata((c) {
                  final s = (c.state[kind] as List).firstWhere(
                    (v) => v['id'] == source['id'],
                  );
                  s['pendingReview'] = true;
                });
                return;
              }
              if (p.added == 0 && p.removed == 0 && p.changed == 0) {
                await metadata((c) {
                  final s = (c.state[kind] as List).firstWhere(
                    (v) => v['id'] == source['id'],
                  );
                  s['updatedAt'] = now;
                  s['retryCount'] = 0;
                  s.remove('retryAfter');
                  s.remove('lastError');
                });
              } else {
                await applyImport(p);
              }
            } else {
              final rules = RemoteRules.parse(text);
              await change((c) {
                final s = (c.state[kind] as List).firstWhere(
                  (v) => v['id'] == source['id'],
                );
                s['rules'] = rules;
                s['updatedAt'] = now;
                s['retryCount'] = 0;
                s.remove('retryAfter');
                s.remove('lastError');
              });
            }
          } catch (_) {
            await metadata((c) {
              final s = (c.state[kind] as List).firstWhere(
                (v) => v['id'] == source['id'],
              );
              final count = retry + 1;
              s['retryCount'] = count;
              s['lastError'] = '更新失败，已保留旧数据';
              if (count <= 3) {
                s['retryAfter'] = now + [60, 300, 1800][count - 1];
              } else {
                s.remove('retryAfter');
              }
            });
          }
        });
      }
    }
  }

  Future<void> addRemoteRules(String url, List<Json> rules) async {
    final next = Catalog(copyJson(catalog.json));
    final ref = ids.v4().toUpperCase();
    final secrets = Map<String, String>.of(credentials)..[ref] = url;
    next.state['remoteRules'] = [
      ...next.state['remoteRules'] as List? ?? [],
      {
        'id': ids.v4().toUpperCase(),
        'name': '远程规则',
        'sourceRef': ref,
        'target': reference('selected'),
        'rules': rules,
        'autoUpdate': true,
        'updatedAt': DateTime.now().millisecondsSinceEpoch / 1000 - 978307200,
      },
    ];
    await commit(next, secrets);
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
