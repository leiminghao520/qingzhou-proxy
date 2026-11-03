import 'dart:convert';
import 'package:flutter/material.dart';
import 'domain/catalog.dart';

Map<String, ({String name, Json value})> policyChoices(
  Catalog catalog, {
  String? excluding,
}) {
  final choices = <({String name, Json value})>[
    (name: '当前选择', value: reference('selected')),
    (name: '直连', value: reference('direct')),
    (name: '拒绝', value: reference('reject')),
    if (catalog.nodes.isNotEmpty) (name: '自动选择', value: reference('automatic')),
    ...catalog.nodes.map(
      (n) => (
        name: n['name'] as String,
        value: reference('node', n['id'] as String),
      ),
    ),
    ...(catalog.state['groups'] as List? ?? [])
        .cast<Json>()
        .where((g) => g['id'] != excluding)
        .map(
          (g) => (
            name: g['name'] as String,
            value: reference('group', g['id'] as String),
          ),
        ),
  ];
  return {for (final c in choices) jsonEncode(c.value): c};
}

Future<Json?> showRuleEditor(
  BuildContext context,
  Catalog catalog, {
  Json? initial,
}) async {
  final choices = policyChoices(catalog);
  final value = TextEditingController(text: initial?['value'] as String? ?? '');
  var kind = initial?['kind'] as String? ?? 'suffix';
  var target = jsonEncode(
    initial?['target'] ??
        reference(
          initial?['action'] == 'direct'
              ? 'direct'
              : initial?['action'] == 'reject'
              ? 'reject'
              : 'selected',
        ),
  );
  var noResolve = initial?['noResolve'] == true;
  final result = await showDialog<Json>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(initial == null ? '添加分流规则' : '编辑分流规则'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: kind,
                  decoration: const InputDecoration(labelText: '匹配方式'),
                  items: const [
                    DropdownMenuItem(value: 'domain', child: Text('完整域名')),
                    DropdownMenuItem(value: 'suffix', child: Text('域名后缀')),
                    DropdownMenuItem(value: 'keyword', child: Text('域名关键词')),
                    DropdownMenuItem(value: 'cidr', child: Text('IP / CIDR')),
                    DropdownMenuItem(value: 'match', child: Text('所有后续流量')),
                  ],
                  onChanged: (v) => setState(() => kind = v!),
                ),
                if (kind != 'match')
                  TextField(
                    controller: value,
                    decoration: const InputDecoration(
                      labelText: '匹配内容',
                      hintText: '例如 example.com 或 10.0.0.0/8',
                    ),
                  ),
                DropdownButtonFormField<String>(
                  initialValue: choices.containsKey(target) ? target : null,
                  decoration: const InputDecoration(labelText: '处理策略'),
                  items: choices.entries
                      .map(
                        (e) => DropdownMenuItem(
                          value: e.key,
                          child: Text(e.value.name),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => setState(() => target = v!),
                ),
                if (kind == 'cidr')
                  SwitchListTile(
                    title: const Text('不主动解析域名'),
                    value: noResolve,
                    onChanged: (v) => setState(() => noResolve = v),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (kind != 'match' && value.text.trim().isEmpty) return;
              Navigator.pop(context, {
                'id': initial?['id'] ?? ids.v4().toUpperCase(),
                'kind': kind,
                'value': kind == 'match' ? '' : value.text.trim(),
                'target': jsonDecode(target),
                'action': 'proxy',
                'noResolve': noResolve,
              });
            },
            child: const Text('保存'),
          ),
        ],
      ),
    ),
  );
  Future<void>.delayed(const Duration(milliseconds: 400), value.dispose);
  return result;
}

Future<Json?> showGroupEditor(
  BuildContext context,
  Catalog catalog, {
  Json? initial,
}) async {
  final name = TextEditingController(text: initial?['name'] as String? ?? '');
  var kind = initial?['kind'] as String? ?? 'select';
  final members = (initial?['members'] as List? ?? [])
      .map((v) => copyJson(v as Json))
      .toList();
  final choices = policyChoices(catalog, excluding: initial?['id'] as String?)
    ..removeWhere(
      (_, v) => ['selected', 'reject'].contains(referenceLabel(v.value)),
    );
  String? adding;
  String? error;
  final result = await showDialog<Json>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final allowed = choices.entries
            .where(
              (e) =>
                  kind != 'fallback' || referenceLabel(e.value.value) == 'node',
            )
            .toList();
        return AlertDialog(
          title: Text(initial == null ? '新建策略组' : '编辑策略组'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: name,
                    decoration: const InputDecoration(labelText: '策略组名称'),
                  ),
                  DropdownButtonFormField<String>(
                    initialValue: kind,
                    items: const [
                      DropdownMenuItem(value: 'select', child: Text('手动选择')),
                      DropdownMenuItem(value: 'urltest', child: Text('自动测速')),
                      DropdownMenuItem(value: 'fallback', child: Text('优先回退')),
                    ],
                    onChanged: (v) => setState(() {
                      kind = v!;
                      adding = null;
                    }),
                  ),
                  const SizedBox(height: 12),
                  const Text('拖动调整优先顺序；优先回退仅接受节点。'),
                  ReorderableListView(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    onReorderItem: (a, b) => setState(() {
                      members.insert(b, members.removeAt(a));
                    }),
                    children: members.asMap().entries.map((e) {
                      final key = jsonEncode(e.value);
                      return ListTile(
                        key: ValueKey('${e.key}-$key'),
                        title: Text(choices[key]?.name ?? '已失效成员'),
                        trailing: IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () =>
                              setState(() => members.removeAt(e.key)),
                        ),
                      );
                    }).toList(),
                  ),
                  DropdownButtonFormField<String>(
                    key: ValueKey(kind),
                    initialValue: adding,
                    decoration: const InputDecoration(labelText: '添加成员'),
                    items: allowed
                        .map(
                          (e) => DropdownMenuItem(
                            value: e.key,
                            child: Text(e.value.name),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setState(() => adding = v),
                  ),
                  TextButton(
                    onPressed: adding == null
                        ? null
                        : () => setState(() {
                            if (!members.any((m) => jsonEncode(m) == adding)) {
                              members.add(copyJson(choices[adding]!.value));
                            }
                          }),
                    child: const Text('添加到组'),
                  ),
                  if (error != null)
                    Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                if (name.text.trim().isEmpty ||
                    members.isEmpty ||
                    (kind == 'fallback' &&
                        members.any((m) => referenceLabel(m) != 'node'))) {
                  setState(() => error = '请填写名称，添加成员，并检查回退组仅包含节点');
                  return;
                }
                Navigator.pop(context, {
                  'id': initial?['id'] ?? ids.v4().toUpperCase(),
                  'name': name.text.trim(),
                  'kind': kind,
                  'members': members,
                });
              },
              child: const Text('保存'),
            ),
          ],
        );
      },
    ),
  );
  Future<void>.delayed(const Duration(milliseconds: 400), name.dispose);
  return result;
}
