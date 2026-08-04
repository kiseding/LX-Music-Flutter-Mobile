import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/music_source/platform/tx_source.dart';

void main() {
  test('Tx exact filename candidates never contain a lower quality prefix', () {
    expect(
      TxSource.exactFilenames('song', 'media', 'flac'),
      ['F000media.flac', 'F000song.flac'],
    );
    expect(TxSource.exactFilenames('song', 'media', '320k'),
        ['M800media.mp3', 'M800song.mp3']);
    expect(TxSource.exactFilenames('song', 'media', '192k'), isEmpty);
    expect(TxSource.exactFilenames('song', 'media', '128k'),
        ['M500media.mp3', 'C400media.m4a', 'M500song.mp3', 'C400song.m4a']);
  });

  test('Tx exact attempt keys collapse aliases and reject unsupported quality',
      () {
    expect(TxSource.exactAttemptKeyForQuality('hires'), 'F000');
    expect(TxSource.exactAttemptKeyForQuality('flac24bit'), 'F000');
    expect(TxSource.exactAttemptKeyForQuality('flac'), 'F000');
    expect(TxSource.exactAttemptKeyForQuality('320k'), 'M800');
    expect(TxSource.exactAttemptKeyForQuality('192k'), isNull);
    expect(TxSource.exactAttemptKeyForQuality('128k'), 'M500/C400');
  });

  test('Tx exact response filename must retain requested quality identity', () {
    expect(TxSource.isExactResponseFilename('flac', 'F000song.flac'), isTrue);
    expect(TxSource.isExactResponseFilename('flac', 'M800song.mp3'), isFalse);
    expect(TxSource.isExactResponseFilename('320k', 'M800song.mp3'), isTrue);
    expect(TxSource.isExactResponseFilename('320k', 'M500song.mp3'), isFalse);
    expect(TxSource.isExactResponseFilename('128k', 'M500song.mp3'), isTrue);
    expect(TxSource.isExactResponseFilename('128k', 'C400song.m4a'), isTrue);
  });

  test('Tx legacy unknown quality keeps the historical fallback candidates',
      () {
    expect(
      TxSource.legacyFilenames('song', 'media', 'future-quality'),
      ['C400song.m4a', 'M500song.mp3'],
    );
  });
}
