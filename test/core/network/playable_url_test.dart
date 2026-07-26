import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/network/play_url_result.dart';

void main() {
  test('rejects empty and root-only CDN urls', () {
    expect(isPlayableMediaUrl(null), isFalse);
    expect(isPlayableMediaUrl(''), isFalse);
    expect(isPlayableMediaUrl('http://wx.music.tc.qq.com/'), isFalse);
    expect(isPlayableMediaUrl('https://wx.music.tc.qq.com'), isFalse);
    expect(isPlayableMediaUrl('not-a-url'), isFalse);
  });

  test('accepts real media paths', () {
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
