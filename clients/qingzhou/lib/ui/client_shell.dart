import 'package:flutter/material.dart';

class ClientShell extends StatelessWidget {
  final List<String> pages;
  final int selected;
  final bool professional, busy, connected;
  final String? error;
  final Widget child;
  final ValueChanged<int> onNavigate;
  final ValueChanged<bool> onModeChanged;
  final IconData Function(String) icon;
  final VoidCallback? onImport;
  final VoidCallback onDismissError;
  const ClientShell({
    super.key,
    required this.pages,
    required this.selected,
    required this.professional,
    required this.busy,
    required this.connected,
    required this.error,
    required this.child,
    required this.onNavigate,
    required this.onModeChanged,
    required this.icon,
    required this.onImport,
    required this.onDismissError,
  });

  Widget modeSwitch() => SegmentedButton<bool>(
    key: const ValueKey('interface-mode-switch'),
    segments: const [
      ButtonSegment(value: false, label: Text('简洁')),
      ButtonSegment(value: true, label: Text('专业')),
    ],
    selected: {professional},
    showSelectedIcon: false,
    style: const ButtonStyle(visualDensity: VisualDensity.compact),
    onSelectionChanged: busy ? null : (value) => onModeChanged(value.single),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final title = pages[selected];
    return LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth >= 900;
      Widget navigation({bool drawer = false}) => ListView(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        children: [
          for (final entry in pages.asMap().entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: ListTile(
                selected: selected == entry.key,
                selectedTileColor: colors.primary.withValues(alpha: 0.09),
                selectedColor: colors.primary,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                leading: Icon(icon(entry.value), size: 21),
                title: Text(entry.value, style: TextStyle(fontWeight: selected == entry.key ? FontWeight.w600 : FontWeight.w400)),
                onTap: () {
                  onNavigate(entry.key);
                  if (drawer) Navigator.pop(context);
                },
              ),
            ),
        ],
      );
      final content = Column(children: [
        if (busy) const LinearProgressIndicator(minHeight: 2),
        if (error != null)
          MaterialBanner(
            content: Text(error!),
            actions: [TextButton(onPressed: onDismissError, child: const Text('关闭'))],
          ),
        Expanded(
          child: ListView(
            key: const PageStorageKey('client-content'),
            padding: EdgeInsets.all(wide ? 32 : 16),
            children: [
              Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1020),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (wide) ...[
                        Row(children: [
                          Expanded(child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('轻舟代理 · $title', style: theme.textTheme.headlineMedium),
                              const SizedBox(height: 8),
                              Text(
                                professional ? '专业工作台 · 按你的方式管理连接' : '简单设置，轻松连接',
                                style: TextStyle(color: colors.onSurfaceVariant),
                              ),
                            ],
                          )),
                          modeSwitch(),
                          const SizedBox(width: 16),
                          IconButton.filledTonal(
                            tooltip: '添加订阅或节点',
                            onPressed: onImport,
                            icon: const Icon(Icons.add),
                          ),
                        ]),
                        const SizedBox(height: 28),
                      ],
                      child,
                      const SizedBox(height: 12),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ]);
      return Scaffold(
        appBar: wide ? null : AppBar(
          title: Text('轻舟代理 · $title', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          actions: [modeSwitch(), const SizedBox(width: 10)],
        ),
        body: Row(children: [
          if (wide)
            Container(
              width: 220,
              decoration: BoxDecoration(
                color: colors.surface,
                border: Border(right: BorderSide(color: theme.dividerColor)),
              ),
              child: Column(children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(26, 32, 20, 32),
                  child: Row(children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(color: colors.primary, borderRadius: BorderRadius.circular(12)),
                      child: Icon(Icons.near_me_rounded, color: colors.onPrimary, size: 24),
                    ),
                    const SizedBox(width: 12),
                    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('轻舟代理', style: theme.textTheme.titleLarge),
                      const SizedBox(height: 3),
                      Text('QINGZHOU PROXY', style: TextStyle(fontSize: 9, letterSpacing: 1.3, color: colors.onSurfaceVariant)),
                    ]),
                  ]),
                ),
                Expanded(child: navigation()),
                Padding(
                  padding: const EdgeInsets.all(22),
                  child: Row(children: [
                    Icon(connected ? Icons.check_circle_outline : Icons.radio_button_unchecked,
                        size: 16, color: connected ? const Color(0xff28a579) : colors.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Text(connected ? '连接已建立' : '等待连接', style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12)),
                  ]),
                ),
              ]),
            ),
          Expanded(child: content),
        ]),
        drawer: !wide && professional ? Drawer(child: SafeArea(child: navigation(drawer: true))) : null,
        bottomNavigationBar: wide || professional ? null : NavigationBar(
          selectedIndex: selected,
          onDestinationSelected: onNavigate,
          destinations: pages.map((page) => NavigationDestination(icon: Icon(icon(page)), label: page)).toList(),
        ),
      );
    });
  }
}
