import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/music_source/platform/kw_source.dart';
import 'package:lx_music_flutter/features/player/domain/music_item.dart';

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

  test('Kw legacy unknown quality keeps the historical mp3 format', () {
    expect(KwSource.legacyFormatForQuality('future-quality'), 'mp3');
    expect(KwSource.legacyFormatForQuality('320k'), 'mp3');
    expect(KwSource.legacyFormatForQuality('flac'), 'flac');
  });

  test('Kw unsupported exact quality performs no token or adapter work',
      () async {
    var tokenCalls = 0;
    var adapterCalls = 0;
    final source = KwSource(
      tokenLoader: () async {
        tokenCalls++;
        return null;
      },
      serviceDioFactory: (headers) {
        adapterCalls++;
        return Dio();
      },
    );
    final music = MusicItem(
      id: 'song',
      name: 'Song',
      singer: 'Singer',
      source: 'kw',
      platform: 'kw',
    );

    final result =
        await source.getMusicUrlExact(music, quality: 'future-quality');

    expect(result, isNull);
    expect(tokenCalls, 0);
    expect(adapterCalls, 0);
  });
}
