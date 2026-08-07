import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/music_source/platform/wy_source.dart';

void main() {
  test('Wy exact bitrate mapping is public and stable', () {
    expect(WySource.exactBitrateForQuality('hires'), 999000);
    expect(WySource.exactBitrateForQuality('flac24bit'), 999000);
    expect(WySource.exactBitrateForQuality('flac'), 999000);
    expect(WySource.exactBitrateForQuality('320k'), 320000);
    expect(WySource.exactBitrateForQuality('192k'), 192000);
    expect(WySource.exactBitrateForQuality('128k'), 128000);
  });

  test('Wy actual quality uses response bitrate metadata', () {
    expect(WySource.qualityFromBitrate(999000), 'flac');
    expect(WySource.qualityFromBitrate(320000), '320k');
    expect(WySource.qualityFromBitrate(192000), '192k');
    expect(WySource.qualityFromBitrate(128000), '128k');
  });

  test('Wy legacy unknown quality keeps the historical 128000 bitrate', () {
    expect(WySource.legacyBitrateForQuality('future-quality'), 128000);
    expect(WySource.legacyBitrateForQuality('128k'), 128000);
    expect(WySource.legacyBitrateForQuality('192k'), 192000);
  });

  test('Wy exact unknown quality is unsupported', () {
    expect(WySource.exactBitrateForQuality('future-quality'), isNull);
  });
}
