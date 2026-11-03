import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';
import 'package:qingzhou/domain/qr_import.dart';
import 'package:qingzhou/domain/remote_rules.dart';

void main() {
  test('二维码图片解析和限制', () {
    const text = 'trojan://test-secret@example.com:443#fixture';
    final matrix = Encoder.encode(text, ErrorCorrectionLevel.l).matrix!;
    final size = (matrix.width + 8) * 8;
    final image = img.Image(width: size, height: size);
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final xx = x ~/ 8 - 4, yy = y ~/ 8 - 4;
        final black =
            xx >= 0 &&
            yy >= 0 &&
            xx < matrix.width &&
            yy < matrix.height &&
            matrix.get(xx, yy) == 1;
        final value = black ? 0 : 255;
        image.setPixelRgb(x, y, value, value, value);
      }
    }
    expect(QrImport.decode(Uint8List.fromList(img.encodePng(image))), [text]);
    expect(
      () => QrImport.decode(Uint8List(2 * 1024 * 1024 + 1)),
      throwsFormatException,
    );
    expect(
      () => QrImport.decode(Uint8List.fromList([0, 1, 2])),
      throwsFormatException,
    );
  });
  test('规则源类型、数量和参数边界', () {
    final rules = RemoteRules.parse(
      'payload:\n  - +.example.com\n  - 192.0.2.0/24\n',
    );
    expect(rules.map((r) => r['kind']), ['suffix', 'cidr']);
    expect(
      RemoteRules.parse(
        'IP-CIDR6,2001:db8::/32,no-resolve',
      ).single['noResolve'],
      true,
    );
    for (final text in [
      'SCRIPT,test',
      'IP-CIDR,1.2.3.4/99',
      'DOMAIN,example.com,DIRECT',
      'payload: []',
    ]) {
      expect(() => RemoteRules.parse(text), throwsFormatException);
    }
  });
}
