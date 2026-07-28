import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/music_source/platform/kw_source.dart';

void main() {
  test('Kuwo generated fallback artwork uses HTTPS', () {
    final source = KwSource();
    addTearDown(source.dispose);

    final item = source.parseItem({
      'MUSICRID': 'MUSIC_123456',
      'SONGNAME': 'Track',
      'ARTIST': 'Artist',
    }, 'kw');

    expect(
      item.artwork,
      'https://img.kuwo.cn/star/starheads/123456_small.jpg',
    );
  });
}
