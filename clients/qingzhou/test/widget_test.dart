import 'package:flutter_test/flutter_test.dart';
import 'package:qingzhou/domain/catalog.dart';

void main() {
  test('默认配置关闭自动连接与兼容模式', () {
    final c = Catalog.empty();
    expect(c.state['captureMode'], 'tun');
    expect(c.state['autoConnect'], false);
    expect(c.state['httpCompatibilityEnabled'], false);
  });
}
