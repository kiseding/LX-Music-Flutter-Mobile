import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/widgets/artwork_image.dart';

void main() {
  test('netease artwork requests use browser headers', () {
    final headers = artworkRequestHeaders(
      'https://p1.music.126.net/F0fTkmBTVykCa2o7Vgu1rQ==/109951173569626660.jpg',
    );
    expect(headers['User-Agent'], contains('Mozilla'));
    expect(headers['Referer'], 'https://music.163.com/');
  });

  test('non-netease artwork does not force netease headers', () {
    final headers = artworkRequestHeaders(
      'https://y.gtimg.cn/music/photo_new/T002R300x300M000abc.jpg',
    );
    expect(headers, isEmpty);
  });

  test('dart HttpClient can load netease cover with artwork headers', () async {
    const url =
        'https://p1.music.126.net/F0fTkmBTVykCa2o7Vgu1rQ==/109951173569626660.jpg';
    final client = HttpClient();
    final req = await client.getUrl(Uri.parse(url));
    artworkRequestHeaders(url).forEach(req.headers.set);
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
