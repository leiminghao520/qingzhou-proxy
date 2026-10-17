import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingzhou/app_model.dart';
import 'package:qingzhou/main.dart';
import 'app_model_test.dart' show FakeRuntime, MemoryRepository;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final path = Platform.environment['QINGZHOU_PREVIEW_FONT'];
    if (path != null) {
      final loader = FontLoader('Microsoft YaHei UI');
      loader.addFont(File(path).readAsBytes().then(ByteData.sublistView));
      await loader.load();
    }
  });
  testWidgets('桌面明暗主题和两种模式可渲染', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final m = AppModel(FakeRuntime(), MemoryRepository());
    await m.initialize();
    for (final appearance in ['light', 'dark']) {
      for (final professional in [false, true]) {
        m.preferences = {'appearance': appearance, 'professional': professional};
        final key = GlobalKey();
        await tester.pumpWidget(RepaintBoundary(key: key, child: QingzhouApp(model: m)));
        await tester.pumpAndSettle();
        expect(find.text('轻舟代理 · 连接'), findsOneWidget);
        expect(find.text('让连接，轻盈一点'), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (const bool.fromEnvironment('QINGZHOU_PREVIEW')) {
          // 保存真实 Flutter 渲染结果供人工检查，不将截图生成视为视觉验收。
          final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 1);
            final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
            final directory = Directory('../../outputs/windows-ui-preview');
            await directory.create(recursive: true);
            await File('${directory.path}/$appearance-${professional ? 'professional' : 'simple'}.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
      }
    }
    await tester.pumpWidget(const SizedBox());
    m.dispose();
  });
}
