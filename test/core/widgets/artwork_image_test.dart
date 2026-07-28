import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/widgets/artwork_image.dart';

void main() {
  const neteaseUrl =
      'https://p1.music.126.net/F0fTkmBTVykCa2o7Vgu1rQ==/109951173569626660.jpg';
  const qqUrl = 'https://y.gtimg.cn/music/photo_new/T002R300x300M000abc.jpg';

  test('artwork provider normalizes dynamic HTTP URLs', () {
    const image = ArtworkNetworkImage('http://images.example.com/cover.jpg');
    expect(image.resolvedUrl, 'https://images.example.com/cover.jpg');
  });

  test('netease artwork requests use browser headers', () {
    final headers = artworkRequestHeaders(neteaseUrl);
    expect(headers['User-Agent'], contains('Mozilla'));
    expect(headers['Referer'], 'https://music.163.com/');
    expect(artworkNeedsBrowserClient(neteaseUrl), isTrue);
  });

  test('non-netease artwork does not force netease headers', () {
    final headers = artworkRequestHeaders(qqUrl);
    expect(headers, isEmpty);
    expect(artworkNeedsBrowserClient(qqUrl), isFalse);
  });

  test('headers.add keeps Dart UA and is blocked by netease CDN', () async {
    final client = HttpClient();
    final req = await client.getUrl(Uri.parse(neteaseUrl));
    // Mimic NetworkImage / Image.network(headers: ...)
    req.headers.add('User-Agent', kArtworkUserAgent);
    req.headers.add('Referer', 'https://music.163.com/');
    expect(req.headers['user-agent']!.length, greaterThan(1));
    final res = await req.close();
    final bytes = await res.fold<List<int>>(<int>[], (a, b) {
      a.addAll(b);
      return a;
    });
    client.close(force: true);
    expect(res.statusCode, 403);
    expect(bytes.first, 0x3C); // <html
  });

  test('HttpClient.userAgent replacement loads netease cover', () async {
    final client = HttpClient()..userAgent = kArtworkUserAgent;
    final req = await client.getUrl(Uri.parse(neteaseUrl));
    req.headers.set('Referer', 'https://music.163.com/');
    expect(req.headers['user-agent'], [kArtworkUserAgent]);
    final res = await req.close();
    final bytes = await res.fold<List<int>>(<int>[], (a, b) {
      a.addAll(b);
      return a;
    });
    client.close(force: true);

    expect(res.statusCode, 200);
    expect(bytes.first, 0xFF); // JPEG
    expect(bytes.length, greaterThan(1000));
  });
}
