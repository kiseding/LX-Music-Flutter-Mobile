import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/music_source/platform/kw_source.dart';

void main() {
  test('Kw exact attempt keys collapse server format aliases', () {
    expect(KwSource.exactAttemptKeyForQuality('hires'), 'flac');
    expect(KwSource.exactAttemptKeyForQuality('flac24bit'), 'flac');
    expect(KwSource.exactAttemptKeyForQuality('flac'), 'flac');
    expect(KwSource.exactAttemptKeyForQuality('320k'), 'mp3');
    expect(KwSource.exactAttemptKeyForQuality('192k'), 'mp3');
    expect(KwSource.exactAttemptKeyForQuality('128k'), 'mp3');
  });

  test('Kw exact format reports conservative actual quality', () {
    expect(KwSource.actualQualityForAttemptKey('flac'), 'flac');
    expect(KwSource.actualQualityForAttemptKey('mp3'), '128k');
  });

  test('Kw exact response quality is corrected from returned URL', () {
    expect(
      KwSource.actualQualityForExactUrl(
          'flac', 'https://media.example/song.flac'),
      'flac',
    );
    expect(
      KwSource.actualQualityForExactUrl(
          'flac', 'https://media.example/song.mp3'),
      '128k',
    );
    expect(
      KwSource.actualQualityForExactUrl(
          'mp3', 'https://media.example/song.mp3'),
      '128k',
    );
  });
}
