import 'dart:convert';
import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'app_model.dart';
import 'editors.dart';
import 'domain/backup.dart';
import 'domain/catalog.dart';
import 'domain/importer.dart';
import 'domain/subscription.dart';
import 'domain/remote_rules.dart';
import 'domain/qr_import.dart';
import 'domain/node_removal.dart';
import 'package:flutter/foundation.dart';
import 'platform/repository.dart';
import 'platform/runtime.dart';
import 'platform/desktop.dart';
import 'ui/client_theme.dart';
import 'ui/client_shell.dart';
import 'ui/connection_dashboard.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final model = AppModel(NativeRuntime(), SecureRepository());
  if (Platform.isWindows) {
    await DesktopController(model).initialize();
  }
  runApp(QingzhouApp(model: model));
  await model.initialize();
}

class QingzhouApp extends StatelessWidget {
  final AppModel model;
  const QingzhouApp({super.key, required this.model});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) => MaterialApp(
      title: '轻舟代理',
      debugShowCheckedModeBanner: false,
      theme: clientTheme(Brightness.light),
      darkTheme: clientTheme(Brightness.dark),
      themeMode:
          {
            'light': ThemeMode.light,
            'dark': ThemeMode.dark,
          }[model.preferences['appearance']] ??
          ThemeMode.system,
      home: Home(model: model),
    ),
  );
}

class Home extends StatefulWidget {
  final AppModel model;
  const Home({super.key, required this.model});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  AppModel get m => widget.model;
  int page = 0;
  String search = '';
  bool selectingNodes = false;
  final selectedNodes = <String>{};
  bool get professional => m.preferences['professional'] == true;
  List<String> get pages => professional
      ? ['连接', '线路', '订阅', '策略', '规则', '监控', '配置', '设置']
      : ['连接', '线路', '订阅', '设置'];
  Future<void> run(Future<void> Function() f) => m.action(f);
  Future<void> changeInterfaceMode(bool value) async {
    final previousPage = pages[page.clamp(0, pages.length - 1)];
    await run(() async {
      await m.setPreference('professional', value);
      if (!mounted) return;
      // 依据页面名称恢复位置；简洁模式中不存在的专业页面回到连接页。
      setState(() {
        final next = pages.indexOf(previousPage);
        page = next < 0 ? 0 : next;
      });
    });
  }

  Future<String?> textDialog(
    String title, {
    String initial = '',
    bool secret = false,
    int lines = 1,
  }) async {
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: controller,
            obscureText: secret,
            maxLines: secret ? 1 : lines,
            autofocus: true,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    // 对话框退出动画结束后释放输入资源。
    Future<void>.delayed(const Duration(milliseconds: 400), controller.dispose);
    return result;
  }

  Future<bool> confirm(String title, String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认'),
            ),
          ],
        ),
      ) ??
      false;
  Future<void> previewImport(
    ImportResult result, {
    String? source,
    String? subscriptionID,
  }) async {
    final p = m.preview(result, subscriptionID: subscriptionID);
    if (await confirm(
      '导入预览',
      '新增 ${p.added}，移除 ${p.removed}，变更 ${p.changed}\n策略组 ${result.groups.length}，规则 ${result.rules.length}${result.groups.isNotEmpty || result.rules.isNotEmpty || result.finalPolicy != null || result.shadowrocket != null ? '\n将替换当前配置的策略组、规则及导入的最终策略' : ''}${p.securityReduced ? '\n警告：包含跳过证书验证的新增节点或证书验证降级' : ''}${p.currentRemoved ? '\n当前线路将被移除' : ''}\n应用后会保存配置；已连接时需要重连。',
    )) {
      await m.applyImport(p, source: source);
    }
  }

  Future<void> importText() async {
    final input = await textDialog('粘贴节点、订阅地址或 YAML', lines: 8);
    if (input == null || input.trim().isEmpty) return;
    await run(() async {
      final source = input.trim();
      if (source.startsWith('https://') && !source.contains('\n')) {
        await previewImport(
          Importer.parse(await SubscriptionFetcher().fetch(source)),
          source: source,
        );
      } else {
        await previewImport(Importer.parse(source));
      }
    });
  }

  Future<void> importFile() async {
    final file = await openFile();
    if (file == null) return;
    await run(() async {
      if (await file.length() > 2 * 1024 * 1024) {
        throw const FormatException('导入超过 2 MiB');
      }
      if (RegExp(
        r'\.(png|jpe?g|webp|gif)$',
        caseSensitive: false,
      ).hasMatch(file.name)) {
        final links = await compute(QrImport.decode, await file.readAsBytes());
        await previewImport(Importer.parse(links.join('\n')));
      } else {
        await previewImport(Importer.parse(await file.readAsString()));
      }
    });
  }

  Widget card(String title, List<Widget> children) => Card(
    margin: const EdgeInsets.only(bottom: 16),
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    ),
  );
  Widget connectPage() {
    final state = m.status['state'];
    final label =
        {
          'connected': '已连接',
          'connecting': '正在连接',
          'disconnected': '未连接',
          'error': '连接异常',
          'unavailable': '运行状态不可用',
          'recoveryRequired': '需要恢复网络',
        }[state] ??
        '$state';
    final policy = m.catalog.state['selectedPolicy'];
    final selectedPolicy = policy == null
        ? const <String, dynamic>{}
        : runtimeReference(policy);
    final selectedID = selectedPolicy['kind'] == 'node'
        ? selectedPolicy['id']
        : m.catalog.state['selectedID'];
    final selected = m.catalog.nodes.where((n) => n['id'] == selectedID).firstOrNull;
    final group = (m.catalog.state['groups'] as List? ?? [])
        .where((g) => g['id'] == selectedPolicy['id']).firstOrNull;
    String nodeName = selected?['name']?.toString() ??
        (m.catalog.nodes.isEmpty ? '尚未添加线路' : '自动选择线路');
    if (selectedPolicy['kind'] == 'direct' || m.catalog.state['mode'] == 'direct') {
      nodeName = '直接连接';
    } else if (selectedPolicy['kind'] == 'group') {
      nodeName = group?['name']?.toString() ?? '策略组';
    }
    return ConnectionDashboard(
      connected: m.connected,
      stateLabel: label,
      nodeName: nodeName,
      captureLabel: const {'tun': 'VPN / TUN', 'systemProxy': '系统代理', 'compatible': '组合接管'}[m.catalog.state['captureMode']] ?? '未设置',
      proxyMode: m.catalog.state['mode'] as String? ?? 'rule',
      coreVersion: m.capabilities['coreVersion'] as String? ?? '未就绪',
      nodeCount: m.catalog.nodes.length,
      onToggle: m.busy || !m.ready ? null : () => run(m.toggle),
      onImport: m.busy ? null : importText,
      onFile: m.busy ? null : importFile,
      onRecover: m.busy ? null : () => run(m.recover),
      onModeChanged: m.busy ? null : (value) => run(() => m.change((c) => c.state['mode'] = value)),
      notificationsDisabled: m.status['notificationsEnabled'] == false,
    );
  }

  Widget nodesPage() {
    final nodes = m.catalog.nodes
        .where(
          (n) => '${n['name']} ${n['server']}'.toLowerCase().contains(
            search.toLowerCase(),
          ),
        )
        .toList();
    final favorites = (m.catalog.state['favorites'] as List? ?? []);
    return Column(
      children: [
        card('线路', [
          TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: '搜索名称或服务器',
            ),
            onChanged: (v) => setState(() => search = v),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                onPressed: m.busy ? null : importText,
                child: const Text('添加'),
              ),
              OutlinedButton(
                onPressed: m.busy ? null : importFile,
                child: const Text('导入文件'),
              ),
              OutlinedButton(
                onPressed: m.busy
                    ? null
                    : () => setState(() {
                        selectingNodes = !selectingNodes;
                        selectedNodes.clear();
                      }),
                child: Text(selectingNodes ? '取消选择' : '批量管理'),
              ),
              if (selectingNodes) ...[
                TextButton(
                  onPressed: m.busy
                      ? null
                      : () => setState(() {
                          selectedNodes.addAll(
                            nodes.map((n) => n['id'] as String),
                          );
                        }),
                  child: const Text('选择筛选结果'),
                ),
                TextButton(
                  onPressed: m.busy || selectedNodes.isEmpty
                      ? null
                      : () => run(
                          () => m.metadata((c) {
                            c.state['favorites'] = {
                              ...c.state['favorites'] as List? ?? [],
                              ...selectedNodes,
                            }.toList();
                          }),
                        ),
                  child: const Text('收藏已选'),
                ),
                TextButton(
                  onPressed: m.busy || selectedNodes.isEmpty
                      ? null
                      : () => deleteNodes(Set.of(selectedNodes)),
                  child: Text('删除已选（${selectedNodes.length}）'),
                ),
              ],
            ],
          ),
        ]),
        if (nodes.isEmpty) card('暂无线路', [const Text('添加订阅、节点链接或配置文件后即可连接。')]),
        ...nodes.map(
          (n) => Card(
            child: ListTile(
              leading: selectingNodes
                  ? Checkbox(
                      value: selectedNodes.contains(n['id']),
                      onChanged: m.busy
                          ? null
                          : (_) => toggleNodeSelection(n['id'] as String),
                    )
                  : IconButton(
                      onPressed: m.busy
                          ? null
                          : () => run(
                              () => m.metadata((c) {
                                final f = (c.state['favorites'] as List? ?? []);
                                f.contains(n['id'])
                                    ? f.remove(n['id'])
                                    : f.add(n['id']);
                                c.state['favorites'] = f;
                              }),
                            ),
                      icon: Icon(
                        favorites.contains(n['id'])
                            ? Icons.star
                            : Icons.star_outline,
                      ),
                    ),
              title: Text(n['name'] as String),
              subtitle: Text(
                '${n['kind']} · ${n['server']}:${n['port']}${(n['parameters'] as Map?)?['insecure'] == '1' ? ' · 未验证证书' : ''}',
              ),
              selected: n['id'] == m.catalog.state['selectedID'],
              onTap: m.busy
                  ? null
                  : selectingNodes
                  ? () => toggleNodeSelection(n['id'] as String)
                  : () => run(
                      () => m.change((c) {
                        c.state['selectedID'] = n['id'];
                        c.state['selectedPolicy'] = reference(
                          'node',
                          n['id'] as String,
                        );
                        c.state['recentUse'] = {
                          ...c.state['recentUse'] as Map? ?? {},
                          n['id']:
                              DateTime.now().millisecondsSinceEpoch / 1000 -
                              978307200,
                        };
                      }),
                    ),
              trailing: PopupMenuButton<String>(
                onSelected: (action) async {
                  if (action == 'delay') {
                    await run(() async {
                      final ms = await m.measure(n);
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('${n['name']}：$ms ms HTTPS 延迟'),
                          ),
                        );
                      }
                    });
                  }
                  if (action == 'share') {
                    await shareNode(n);
                  }
                  if (action == 'note') {
                    final note = await textDialog(
                      '线路备注',
                      initial:
                          (m.catalog.state['notes'] as Map?)?[n['id']]
                              as String? ??
                          '',
                    );
                    if (note != null) {
                      await run(
                        () => m.metadata((c) {
                          c.state['notes'] = {
                            ...c.state['notes'] as Map? ?? {},
                            n['id']: note,
                          };
                        }),
                      );
                    }
                  }
                  if (action == 'delete') {
                    await deleteNodes({n['id'] as String});
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'note', child: Text('备注')),
                  PopupMenuItem(value: 'share', child: Text('分享链接 / 二维码')),
                  PopupMenuItem(value: 'delay', child: Text('HTTPS 延迟测速')),
                  PopupMenuItem(value: 'delete', child: Text('删除')),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  void toggleNodeSelection(String id) => setState(() {
    if (!selectedNodes.remove(id)) selectedNodes.add(id);
  });

  Future<void> deleteNodes(Set<String> ids) => run(() async {
    final preview = previewNodeRemoval(m.catalog, ids);
    if (!await confirm(
      '删除线路预览',
      '删除 ${preview.nodes} 条线路并清理策略组成员引用；移除 ${preview.groups} 个空策略组、${preview.rules} 条引用规则和 ${preview.remoteSources} 个引用规则源。${preview.selectionChanged ? '\n当前线路或策略将调整。' : ''}\n已连接时将重连，失败会回滚。确认删除？',
    )) {
      return;
    }
    await m.commit(preview.next, Map.of(m.credentials));
    if (mounted) {
      setState(() {
        selectedNodes.clear();
        selectingNodes = false;
      });
    }
  });

  Future<void> shareNode(Json n) async {
    if (!await confirm('分享含凭据', '链接及二维码包含此节点的认证信息。确认生成？')) return;
    final p = Map<String, String>.from(n['parameters'] as Map);
    var auth = m.credentials[n['credentialRef']]!;
    final kind = n['kind'] as String;
    if (kind == 'shadowsocks') {
      auth = base64Encode(utf8.encode('${p.remove('method')}:$auth'));
    }
    if (p['obfs'] != null) {
      p['obfs-password'] = m.credentials['${n['credentialRef']}.obfs']!;
    }
    final link = Uri(
      scheme: kind == 'shadowsocks' ? 'ss' : kind,
      userInfo: auth,
      host: n['server'] as String,
      port: n['port'] as int,
      queryParameters: p.isEmpty ? null : p,
      fragment: n['name'] as String,
    ).toString();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('节点分享'),
        content: SizedBox(
          width: 300,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              QrImageView(data: link, size: 260, backgroundColor: Colors.white),
              const Text('仅分享给可信任的人。'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: link)),
            child: const Text('复制链接'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Widget subscriptionsPage() => Column(
    children: [
      card('订阅', [
        const Text('地址保存在加密快照中；更新先显示差异，确认后应用。'),
        FilledButton(
          onPressed: m.busy ? null : importText,
          child: const Text('添加订阅'),
        ),
      ]),
      ...(m.catalog.state['subscriptions'] as List? ?? []).cast<Json>().map(
        (s) => Card(
          child: ListTile(
            title: Text(s['name'] as String),
            subtitle: Text(
              s['pendingReview'] == true ? '更新待确认' : '已保存 HTTPS 订阅',
            ),
            trailing: IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: m.busy
                  ? null
                  : () => run(() async {
                      final p = await m.fetchSubscription(s);
                      await previewImport(
                        p.result,
                        subscriptionID: s['id'] as String,
                      );
                    }),
            ),
          ),
        ),
      ),
    ],
  );
  Future<void> editRule([Json? initial]) async {
    final rule = await showRuleEditor(context, m.catalog, initial: initial);
    if (rule == null) return;
    await run(
      () => m.change((c) {
        final rules = (c.state['rules'] as List? ?? []);
        final index = rules.indexWhere((r) => r['id'] == rule['id']);
        if (index < 0) {
          rules.add(rule);
        } else {
          rules[index] = rule;
        }
        c.state['rules'] = rules;
      }),
    );
  }

  Future<void> editGroup([Json? initial]) async {
    final group = await showGroupEditor(context, m.catalog, initial: initial);
    if (group == null) return;
    await run(
      () => m.change((c) {
        final groups = (c.state['groups'] as List? ?? []);
        final index = groups.indexWhere((g) => g['id'] == group['id']);
        if (index < 0) {
          groups.add(group);
        } else {
          groups[index] = group;
        }
        c.state['groups'] = groups;
      }),
    );
  }

  Future<void> addRemoteRules() async {
    final url = await textDialog('HTTPS 远程规则地址');
    if (url == null) return;
    await run(() async {
      final rules = RemoteRules.parse(await SubscriptionFetcher().fetch(url));
      if (await confirm(
        '规则源预览',
        '导入 ${rules.length} 条规则，默认指向当前选择，排列在用户规则之后。',
      )) {
        await m.addRemoteRules(url, rules);
      }
    });
  }

  Widget rulesPage() => Column(
    children: [
      card('分流规则', [
        const Text('按显示顺序匹配，支持域名、后缀、关键词、IP/CIDR 与最终策略。'),
        TextButton(
          onPressed: m.busy ? null : () => editRule(),
          child: const Text('编辑规则'),
        ),
      ]),
      ...(m.catalog.state['rules'] as List? ?? []).cast<Json>().map(
        (r) => Card(
          child: ListTile(
            title: Text('${r['kind']} · ${r['value']}'),
            onTap: m.busy ? null : () => editRule(r),
            trailing: PopupMenuButton<String>(
              onSelected: (v) => run(
                () => m.change((c) {
                  final rules = c.state['rules'] as List;
                  final index = rules.indexWhere((e) => e['id'] == r['id']);
                  if (v == 'delete') {
                    rules.removeAt(index);
                  } else {
                    final to = v == 'up' ? index - 1 : index + 1;
                    if (to >= 0 && to < rules.length) {
                      rules.insert(to, rules.removeAt(index));
                    }
                  }
                }),
              ),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'up', child: Text('上移')),
                PopupMenuItem(value: 'down', child: Text('下移')),
                PopupMenuItem(value: 'delete', child: Text('删除')),
              ],
            ),
            subtitle: Text(
              referenceLabel(
                r['target'] ??
                    reference(
                      r['action'] == 'proxy'
                          ? 'selected'
                          : r['action'] as String,
                    ),
              ),
            ),
          ),
        ),
      ),
    ],
  );
  Widget groupsPage() => Column(
    children: [
      card('策略组', [
        const Text('支持手动选择、自动测速和优先回退；拖动成员可调整回退优先级。'),
        TextButton(
          onPressed: m.busy ? null : () => editGroup(),
          child: const Text('编辑策略组'),
        ),
      ]),
      ...(m.catalog.state['groups'] as List? ?? []).cast<Json>().map(
        (g) => Card(
          child: ListTile(
            title: Text(g['name'] as String),
            trailing: IconButton(
              icon: const Icon(Icons.edit_outlined),
              onPressed: m.busy ? null : () => editGroup(g),
            ),
            subtitle: Text(
              '${g['kind']} · ${(g['members'] as List).length} 个成员',
            ),
            onTap: m.busy
                ? null
                : () => run(
                    () => m.change(
                      (c) => c.state['selectedPolicy'] = reference(
                        'group',
                        g['id'] as String,
                      ),
                    ),
                  ),
          ),
        ),
      ),
    ],
  );
  Widget monitorPage() => Column(
    children: [
      card('连接观测', [
        Text(
          m.connections == null
              ? '监控不可用'
              : '上传 ${m.connections!['uploadTotal']} B · 下载 ${m.connections!['downloadTotal']} B',
        ),
        const Text('仅展示核心返回的字段，重连后清零。'),
        Text('保留 ${m.samples.length} 个观测样本'),
      ]),
      ...(m.connections?['connections'] as List? ?? [])
          .take(100)
          .map(
            (c) => Card(
              child: ListTile(
                title: Text(
                  '${c['metadata']?['host'] ?? c['metadata']?['destinationIP'] ?? '未知目标'}',
                ),
                subtitle: Text(
                  '${c['metadata']?['network'] ?? ''} · ↑${c['upload'] ?? 0} ↓${c['download'] ?? 0}',
                ),
              ),
            ),
          ),
    ],
  );
  Widget profilesPage() => Column(
    children: [
      card('配置管理', [
        FilledButton(
          onPressed: m.busy
              ? null
              : () async {
                  final name = await textDialog('新配置名称');
                  if (name == null) return;
                  await run(
                    () => m.change((c) {
                      c.profiles.add({
                        'id': ids.v4().toUpperCase(),
                        'name': name,
                        'configuration': Catalog.emptyState(
                          mobile: !Platform.isWindows,
                        ),
                      });
                    }),
                  );
                },
          child: const Text('新建配置'),
        ),
        OutlinedButton(
          onPressed: m.busy
              ? null
              : () async {
                  final name = await textDialog('复制配置名称');
                  if (name == null) return;
                  await run(
                    () => m.change((c) {
                      c.profiles.add({
                        'id': ids.v4().toUpperCase(),
                        'name': name,
                        'configuration': copyJson(c.state),
                      });
                    }),
                  );
                },
          child: const Text('复制当前配置'),
        ),
      ]),
      ...m.catalog.profiles.map(
        (p) => Card(
          child: ListTile(
            title: Text(p['name'] as String),
            selected: p['id'] == m.catalog.json['currentProfileID'],
            onTap: m.busy
                ? null
                : () => run(
                    () => m.change((c) => c.json['currentProfileID'] = p['id']),
                  ),
            trailing: PopupMenuButton<String>(
              onSelected: (value) async {
                if (value == 'rename') {
                  final name = await textDialog(
                    '配置名称',
                    initial: p['name'] as String,
                  );
                  if (name != null) {
                    await run(
                      () => m.change(
                        (c) => c.profiles.firstWhere(
                          (v) => v['id'] == p['id'],
                        )['name'] = name,
                      ),
                    );
                  }
                } else if (p['id'] != m.catalog.json['currentProfileID'] &&
                    await confirm('删除配置', '确认删除此配置？')) {
                  await run(
                    () => m.change(
                      (c) => c.profiles.removeWhere((v) => v['id'] == p['id']),
                    ),
                  );
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'rename', child: Text('改名')),
                if (p['id'] != m.catalog.json['currentProfileID'])
                  const PopupMenuItem(value: 'delete', child: Text('删除')),
              ],
            ),
          ),
        ),
      ),
    ],
  );
  Future<void> exportBackup() async {
    final password = await textDialog('设置备份口令', secret: true);
    if (password == null) return;
    await run(() async {
      final bytes = await Backup.encrypt(
        Snapshot(m.catalog, m.credentials),
        password,
      );
      await saveBytes(
        bytes,
        'qingzhou-${DateTime.now().millisecondsSinceEpoch}.qzb',
      );
    });
  }

  Future<void> saveBytes(Uint8List bytes, String name) async {
    if (Platform.isAndroid || Platform.isIOS) {
      await NativeRuntime.channel.invokeMethod<void>('export', {
        'name': name,
        'bytes': bytes,
      });
      return;
    }
    final location = await getSaveLocation(suggestedName: name);
    if (location == null) return;
    await XFile.fromData(bytes, name: name).saveTo(location.path);
  }

  Future<void> restoreBackup() async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(label: '轻舟备份', extensions: ['qzb']),
      ],
    );
    if (file == null) return;
    if (await file.length() > 48 * 1024 * 1024) {
      await run(() async => throw const FormatException('备份超过 48 MiB'));
      return;
    }
    final password = await textDialog('输入备份口令', secret: true);
    if (password == null) return;
    await m.action(() async {
      final snapshot = await Backup.decrypt(await file.readAsBytes(), password);
      final modes = (m.capabilities['captureModes'] as List? ?? []);
      final unsupported = snapshot.catalog.profiles.where(
        (p) => !modes.contains(p['configuration']['captureMode']),
      );
      if (unsupported.isNotEmpty) {
        if (!await confirm(
          '接管方式不兼容',
          '${unsupported.length} 份配置的接管方式不适用于本平台。确认改为 ${Platform.isWindows ? '系统代理' : 'VPN'}？',
        )) {
          return;
        }
        for (final p in unsupported) {
          p['configuration']['captureMode'] = Platform.isWindows
              ? 'systemProxy'
              : 'tun';
        }
      }
      if (await confirm(
        '恢复预览',
        '包含 ${snapshot.catalog.profiles.length} 份配置、${snapshot.credentials.length} 项凭据。恢复将替换当前数据，自动连接和登录启动将关闭。',
      )) {
        await m.restore(snapshot);
      }
    }, allowRecovery: true);
  }

  Widget settingsPage() => Column(
    children: [
      card('界面', [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('专业模式'),
          value: professional,
          onChanged: m.busy ? null : changeInterfaceMode,
        ),
        DropdownButtonFormField<String>(
          initialValue: m.preferences['appearance'] as String? ?? 'system',
          items: const [
            DropdownMenuItem(value: 'system', child: Text('跟随系统')),
            DropdownMenuItem(value: 'light', child: Text('白天')),
            DropdownMenuItem(value: 'dark', child: Text('夜间')),
          ],
          onChanged: (v) => run(() => m.setPreference('appearance', v)),
        ),
      ]),
      card('网络设置', [
        DropdownButtonFormField<String>(
          initialValue:
              (m.capabilities['captureModes'] as List? ?? []).contains(
                m.catalog.state['captureMode'],
              )
              ? m.catalog.state['captureMode'] as String
              : null,
          decoration: const InputDecoration(labelText: '接管方式'),
          items: (m.capabilities['captureModes'] as List? ?? [])
              .map(
                (v) => DropdownMenuItem(
                  value: v as String,
                  child: Text(
                    {
                          'tun': 'VPN / TUN',
                          'systemProxy': '系统代理',
                          'compatible': 'TUN + 系统代理',
                        }[v] ??
                        v,
                  ),
                ),
              )
              .toList(),
          onChanged: m.busy
              ? null
              : (v) => run(() => m.change((c) => c.state['captureMode'] = v)),
        ),
        SwitchListTile(
          title: const Text('经代理使用 HTTPS DNS'),
          value: m.catalog.state['dnsPreference'] == 'httpsProxy',
          onChanged: m.busy
              ? null
              : (v) => run(
                  () => m.change(
                    (c) =>
                        c.state['dnsPreference'] = v ? 'httpsProxy' : 'system',
                  ),
                ),
        ),
      ]),
      card('高级功能', [
        TextButton(
          onPressed: m.busy ? null : addRemoteRules,
          child: const Text('添加远程规则源'),
        ),
        if (m.catalog.state['shadowrocket'] != null)
          SwitchListTile(
            title: const Text('HTTP 兼容模式'),
            subtitle: const Text('仅适用于采用本地代理的流量，HTTPS 内容不解密'),
            value: m.catalog.state['httpCompatibilityEnabled'] == true,
            onChanged: m.busy
                ? null
                : (v) => run(
                    () => m.change(
                      (c) => c.state['httpCompatibilityEnabled'] = v,
                    ),
                  ),
          ),
      ]),
      card('备份与恢复', [
        Wrap(
          spacing: 8,
          children: [
            OutlinedButton(
              onPressed: m.busy ? null : exportBackup,
              child: const Text('导出加密备份'),
            ),
            OutlinedButton(
              onPressed: m.busy ? null : restoreBackup,
              child: const Text('恢复备份'),
            ),
          ],
        ),
      ]),
      card('诊断', [
        Text('平台运行状态：${m.status['state']}'),
        Text('核心：${m.capabilities['coreVersion'] ?? '未就绪'}'),
        TextButton(
          onPressed: m.busy || !m.connected
              ? null
              : () => run(() async {
                  final ms = await m.runtime.delay(
                    m.catalog.state['mode'] == 'direct' ? 'direct' : 'proxy',
                  );
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('当前出口 HTTPS 检查通过：$ms ms')),
                    );
                  }
                }),
          child: const Text('当前出口 HTTPS 检查'),
        ),
        TextButton(
          onPressed: m.busy
              ? null
              : () => run(() async {
                  await m.runtime.validate(m.catalog.runtime(m.credentials));
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('核心配置校验通过；实网连通性仍需单独检查')),
                    );
                  }
                }),
          child: const Text('校验配置'),
        ),
        TextButton(
          onPressed: m.busy ? null : () => run(m.recover),
          child: const Text('恢复网络'),
        ),
        ...m.logs.map((s) => Text(s)),
      ]),
    ],
  );
  @override
  Widget build(BuildContext context) {
    final labels = pages;
    final index = page.clamp(0, labels.length - 1);
    final label = labels[index];
    final body = switch (label) {
      '连接' => connectPage(),
      '线路' => nodesPage(),
      '订阅' => subscriptionsPage(),
      '策略' => groupsPage(),
      '规则' => rulesPage(),
      '监控' => monitorPage(),
      '配置' => profilesPage(),
      _ => settingsPage(),
    };
    return ClientShell(
      pages: labels,
      selected: index,
      professional: professional,
      busy: m.busy,
      connected: m.connected,
      error: m.error,
      onNavigate: (value) => setState(() => page = value),
      onModeChanged: changeInterfaceMode,
      icon: icon,
      onImport: m.busy ? null : importText,
      onDismissError: () => setState(() => m.error = null),
      child: body,
    );
  }

  IconData icon(String s) => {
    '连接': Icons.power_settings_new,
    '线路': Icons.route_outlined,
    '订阅': Icons.rss_feed,
    '策略': Icons.hub_outlined,
    '规则': Icons.rule,
    '监控': Icons.monitor_heart_outlined,
    '配置': Icons.folder_outlined,
    '设置': Icons.settings_outlined,
  }[s]!;
}
