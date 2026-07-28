import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/music_source/platform/kw_source.dart';

void main() {
  test('Kuwo request endpoints use HTTPS', () {
    expect(kuwoSearchBaseUrl, 'https://search.kuwo.cn');
    expect(kuwoArtworkEndpoint, 'https://artistpicserver.kuwo.cn/pic.web');
    expect(kuwoAntiServerEndpoint, 'https://antiserver.kuwo.cn/anti.s');
    expect(
      kuwoPlayInfoEndpoint,
      'https://www.kuwo.cn/api/v1/www/music/playInfo',
    );
    expect(kuwoLegacyPlayEndpoint, 'https://www.kuwo.cn/url');
    expect(kuwoLyricEndpoint, 'https://newlyric.kuwo.cn/newlyric.lrc');
    expect(kuwoPlaylistEndpoint, 'https://nplserver.kuwo.cn/pl.svc');
  });

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
