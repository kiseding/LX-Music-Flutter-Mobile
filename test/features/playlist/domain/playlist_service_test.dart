import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/features/player/domain/music_item.dart';
import 'package:lx_music_flutter/features/playlist/domain/playlist_service.dart';

MusicItem _song(String id) => MusicItem(
      id: id,
      name: 'Song $id',
      singer: 'Artist',
      source: 'test',
      duration: const Duration(minutes: 3),
    );

void main() {
  late PlaylistService service;

  setUp(() {
    service = PlaylistService();
  });

  test('addAllSongsToFavorites dedupes and returns added count', () {
    final source = service.createPlaylist(name: 'Imported');
    service.updatePlaylist(id: source.id, songs: [
      _song('a'),
      _song('b'),
      _song('c'),
    ]);

    // Pre-seed favorites with one of the songs to verify dedup.
    service.addSongToPlaylist('favorites', _song('a'));

    final added = service.addAllSongsToFavorites(source.id);
    expect(added, 2);
    final favorites = service.favorites!;
    expect(favorites.songs.length, 3);
    expect(favorites.songs.map((s) => s.id), containsAll(['a', 'b', 'c']));
  });

  test('addAllSongsToFavorites on missing playlist throws', () {
    expect(() => service.addAllSongsToFavorites('nope'), throwsException);
  });
}
