import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lx_music_flutter/features/player/domain/music_item.dart';
import 'package:lx_music_flutter/features/playlist/data/playlist_repository.dart';
import 'package:lx_music_flutter/features/playlist/domain/playlist.dart';
import 'package:lx_music_flutter/features/playlist/presentation/playlist_detail_screen.dart';
import 'package:lx_music_flutter/features/playlist/presentation/playlist_occurrence.dart';
import 'package:lx_music_flutter/features/playlist/presentation/playlist_provider.dart';

void main() {
  test('duplicate songs receive stable occurrence keys across reorder', () {
    final song = MusicItem(id: 'same', name: 'Song', singer: 'A', source: 'tx');
    final occurrences = buildPlaylistOccurrences('list', [song, song]);
    final second = occurrences.removeAt(1);
    occurrences.insert(0, second);

    expect(occurrences.map((entry) => entry.key), [
      'list:same:1',
      'list:same:0',
    ]);
  });

  testWidgets('playlist deep link resolves current repository value',
      (tester) async {
    final now = DateTime.utc(2026);
    final repository = _Repository(PlaylistSnapshot(
      schemaVersion: 1,
      playlists: [
        Playlist(id: 'deep', name: 'Deep', createdAt: now, updatedAt: now)
      ],
    ));
    final router = GoRouter(
      initialLocation: '/playlist/detail/deep',
      routes: [
        GoRoute(
          path: '/playlist/detail/:playlistId',
          builder: (_, state) => PlaylistDetailScreen(
            playlistId: state.pathParameters['playlistId']!,
          ),
        ),
      ],
    );
    final container = ProviderContainer(overrides: [
      playlistRepositoryProvider.overrideWithValue(repository),
    ]);
    addTearDown(container.dispose);
    await container.read(playlistServiceProvider).init();

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('Deep'), findsOneWidget);
  });
}

class _Repository implements PlaylistRepository {
  _Repository(this.snapshot);
  PlaylistSnapshot snapshot;
  @override
  Future<PlaylistSnapshot> load() async => snapshot;
  @override
  Future<void> save(PlaylistSnapshot value) async => snapshot = value;
}
