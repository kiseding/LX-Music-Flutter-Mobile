import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/features/playlist/domain/playlist.dart';
import 'package:lx_music_flutter/features/player/domain/music_item.dart';

void main() {
  group('Playlist', () {
    test('should create Playlist with required fields', () {
      final now = DateTime.now();
      final playlist = Playlist(
        id: '1',
        name: 'Test Playlist',
        createdAt: now,
        updatedAt: now,
      );

      expect(playlist.id, '1');
      expect(playlist.name, 'Test Playlist');
      expect(playlist.songs, isEmpty);
    });

    test('should create Playlist with songs', () {
      final now = DateTime.now();
      final songs = [
        MusicItem(
          id: '1',
          name: 'Song 1',
          singer: 'Artist 1',
          source: 'test',
          duration: const Duration(minutes: 3),
        ),
        MusicItem(
          id: '2',
          name: 'Song 2',
          singer: 'Artist 2',
          source: 'test',
          duration: const Duration(minutes: 4),
        ),
      ];

      final playlist = Playlist(
        id: '1',
        name: 'Test Playlist',
        songs: songs,
        createdAt: now,
        updatedAt: now,
      );

      expect(playlist.songs.length, 2);
      expect(playlist.songCount, 2);
    });

    test('should calculate total duration', () {
      final now = DateTime.now();
      final songs = [
        MusicItem(
          id: '1',
          name: 'Song 1',
          singer: 'Artist 1',
          source: 'test',
          duration: const Duration(minutes: 3),
        ),
        MusicItem(
          id: '2',
          name: 'Song 2',
          singer: 'Artist 2',
          source: 'test',
          duration: const Duration(minutes: 4),
        ),
      ];

      final playlist = Playlist(
        id: '1',
        name: 'Test Playlist',
        songs: songs,
        createdAt: now,
        updatedAt: now,
      );

      expect(playlist.totalDuration, const Duration(minutes: 7));
    });

    test('should copy Playlist with new values', () {
      final now = DateTime.now();
      final playlist = Playlist(
        id: '1',
        name: 'Test Playlist',
        createdAt: now,
        updatedAt: now,
      );

      final copied = playlist.copyWith(
        name: 'Updated Playlist',
        description: 'New description',
      );

      expect(copied.id, '1');
      expect(copied.name, 'Updated Playlist');
      expect(copied.description, 'New description');
    });
  });
}
