import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingzhou/app_model.dart';
import 'package:qingzhou/main.dart';
import 'package:qingzhou/domain/importer.dart';
import 'app_model_test.dart' show FakeRuntime, MemoryRepository;

void main() {
  testWidgets('批量收藏和删除确认在手机上可用', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final runtime = FakeRuntime();
    final m = AppModel(runtime, MemoryRepository());
    await m.initialize();
    await m.applyImport(
      m.preview(
        Importer.parse(
          'trojan://one@example.com#甲\ntrojan://two@example.org#乙',
        ),
      ),
    );
    await tester.pumpWidget(QingzhouApp(model: m));
    await tester.pumpAndSettle();
    await tester.tap(find.text('线路').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('批量管理'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择筛选结果'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('收藏已选'));
    await tester.pumpAndSettle();
    expect(m.catalog.state['favorites'], hasLength(2));
    await tester.tap(find.text('删除已选（2）'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('删除线路预览'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(m.catalog.nodes, hasLength(2));
    await tester.tap(find.text('删除已选（2）'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.widgetWithText(FilledButton, '确认'));
    await tester.pumpAndSettle();
    expect(m.catalog.nodes, isEmpty);
    expect(m.credentials, isEmpty);
    expect(runtime.events, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    m.dispose();
  });
  for (final wide in [false, true]) {
    testWidgets(wide ? '桌面专业导航可见' : '手机简洁导航可用', (tester) async {
      tester.view.physicalSize = wide
          ? const Size(1280, 900)
          : const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final m = AppModel(FakeRuntime(), MemoryRepository());
      await m.initialize();
      if (wide) m.preferences['professional'] = true;
      await tester.pumpWidget(QingzhouApp(model: m));
      await tester.pumpAndSettle();
      expect(find.text('轻舟代理 · 连接'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('设置').last);
      await tester.pumpAndSettle();
      expect(find.text('导出加密备份'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      m.dispose();
    });
  }
}
