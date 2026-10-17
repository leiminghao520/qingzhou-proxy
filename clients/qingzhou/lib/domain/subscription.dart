import 'dart:async';
import 'dart:convert';
import 'dart:io';

class SubscriptionFetcher {
  Future<String> fetch(String source) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      return await _read(
        client,
        Uri.parse(source),
        0,
      ).timeout(const Duration(seconds: 15));
    } finally {
      client.close(force: true);
    }
  }

  Future<String> _read(HttpClient client, Uri uri, int redirects) async {
    if (uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      throw const FormatException('订阅或规则地址必须为 HTTPS');
    }
    if (redirects > 5) throw const FormatException('重定向次数过多');
    final request = await client.getUrl(uri);
    request.followRedirects = false;
    request.headers.set(HttpHeaders.userAgentHeader, 'Qingzhou');
    final response = await request.close();
    if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
      final location = response.headers.value(HttpHeaders.locationHeader);
      if (location == null) throw const FormatException('重定向缺少地址');
      await response.drain<void>();
      return _read(client, uri.resolve(location), redirects + 1);
    }
    if (response.statusCode != 200) throw const FormatException('订阅下载失败');
    if (response.contentLength > 2 * 1024 * 1024) {
      throw const FormatException('下载超过 2 MiB');
    }
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length > 2 * 1024 * 1024) {
        throw const FormatException('下载超过 2 MiB');
      }
    }
    return utf8.decode(bytes);
  }
}
