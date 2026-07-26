import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/features/player/domain/music_item.dart';

void main() {
  group('MusicItem', () {
    test('should create MusicItem with required fields', () {
      final music = MusicItem(
        id: '1',
        name: 'Test Song',
        singer: 'Test Artist',
        source: 'test',
      );

      expect(music.id, '1');
      expect(music.name, 'Test Song');
      expect(music.singer, 'Test Artist');
      expect(music.source, 'test');
    });

    test('should create MusicItem with optional fields', () {
      final music = MusicItem(
        id: '1',
        name: 'Test Song',
        singer: 'Test Artist',
        source: 'test',
        album: 'Test Album',
        duration: const Duration(minutes: 3, seconds: 30),
        artwork: 'https://example.com/artwork.jpg',
        url: 'https://example.com/song.mp3',
        lyricsUrl: 'https://example.com/lyrics.lrc',
      );

      expect(music.album, 'Test Album');
      expect(music.duration, const Duration(minutes: 3, seconds: 30));
      expect(music.artwork, 'https://example.com/artwork.jpg');
      expect(music.url, 'https://example.com/song.mp3');
      expect(music.lyricsUrl, 'https://example.com/lyrics.lrc');
    });

    test('should copy MusicItem with new values', () {
      final music = MusicItem(
        id: '1',
        name: 'Test Song',
        singer: 'Test Artist',
        source: 'test',
      );

      final copied = music.copyWith(
        name: 'Updated Song',
        singer: 'Updated Artist',
      );

      expect(copied.id, '1');
      expect(copied.name, 'Updated Song');
      expect(copied.singer, 'Updated Artist');
      expect(copied.source, 'test');
    });

    test('should be equal based on id', () {
      final music1 = MusicItem(
        id: '1',
        name: 'Song 1',
        singer: 'Artist 1',
        source: 'test',
      );

      final music2 = MusicItem(
        id: '1',
        name: 'Song 2',
        singer: 'Artist 2',
        source: 'test',
      );

      final music3 = MusicItem(
        id: '2',
        name: 'Song 1',
        singer: 'Artist 1',
        source: 'test',
      );

      expect(music1, music2);
      expect(music1, isNot(music3));
    });
  });
}
