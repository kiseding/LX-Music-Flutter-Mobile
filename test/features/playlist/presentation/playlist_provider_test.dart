import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/features/playlist/data/playlist_repository.dart';
import 'package:lx_music_flutter/features/playlist/domain/playlist.dart';
import 'package:lx_music_flutter/features/player/domain/music_item.dart';
import 'package:lx_music_flutter/features/playlist/presentation/playlist_provider.dart';

const playlistConsumerPaths = [
  'lib/features/playlist/presentation/playlist_provider.dart',
  'lib/features/playlist/presentation/playlist_screen.dart',
  'lib/features/playlist/presentation/playlist_detail_screen.dart',
  'lib/features/playlist/presentation/playlist_picker.dart',
  'lib/features/player/presentation/player_provider.dart',
  'lib/features/player/presentation/player_screen.dart',
  'lib/features/search/presentation/search_screen.dart',
  'lib/features/sync/presentation/sync_provider.dart',
  'lib/features/sync/presentation/sync_screen.dart',
  'lib/features/settings/presentation/settings_screen.dart',
];

void main() {
  test('playlist providers rebuild from the service revision stream', () async {
    final repository = MemoryPlaylistRepository(systemSnapshot());
    final container = ProviderContainer(overrides: [
      playlistRepositoryProvider.overrideWithValue(repository),
    ]);
    addTearDown(container.dispose);
    final service = container.read(playlistServiceProvider);
    await service.init();
    expect(container.read(playlistsProvider), hasLength(2));

    await service.createPlaylist(name: 'One', id: 'one');
    await Future<void>.delayed(Duration.zero);

    expect(container.read(playlistsProvider).map((p) => p.id), contains('one'));
  });

  test('production playlist consumers contain no manual version increments',
      () {
    for (final path in playlistConsumerPaths) {
      final source = File(path).readAsStringSync();
      expect(source, isNot(contains('playlistVersionProvider')), reason: path);
    }
  });

  test('favorite provider invalidates when replaceAll removes a favorite',
      () async {
    final song = MusicItem(
      id: 'song',
      name: 'Song',
      singer: 'Singer',
      source: 'tx',
    );
    final initial = systemSnapshot();
    final favorite = initial.playlists.first.copyWith(songs: [song]);
    final repository = MemoryPlaylistRepository(PlaylistSnapshot(
      schemaVersion: 1,
      playlists: [favorite, initial.playlists.last],
    ));
    final container = ProviderContainer(overrides: [
      playlistRepositoryProvider.overrideWithValue(repository),
    ]);
    addTearDown(container.dispose);
    final service = container.read(playlistServiceProvider);
    await service.init();
    final subscription = container.listen(
      isSongFavoriteProvider(song.id),
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);
    expect(subscription.read(), isTrue);

    await service.replaceAll([
      favorite.copyWith(songs: const []),
      initial.playlists.last,
    ]);
    await Future<void>.delayed(Duration.zero);

    expect(subscription.read(), isFalse);
  });
}

PlaylistSnapshot systemSnapshot() {
  final now = DateTime.utc(2026);
  return PlaylistSnapshot(schemaVersion: 1, playlists: [
    Playlist(
        id: 'favorites', name: 'Favorites', createdAt: now, updatedAt: now),
    Playlist(id: 'recent', name: 'Recent', createdAt: now, updatedAt: now),
  ]);
}

final class MemoryPlaylistRepository implements PlaylistRepository {
  MemoryPlaylistRepository(this.snapshot);

  PlaylistSnapshot snapshot;

  @override
  Future<PlaylistSnapshot> load() async => snapshot;

  @override
  Future<void> save(PlaylistSnapshot snapshot) async {
    this.snapshot = snapshot;
  }
}
