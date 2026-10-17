import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingzhou/app_model.dart';
import 'package:qingzhou/domain/backup.dart';
import 'package:qingzhou/domain/catalog.dart';
import 'package:qingzhou/domain/importer.dart';
import 'package:qingzhou/platform/repository.dart';
import 'package:qingzhou/platform/runtime.dart';

class MemoryRepository implements Repository {
  Snapshot? value;
  bool fail = false;
  @override
  Future<Snapshot?> load() async => value;
  @override
  Future<void> save(Snapshot snapshot) async {
    if (fail) throw StateError('disk');
    value = snapshot;
  }

  @override
  Future<Json> preferences() async => {};
  @override
  Future<void> savePreferences(Json preferences) async {}
}

class FakeRuntime implements Runtime {
  bool running = false, failNextStart = false;
  final events = <String>[];
  int statusCalls = 0, queryCalls = 0;
  @override
  Future<Json> capabilities() async => {
    'captureModes': ['tun'],
  };
  @override
  Future<void> validate(Json request) async {
    events.add('validate');
  }

  @override
  Future<void> start(Json request) async {
    events.add('start');
    if (failNextStart) {
      failNextStart = false;
      throw StateError('failed');
    }
    running = true;
  }

  @override
  Future<void> stop() async {
    events.add('stop');
    running = false;
  }

  @override
  Future<void> recover() async {
    running = false;
  }

  @override
  Future<Json> status() async {
    statusCalls++;
    return {'state': running ? 'connected' : 'disconnected'};
  }

  @override
  Future<Json> query(String path) async {
    queryCalls++;
    return {};
  }

  @override
  Future<int> probe(Json request) async => 10;
  @override
  Future<int> delay(String tag) async => 10;
  @override
  Future<void> select(String target) async {}
}

void main() {
  test('确认框等待期间继续发送心跳且不污染事务状态', () async {
    final runtime = FakeRuntime();
    final m = AppModel(runtime, MemoryRepository());
    await m.initialize();
    runtime.running = true;
    m.status = {'state': 'connecting'};
    final waiting = Completer<void>();
    final operation = m.action(() => waiting.future);
    final before = runtime.statusCalls;
    await m.poll();
    expect(runtime.statusCalls, before + 1);
    expect(runtime.queryCalls, 0);
    expect(m.status['state'], 'connecting');
    waiting.complete();
    await operation;
    await m.poll();
    expect(m.connected, true);
    expect(runtime.queryCalls, 1);
    m.dispose();
  });
  test('连接中切换失败恢复旧配置且不提交', () async {
    final runtime = FakeRuntime(), repo = MemoryRepository();
    final m = AppModel(runtime, repo);
    await m.initialize();
    runtime.running = true;
    m.status = {'state': 'connected'};
    final before = copyJson(m.catalog.json);
    runtime.failNextStart = true;
    await expectLater(
      m.change((c) => c.state['mode'] = 'global'),
      throwsStateError,
    );
    expect(m.catalog.json, before);
    expect(repo.value, isNull);
    expect(runtime.running, true);
    expect(runtime.events, ['validate', 'stop', 'start', 'start']);
    m.dispose();
  });
  test('保存失败恢复运行状态', () async {
    final runtime = FakeRuntime(), repo = MemoryRepository();
    final m = AppModel(runtime, repo);
    await m.initialize();
    runtime.running = true;
    m.status = {'state': 'connected'};
    repo.fail = true;
    await expectLater(
      m.change((c) => c.state['mode'] = 'global'),
      throwsStateError,
    );
    expect(m.catalog.state['mode'], 'rule');
    expect(runtime.running, true);
    m.dispose();
  });
  test('更新保留节点 ID 并显式预览证书降级', () async {
    final runtime = FakeRuntime(), repo = MemoryRepository();
    final m = AppModel(runtime, repo);
    await m.initialize();
    await m.applyImport(
      m.preview(Importer.parse('trojan://test@example.com#旧名')),
      source: 'https://example.com/sub',
    );
    final id = m.catalog.nodes.single['id'];
    final sid = m.catalog.state['subscriptions'][0]['id'] as String;
    final preview = m.preview(
      Importer.parse('trojan://test@example.com?insecure=1#新名'),
      subscriptionID: sid,
    );
    expect(preview.securityReduced, true);
    expect(preview.changed, 1);
    expect(preview.removed, 0);
    await m.applyImport(preview);
    expect(m.catalog.nodes.single['id'], id);
    expect(m.catalog.nodes.single['name'], '新名');
    expect(m.credentials.values, contains('https://example.com/sub'));
    m.dispose();
  });
  test('首次不安全导入、仅最终策略更新及稳定策略组 ID', () async {
    final m = AppModel(FakeRuntime(), MemoryRepository());
    await m.initialize();
    expect(
      m
          .preview(Importer.parse('trojan://test@example.com?insecure=1'))
          .securityReduced,
      true,
    );
    const profile = '''proxies:
  - {name: 测试线路, type: trojan, server: example.com, port: 443, password: test}
proxy-groups:
  - {name: 选择线路, type: select, proxies: [测试线路, DIRECT]}
rules:
  - MATCH,选择线路
''';
    await m.applyImport(
      m.preview(Importer.parse(profile)),
      source: 'https://example.com/sub',
    );
    final sid = m.catalog.state['subscriptions'][0]['id'] as String;
    final gid = (m.catalog.state['groups'] as List).single['id'];
    await m.applyImport(
      m.preview(Importer.parse(profile), subscriptionID: sid),
    );
    expect((m.catalog.state['groups'] as List).single['id'], gid);
    expect(m.catalog.state['subscriptions'][0]['scope'], 'profile');
    await m.applyImport(
      m.preview(ImportResult([], finalPolicy: reference('direct'))),
    );
    expect(m.catalog.state['groups'], isEmpty);
    expect(referenceLabel(m.catalog.state['ruleFinal']), 'direct');
    m.dispose();
  });
  test('离线测速不启动 VPN 且仅保存测速元数据', () async {
    final runtime = FakeRuntime(), repo = MemoryRepository();
    final m = AppModel(runtime, repo);
    await m.initialize();
    await m.applyImport(m.preview(Importer.parse('trojan://test@example.com')));
    expect(await m.measure(m.catalog.nodes.single), 10);
    expect(runtime.events, isEmpty);
    expect(runtime.running, false);
    expect(m.catalog.state['latency'], isNotEmpty);
    m.dispose();
  });
}
