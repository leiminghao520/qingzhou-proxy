import 'package:flutter/material.dart';

class ConnectionDashboard extends StatelessWidget {
  final bool connected;
  final String stateLabel, nodeName, captureLabel, proxyMode, coreVersion;
  final int nodeCount;
  final String? diagnosticSummary;
  final VoidCallback? onToggle, onImport, onFile, onRecover;
  final ValueChanged<String>? onModeChanged;
  final bool notificationsDisabled;
  const ConnectionDashboard({
    super.key,
    required this.connected,
    this.diagnosticSummary,
    required this.stateLabel,
    required this.nodeName,
    required this.captureLabel,
    required this.proxyMode,
    required this.coreVersion,
    required this.nodeCount,
    required this.onToggle,
    required this.onImport,
    required this.onFile,
    required this.onRecover,
    required this.onModeChanged,
    required this.notificationsDisabled,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final muted = colors.onSurfaceVariant;
    Widget panel(Widget child) => Card(
      child: Padding(padding: const EdgeInsets.all(24), child: child),
    );
    Widget metric(IconData icon, String label, String value) => Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Column(
          children: [
            Icon(icon, size: 20, color: muted),
            const SizedBox(height: 10),
            Text(value, style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(label, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
          ],
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            gradient: LinearGradient(
              colors: theme.brightness == Brightness.dark
                  ? const [Color(0xff263354), Color(0xff202a42)]
                  : const [Color(0xffedf1ff), Color(0xfff0f7ff)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: connected ? const Color(0xff28a579) : muted,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(stateLabel, style: theme.textTheme.titleMedium),
                  const Spacer(),
                  Icon(Icons.shield_outlined, color: colors.primary),
                ],
              ),
              const SizedBox(height: 24),
              Text(
                connected ? (diagnosticSummary == null ? '连接已建立' : '代理核心已运行') : '让连接，轻盈一点',
                style: theme.textTheme.headlineMedium,
              ),
              const SizedBox(height: 10),
              Text(
                connected ? (diagnosticSummary ?? '线路已就绪，可在设置中检查实际连通性。') : '选择一条线路，开启你的轻舟之旅。',
                style: TextStyle(color: muted, height: 1.6),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Icon(Icons.public, color: colors.primary, size: 22),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('当前线路', style: TextStyle(color: muted, fontSize: 12)),
                              const SizedBox(height: 4),
                              Text(nodeName, maxLines: 2, overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleMedium),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: onToggle,
                    icon: Icon(connected ? Icons.stop_circle_outlined : Icons.power_settings_new),
                    label: Text(connected ? '断开连接' : '连接'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        panel(Row(children: [
          metric(Icons.route_outlined, '可用配置线路', '$nodeCount 条'),
          metric(Icons.layers_outlined, '接管方式', captureLabel),
          metric(Icons.memory_outlined, '代理核心', coreVersion),
        ])),
        const SizedBox(height: 20),
        panel(Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('代理模式', style: theme.textTheme.titleLarge),
            const SizedBox(height: 6),
            Text('按规则分流，或为当前连接选择统一出口。', style: TextStyle(color: muted)),
            const SizedBox(height: 18),
            Wrap(spacing: 10, runSpacing: 10, children: [
              for (final entry in const {'rule': '规则分流', 'global': '全部代理', 'direct': '全部直连'}.entries)
                ChoiceChip(
                  label: Text(entry.value),
                  selected: proxyMode == entry.key,
                  onSelected: onModeChanged == null ? null : (_) => onModeChanged!(entry.key),
                  showCheckmark: false,
                  avatar: Icon(entry.key == 'rule' ? Icons.alt_route : entry.key == 'global' ? Icons.language : Icons.arrow_forward, size: 18),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  side: BorderSide.none,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
            ]),
          ],
        )),
        const SizedBox(height: 20),
        panel(Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('管理你的线路', style: theme.textTheme.titleLarge),
            const SizedBox(height: 6),
            Text('从订阅、节点链接或配置文件开始。', style: TextStyle(color: muted)),
            const SizedBox(height: 18),
            Wrap(spacing: 10, runSpacing: 10, children: [
              OutlinedButton.icon(onPressed: onImport, icon: const Icon(Icons.add_link), label: const Text('添加订阅或节点')),
              OutlinedButton.icon(onPressed: onFile, icon: const Icon(Icons.file_open_outlined), label: const Text('导入文件')),
              TextButton(onPressed: onRecover, child: const Text('恢复网络')),
            ]),
          ],
        )),
        if (notificationsDisabled)
          const Padding(
            padding: EdgeInsets.only(top: 16),
            child: Text('通知未开启，可在本页断开 VPN，或在系统设置中允许通知。'),
          ),
      ],
    );
  }
}
