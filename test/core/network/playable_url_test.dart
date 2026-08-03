import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/network/play_url_result.dart';

void main() {
  test('rejects values that cannot be remote media requests', () {
    expect(isPlayableMediaUrl(null), isFalse);
    expect(isPlayableMediaUrl(''), isFalse);
    expect(isPlayableMediaUrl('not-a-url'), isFalse);
    expect(isPlayableMediaUrl('/relative/file.mp3'), isFalse);
    expect(isPlayableMediaUrl('file:///tmp/file.mp3'), isFalse);
  });

  test('accepts absolute media endpoints regardless of path shape', () {
    expect(isPlayableMediaUrl('https://media.example.com'), isTrue);
    expect(
      isPlayableMediaUrl('https://media.example.com/?token=abc&song=123'),
      isTrue,
    );
    expect(
      isPlayableMediaUrl(
        'http://wx.music.tc.qq.com/M800004UlK9x0jeuow.mp3?guid=1',
      ),
      isTrue,
    );
    expect(
      isPlayableMediaUrl(
        'http://wx.music.tc.qq.com/F000004UlK9x0jeuow.flac',
      ),
      isTrue,
    );
    expect(
      isPlayableMediaUrl(
        'https://m801.music.126.net/20260726/abc/file.mp3',
      ),
      isTrue,
    );
  });
}
