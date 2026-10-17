import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingzhou/app_model.dart';
import 'package:qingzhou/main.dart';
import 'package:qingzhou/domain/importer.dart';
import 'app_model_test.dart' show FakeRuntime, MemoryRepository;

class InterfacePreferences extends MemoryRepository {
  Map<String, dynamic> saved = {};
  bool rejectSave = false;
  @override
  Future<Map<String, dynamic>> preferences() async => {...saved};
  @override
  Future<void> savePreferences(Map<String, dynamic> preferences) async {
    if (rejectSave) throw StateError('disk');
    saved = {...preferences};
  }
}

void main() {
  for (final width in [390.0, 800.0, 1280.0]) {
    testWidgets('顶部模式切换可发现、保留页面并持久化：$width', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = InterfacePreferences();
      final runtime = FakeRuntime();
      final m = AppModel(runtime, repository);
      await m.initialize();
      await tester.pumpWidget(QingzhouApp(model: m));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('interface-mode-switch')), findsOneWidget);
      await tester.tap(find.text('设置').last);
      await tester.pumpAndSettle();
      await tester.drag(find.byKey(const PageStorageKey('client-content')), const Offset(0, -1000));
      await tester.pumpAndSettle();
      await tester.tap(find.text('专业'));
      await tester.pumpAndSettle();
      expect(m.preferences['professional'], true);
      expect(repository.saved['professional'], true);
      expect(find.text('轻舟代理 · 设置'), findsOneWidget);
      if (width < 900) {
        await tester.tap(find.byTooltip('Open navigation menu'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('策略').last);
      await tester.pumpAndSettle();
      expect(find.text('轻舟代理 · 策略'), findsOneWidget);
      await tester.tap(find.text('简洁'));
      await tester.pumpAndSettle();
      expect(find.text('轻舟代理 · 连接'), findsOneWidget);
      expect(repository.saved['professional'], false);
      expect(runtime.events, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      m.dispose();
      final restored = AppModel(FakeRuntime(), repository);
      await restored.initialize();
      expect(restored.preferences['professional'], false);
      restored.dispose();
    });
  }
  testWidgets('模式保存失败保持原界面，深色窄屏仍可操作', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = InterfacePreferences();
    repository.saved = {'appearance': 'dark'};
    final m = AppModel(FakeRuntime(), repository);
    await m.initialize();
    repository.rejectSave = true;
    await tester.pumpWidget(QingzhouApp(model: m));
    await tester.pumpAndSettle();
    await tester.tap(find.text('专业'));
    await tester.pumpAndSettle();
    expect(m.preferences['professional'], isNot(true));
    expect(find.text('轻舟代理 · 连接'), findsOneWidget);
    expect(find.text('操作失败，请查看脱敏诊断'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    m.dispose();
  });
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
