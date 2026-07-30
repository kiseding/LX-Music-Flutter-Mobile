import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/features/playlist/data/playlist_repository.dart';
import 'package:lx_music_flutter/features/playlist/domain/playlist.dart';
import 'package:lx_music_flutter/features/playlist/domain/playlist_service.dart';
import 'package:lx_music_flutter/features/sync/presentation/cloud_playlist_merge.dart';

void main() {
  test('cloud merge counts only accepted playlists and persists once',
      () async {
    final repository = _CountingRepository(_systemSnapshot());
    final service = PlaylistService(repository: repository);
    await service.init();

    final result = await mergeAndPersistCloudPlaylists(
      service: service,
      love: const [],
      userList: const [
        {'id': 'one', 'name': 'One', 'list': []},
      ],
      decodeSong: decodeCloudSong,
      clock: () => DateTime.utc(2026),
    );

    expect(result.acceptedPlaylistCount, 1);
    expect(repository.saveCalls, 1);
    expect(service.getPlaylist('one'), isNotNull);
  });

  test('persistence failure produces no success result', () async {
    final repository = _CountingRepository(_systemSnapshot());
    final service = PlaylistService(repository: repository);
    await service.init();
    repository.failSave = true;
    var reportedSuccess = false;

    try {
      await mergeAndPersistCloudPlaylists(
        service: service,
        love: const [],
        userList: const [
          {'id': 'one', 'name': 'One', 'list': []},
        ],
        decodeSong: decodeCloudSong,
      );
      reportedSuccess = true;
    } catch (_) {}

    expect(reportedSuccess, isFalse);
    expect(service.getPlaylist('one'), isNull);
  });

  test('one malformed favorite rejects the whole cloud replacement', () async {
    final repository = _CountingRepository(_systemSnapshot());
    final service = PlaylistService(repository: repository);
    await service.init();

    await expectLater(
      mergeAndPersistCloudPlaylists(
        service: service,
        love: const [
          {'songmid': 'ok', 'name': 'Good', 'singer': 'Singer', 'source': 'tx'},
          {'songmid': '', 'name': '', 'singer': 'Singer', 'source': 'tx'},
        ],
        userList: const [],
        decodeSong: decodeCloudSong,
      ),
      throwsFormatException,
    );

    expect(repository.saveCalls, 0);
    expect(service.favorites!.songs, isEmpty);
  });

  test('malformed song in one user playlist rejects all user playlists',
      () async {
    final repository = _CountingRepository(_systemSnapshot());
    final service = PlaylistService(repository: repository);
    await service.init();

    await expectLater(
      mergeAndPersistCloudPlaylists(
        service: service,
        love: const [],
        userList: const [
          {'id': 'good', 'name': 'Good', 'list': []},
          {
            'id': 'bad',
            'name': 'Bad',
            'list': [7]
          },
        ],
        decodeSong: decodeCloudSong,
      ),
      throwsFormatException,
    );

    expect(repository.saveCalls, 0);
    expect(service.getPlaylist('good'), isNull);
  });

  test('valid cloud favorites and playlists replace successfully', () async {
    final repository = _CountingRepository(_systemSnapshot());
    final service = PlaylistService(repository: repository);
    await service.init();

    final result = await mergeAndPersistCloudPlaylists(
      service: service,
      love: const [
        {'songmid': 'm1', 'name': 'Track', 'singer': 'Artist', 'source': 'tx'},
      ],
      userList: const [
        {
          'id': 'pl1',
          'name': 'Mine',
          'list': [
            {
              'songmid': 'm2',
              'name': 'Other',
              'singer': 'B',
              'source': 'wy',
            },
          ],
        },
      ],
      decodeSong: decodeCloudSong,
      clock: () => DateTime.utc(2026, 2),
    );

    expect(result.favoriteSongCount, 1);
    expect(result.acceptedPlaylistCount, 1);
    expect(repository.saveCalls, 1);
    expect(service.favorites!.songs.single.id, 'm1');
    expect(service.getPlaylist('pl1')!.songs.single.id, 'm2');
  });

  test('malformed user playlist structure rejects without saving', () async {
    final repository = _CountingRepository(_systemSnapshot());
    final service = PlaylistService(repository: repository);
    await service.init();

    await expectLater(
      mergeAndPersistCloudPlaylists(
        service: service,
        love: const [],
        userList: const [
          {'id': 'one', 'name': 'One', 'list': []},
          'malformed',
        ],
        decodeSong: decodeCloudSong,
      ),
      throwsFormatException,
    );

    expect(repository.saveCalls, 0);
    expect(service.getPlaylist('one'), isNull);
  });
}

PlaylistSnapshot _systemSnapshot() {
  final now = DateTime.utc(2026);
  return PlaylistSnapshot(schemaVersion: 1, playlists: [
    Playlist(
        id: 'favorites', name: 'Favorites', createdAt: now, updatedAt: now),
    Playlist(id: 'recent', name: 'Recent', createdAt: now, updatedAt: now),
  ]);
}

final class _CountingRepository implements PlaylistRepository {
  _CountingRepository(this.snapshot);

  PlaylistSnapshot snapshot;
  int saveCalls = 0;
  bool failSave = false;

  @override
  Future<PlaylistSnapshot> load() async => snapshot;

  @override
  Future<void> save(PlaylistSnapshot snapshot) async {
    saveCalls++;
    if (failSave) throw StateError('save failed');
    this.snapshot = snapshot;
  }
}
