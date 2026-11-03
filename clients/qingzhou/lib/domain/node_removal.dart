import 'catalog.dart';

class NodeRemovalPreview {
  final Catalog next;
  final int nodes, groups, rules, remoteSources;
  final bool selectionChanged;
  NodeRemovalPreview(
    this.next,
    this.nodes,
    this.groups,
    this.rules,
    this.remoteSources,
    this.selectionChanged,
  );
}

NodeRemovalPreview previewNodeRemoval(Catalog catalog, Set<String> ids) {
  if (ids.isEmpty ||
      !ids.every((id) => catalog.nodes.any((n) => n['id'] == id))) {
    throw const FormatException('待删除线路已变化，请重新选择');
  }
  final next = Catalog(copyJson(catalog.json));
  final state = next.state;
  final removedGroups = <String>{};
  final noNodesRemain = catalog.nodes.every((n) => ids.contains(n['id']));
  bool removed(dynamic value) {
    if (value == null) return false;
    final ref = runtimeReference(value);
    return (ref['kind'] == 'automatic' && noNodesRemain) ||
        (ref['kind'] == 'node' && ids.contains(ref['id'])) ||
        (ref['kind'] == 'group' && removedGroups.contains(ref['id']));
  }

  final groups = (state['groups'] as List? ?? []).cast<Json>().toList();
  // 空策略组会使引用它的组也变空，按依赖逐轮清理直到稳定。
  var again = true;
  while (again) {
    again = false;
    for (final group in groups) {
      if (removedGroups.contains(group['id'])) continue;
      final members = (group['members'] as List)
          .where((m) => !removed(m))
          .toList();
      group['members'] = members;
      if (members.isEmpty) {
        removedGroups.add(group['id'] as String);
        again = true;
      } else if (removed(group['selected'])) {
        group['selected'] = members.first;
      }
    }
  }
  state['groups'] = groups
      .where((g) => !removedGroups.contains(g['id']))
      .toList();
  state['nodes'] = next.nodes.where((n) => !ids.contains(n['id'])).toList();
  final rules = state['rules'] as List? ?? [];
  final remote = state['remoteRules'] as List? ?? [];
  final nextRules = rules.where((r) => !removed(r['target'])).toList();
  final nextRemote = remote.where((r) => !removed(r['target'])).toList();
  state['rules'] = nextRules;
  state['remoteRules'] = nextRemote;
  final selectionChanged =
      ids.contains(state['selectedID']) || removed(state['selectedPolicy']);
  if (ids.contains(state['selectedID'])) state.remove('selectedID');
  if (removed(state['selectedPolicy'])) state.remove('selectedPolicy');
  if (removed(state['ruleFinal'])) state['ruleFinal'] = reference('selected');
  state['favorites'] = (state['favorites'] as List? ?? [])
      .where((id) => !ids.contains(id))
      .toList();
  for (final key in ['notes', 'recentUse']) {
    if (state[key] is Map) {
      (state[key] as Map).removeWhere((id, _) => ids.contains(id));
    }
  }
  next.validate();
  return NodeRemovalPreview(
    next,
    ids.length,
    removedGroups.length,
    rules.length - nextRules.length,
    remote.length - nextRemote.length,
    selectionChanged,
  );
}
