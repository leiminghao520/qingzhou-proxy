import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import '../app_model.dart';

class DesktopController with TrayListener, WindowListener {
  final AppModel model;
  bool _quitting = false;
  DesktopController(this.model);
  Future<void> initialize() async {
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
    await trayManager.setIcon('assets/tray.ico');
    await trayManager.setToolTip('轻舟代理');
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'show', label: '打开轻舟代理'),
          MenuItem(key: 'disconnect', label: '断开连接'),
          MenuItem.separator(),
          MenuItem(key: 'quit', label: '断开并退出'),
        ],
      ),
    );
    trayManager.addListener(this);
    windowManager.addListener(this);
  }

  @override
  void onWindowClose() {
    windowManager.hide();
  }

  @override
  void onTrayIconMouseDown() {
    windowManager.show();
    windowManager.focus();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    switch (menuItem.key) {
      case 'show':
        await windowManager.show();
        await windowManager.focus();
      case 'disconnect':
        await model.action(() async {
          await model.runtime.stop();
          await model.poll();
        });
      case 'quit':
        if (_quitting) return;
        _quitting = true;
        try {
          var prepared = false;
          await model.action(() async {
            await model.prepareToExit();
            prepared = true;
          }, allowRecovery: true);
          if (!prepared) {
            await windowManager.show();
            await windowManager.focus();
            return;
          }
          await trayManager.destroy();
          await windowManager.destroy();
        } catch (_) {
          await model.action(() async {
            throw const FormatException('网络已确认断开，但桌面窗口退出失败，请重试退出');
          }, allowRecovery: true);
          await windowManager.show();
        } finally {
          _quitting = false;
        }
    }
  }
}
