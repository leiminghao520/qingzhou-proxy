import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import '../app_model.dart';

class DesktopController with TrayListener, WindowListener {
  final AppModel model;
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
        try {
          await model.runtime.stop();
          await trayManager.destroy();
          await windowManager.destroy();
        } catch (_) {
          model.error = '网络恢复尚未完成，请打开应用检查';
          await windowManager.show();
        }
    }
  }
}
