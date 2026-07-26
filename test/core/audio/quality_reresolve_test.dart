import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/audio/audio_handler.dart';

void main() {
  test('cached play url is reused only when requested quality matches', () {
    expect(
      shouldReuseCachedPlayUrl(
        cachedUrl: 'file:///tmp/a.flac',
        cachedRequestedQuality: 'flac',
        currentRequestedQuality: 'flac',
      ),
      isTrue,
    );
    expect(
      shouldReuseCachedPlayUrl(
        cachedUrl: 'file:///tmp/a.mp3',
        cachedRequestedQuality: '320k',
        currentRequestedQuality: 'flac',
      ),
      isFalse,
    );
    expect(
      shouldReuseCachedPlayUrl(
        cachedUrl: 'file:///tmp/a.mp3',
        cachedRequestedQuality: null,
        currentRequestedQuality: '320k',
      ),
      isFalse,
    );
    expect(
      shouldReuseCachedPlayUrl(
        cachedUrl: null,
        cachedRequestedQuality: 'flac',
        currentRequestedQuality: 'flac',
      ),
      isFalse,
    );
    expect(
      shouldReuseCachedPlayUrl(
        cachedUrl: 'data:audio/wav;base64,xx',
        cachedRequestedQuality: 'flac',
        currentRequestedQuality: 'flac',
      ),
      isFalse,
    );
  });

  test('quality string map covers settings options', () {
    expect(playQualityToken(AudioQualityToken.low), '128k');
    expect(playQualityToken(AudioQualityToken.high), '320k');
    expect(playQualityToken(AudioQualityToken.lossless), 'flac');
    expect(playQualityToken(AudioQualityToken.lossless24), 'flac24bit');
    expect(playQualityToken(AudioQualityToken.hires), 'hires');
  });
}
