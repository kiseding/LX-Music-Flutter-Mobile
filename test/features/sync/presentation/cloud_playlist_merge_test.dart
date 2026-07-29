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
        {'id': '', 'name': 'Missing id', 'list': []},
        {'id': 'love', 'name': 'Reserved', 'list': []},
        'malformed',
      ],
      decodeSong: (_) => null,
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
        decodeSong: (_) => null,
      );
      reportedSuccess = true;
    } catch (_) {}

    expect(reportedSuccess, isFalse);
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
