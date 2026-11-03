import 'package:flutter_test/flutter_test.dart';
import 'package:qingzhou/app_model.dart';
import 'package:qingzhou/domain/catalog.dart';
import 'app_model_test.dart' show FakeRuntime, MemoryRepository;

class ExitRuntime extends FakeRuntime {
  bool stopFails = false, recoveryFails = false;
  int recoveries = 0;
  Json? finalStatus;
  @override
  Future<void> stop() async {
    if (stopFails) throw const FormatException('停止响应失败');
    await super.stop();
  }

  @override
  Future<void> recover() async {
    recoveries++;
    if (recoveryFails) throw const FormatException('网络设置已被外部修改');
    await super.recover();
  }

  @override
  Future<Json> status() async => finalStatus ?? await super.status();
}

void main() {
  test('退出前确认停止并清除连接缓存', () async {
    final runtime = ExitRuntime()..running = true;
    final model = AppModel(runtime, MemoryRepository());
    model.connections = {'connections': []};
    await model.prepareToExit();
    expect(model.status['state'], 'disconnected');
    expect(model.connections, isNull);
    expect(runtime.recoveries, 0);
    model.dispose();
  });

  test('停止响应失败时恢复重试并核验状态', () async {
    final runtime = ExitRuntime()..stopFails = true;
    final model = AppModel(runtime, MemoryRepository());
    await model.prepareToExit();
    expect(runtime.recoveries, 1);
    expect(model.status['state'], 'disconnected');
    model.dispose();
  });

  test('恢复仍失败时保留具体原因并阻止退出', () async {
    final runtime = ExitRuntime()..stopFails = true..recoveryFails = true;
    final model = AppModel(runtime, MemoryRepository());
    await expectLater(model.prepareToExit(), throwsA(isA<FormatException>().having((e) => e.message, 'message', '网络设置已被外部修改')));
    model.dispose();
  });

  for (final state in [
    {'state': 'recoveryRequired', 'coreRunning': false},
    {'state': 'disconnected', 'coreRunning': true},
  ]) {
    test('未确认安全状态不能退出：$state', () async {
      final runtime = ExitRuntime()..finalStatus = state;
      final model = AppModel(runtime, MemoryRepository());
      await expectLater(model.prepareToExit(), throwsFormatException);
      model.dispose();
    });
  }
}
