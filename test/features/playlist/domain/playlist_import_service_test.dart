import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/music_source/platform/source_utils.dart';

void main() {
  test('网易云导入歌单将 HTTP 封面规范化为 HTTPS', () {
    expect(
      normalizeNeteaseArtwork('http://p1.music.126.net/artwork.jpg'),
      'https://p1.music.126.net/artwork.jpg',
    );
  });
}
