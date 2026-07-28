import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/music_source/platform/wy_source.dart';

void main() {
  test('NetEase EAPI request endpoints use HTTPS', () {
    expect(
      neteaseSearchEndpoint,
      'https://interface.music.163.com/eapi/batch',
    );
    expect(
      neteaseLyricEndpoint,
      'https://interface.music.163.com/eapi/song/lyric/v1',
    );
  });
}
