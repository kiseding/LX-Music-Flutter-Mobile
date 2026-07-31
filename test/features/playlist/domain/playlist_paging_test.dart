import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/features/player/domain/music_item.dart';
import 'package:lx_music_flutter/features/playlist/data/playlist_repository.dart';
import 'package:lx_music_flutter/features/playlist/domain/playlist.dart';
import 'package:lx_music_flutter/features/playlist/domain/playlist_service.dart';

void main() {
  test('loads only the requested playlist page from a paged repository',
      () async {
    final songs = List.generate(250, _song);
    final repository = _PagedRepository(songs);
    final service = PlaylistService(repository: repository);
    await service.init();

    final page = await service.getSongsPage('long', offset: 100, limit: 100);

    expect(page.total, 250);
    expect(page.offset, 100);
    expect(page.songs.map((song) => song.id),
        List.generate(100, (index) => '${index + 100}'));
    expect(repository.pageRequests, [(offset: 100, limit: 100)]);
    await service.dispose();
  });
}

MusicItem _song(int index) => MusicItem(
      id: '$index',
      name: 'Song $index',
      singer: 'Singer',
      source: 'test',
    );

final class _PagedRepository
    implements PlaylistRepository, PlaylistSongPageRepository {
  _PagedRepository(this.songs);

  final List<MusicItem> songs;
  final List<({int offset, int limit})> pageRequests = [];

  @override
  Future<PlaylistSnapshot> load() async {
    final now = DateTime.utc(2026);
    return PlaylistSnapshot(
      schemaVersion: 1,
      playlists: [
        Playlist(
          id: 'long',
          name: 'Long',
          songs: const [],
          songCount: songs.length,
          createdAt: now,
          updatedAt: now,
        ),
      ],
    );
  }

  @override
  Future<PlaylistSongPage> loadSongsPage(
    String playlistId, {
    required int offset,
    required int limit,
  }) async {
    pageRequests.add((offset: offset, limit: limit));
    return PlaylistSongPage(
      total: songs.length,
      offset: offset,
      songs:
          songs.sublist(offset, (offset + limit).clamp(0, songs.length).toInt()),
    );
  }

  @override
  Future<List<MusicItem>> loadAllSongs(String playlistId) async => songs;

  @override
  Future<void> save(PlaylistSnapshot snapshot) async {}
}
