import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';

class QrImport {
  static List<String> decode(Uint8List bytes) {
    if (bytes.length > 2 * 1024 * 1024) {
      throw const FormatException('二维码图片超过 2 MiB');
    }
    final decoder = img.findDecoderForData(bytes);
    final info = decoder?.startDecode(bytes);
    if (info == null || info.width * info.height > 20000000) {
      throw const FormatException('图片无效或超过 2000 万像素');
    }
    final image = decoder!.decodeFrame(0)?.convert(numChannels: 4);
    if (image == null) throw const FormatException('图片解码失败');
    final results = <String>[];
    for (var count = 0; count < 20; count++) {
      final pixels = image.getBytes(order: img.ChannelOrder.bgra);
      final bitmap = BinaryBitmap(
        HybridBinarizer(
          RGBLuminanceSource(
            image.width,
            image.height,
            pixels.buffer.asInt32List(),
          ),
        ),
      );
      try {
        final result = QRCodeReader().decode(bitmap);
        if (!results.contains(result.text)) results.add(result.text);
        final points = result.resultPoints;
        if (points.length < 3) break;
        final left = points.map((p) => p.x).reduce((a, b) => a < b ? a : b);
        final right = points.map((p) => p.x).reduce((a, b) => a > b ? a : b);
        final top = points.map((p) => p.y).reduce((a, b) => a < b ? a : b);
        final bottom = points.map((p) => p.y).reduce((a, b) => a > b ? a : b);
        final margin = ((right - left) + (bottom - top)) / 8 + 8;
        for (
          var y = (top - margin).floor().clamp(0, image.height - 1);
          y <= (bottom + margin).ceil().clamp(0, image.height - 1);
          y++
        ) {
          for (
            var x = (left - margin).floor().clamp(0, image.width - 1);
            x <= (right + margin).ceil().clamp(0, image.width - 1);
            x++
          ) {
            image.setPixelRgba(x, y, 255, 255, 255, 255);
          }
        }
      } on ReaderException {
        break;
      }
    }
    if (results.isEmpty) throw const FormatException('未识别到二维码');
    return results;
  }
}
