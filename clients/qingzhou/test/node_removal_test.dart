import 'package:flutter_test/flutter_test.dart';
import 'package:qingzhou/domain/catalog.dart';
import 'package:qingzhou/domain/importer.dart';
import 'package:qingzhou/domain/node_removal.dart';

void main() {
  test('批量删除清理递归空组与规则，保留其他配置和原始数据', () {
    final catalog = Catalog.empty();
    final a = Importer.node('trojan://first@example.com#甲');
    final b = Importer.node('trojan://second@example.org#乙');
    final aid = a.node['id'] as String, bid = b.node['id'] as String;
    final g1 = ids.v4().toUpperCase(),
        g2 = ids.v4().toUpperCase(),
        g3 = ids.v4().toUpperCase();
    catalog.state['nodes'] = [a.node, b.node];
    catalog.state['groups'] = [
      {
        'id': g2,
        'name': '上层',
        'kind': 'select',
        'members': [reference('group', g1)],
      },
      {
        'id': g1,
        'name': '子组',
        'kind': 'select',
        'members': [reference('node', aid)],
      },
      {
        'id': g3,
        'name': '保留',
        'kind': 'select',
        'members': [reference('node', aid), reference('node', bid)],
        'selected': reference('node', aid),
      },
    ];
    catalog.state['selectedID'] = aid;
    catalog.state['selectedPolicy'] = reference('group', g2);
    catalog.state['ruleFinal'] = reference('node', aid);
    catalog.state['rules'] = [
      {
        'kind': 'domain',
        'value': 'example.net',
        'target': reference('group', g2),
      },
      {'kind': 'suffix', 'value': 'example.org', 'target': reference('direct')},
    ];
    catalog.state['remoteRules'] = [
      {
        'id': ids.v4(),
        'sourceRef': ids.v4().toUpperCase(),
        'target': reference('node', aid),
        'rules': [],
      },
    ];
    catalog.state['favorites'] = [aid, bid];
    catalog.state['notes'] = {aid: '甲备注', bid: '乙备注'};
    catalog.state['recentUse'] = {aid: 100, bid: 200};
    final other = copyJson(catalog.profiles.single);
    other['id'] = ids.v4().toUpperCase();
    other['name'] = '保留配置';
    catalog.json['profiles'] = [...catalog.profiles, other];
    catalog.validate();
    final before = copyJson(catalog.json);
    final preview = previewNodeRemoval(catalog, {aid});
    expect(catalog.json, before);
    expect(preview.next.profiles.last, other);
    expect(preview.groups, 2);
    expect(preview.rules, 1);
    expect(preview.remoteSources, 1);
    expect(preview.selectionChanged, true);
    expect(preview.next.nodes.single['id'], bid);
    final group = (preview.next.state['groups'] as List).single;
    expect(group['id'], g3);
    expect(group['selected'], reference('node', bid));
    expect(preview.next.state['selectedPolicy'], isNull);
    expect(preview.next.state['ruleFinal'], reference('selected'));
    expect(preview.next.state['favorites'], [bid]);
    expect(preview.next.state['notes'], {bid: '乙备注'});
    expect(preview.next.state['recentUse'], {bid: 200});
    // 另一份配置仍使用该凭据，删除当前配置节点不能移除它。
    expect(preview.next.credentialRefs, contains(a.node['credentialRef']));
  });
  test('删除全部节点同时移除自动策略引用，直连规则继续保留', () {
    final c = Catalog.empty(), n = Importer.node('trojan://first@example.com');
    final nid = n.node['id'] as String;
    c.state['nodes'] = [n.node];
    c.state['selectedPolicy'] = reference('automatic');
    c.state['groups'] = [
      {
        'id': ids.v4(),
        'name': '自动组',
        'kind': 'select',
        'members': [reference('automatic')],
      },
    ];
    c.state['rules'] = [
      {
        'kind': 'domain',
        'value': 'example.net',
        'target': reference('automatic'),
      },
      {'kind': 'domain', 'value': 'example.org', 'target': reference('direct')},
    ];
    c.state['ruleFinal'] = reference('automatic');
    final p = previewNodeRemoval(c, {nid});
    expect(p.next.nodes, isEmpty);
    expect(p.groups, 1);
    expect(p.rules, 1);
    expect(p.next.state['selectedPolicy'], isNull);
    expect(p.next.runtime({})['selected'], {'kind': 'direct'});
  });
  test('选择已变化时不生成可应用的删除预览', () {
    expect(
      () => previewNodeRemoval(Catalog.empty(), {}),
      throwsFormatException,
    );
    expect(
      () => previewNodeRemoval(Catalog.empty(), {'missing'}),
      throwsFormatException,
    );
  });
}
