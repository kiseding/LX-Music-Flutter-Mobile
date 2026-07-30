import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/features/playlist/data/playlist_repository.dart';
import 'package:lx_music_flutter/features/playlist/domain/playlist.dart';
import 'package:lx_music_flutter/features/playlist/presentation/playlist_detail_screen.dart';
import 'package:lx_music_flutter/features/playlist/presentation/playlist_provider.dart';

void main() {
  test('playlist list more menu uses center dialog and can add favorites', () {
    final source = File(
      'lib/features/playlist/presentation/playlist_screen.dart',
    ).readAsStringSync();
    final more = source.substring(
      source.indexOf('void _showPlaylistMoreMenu('),
    );

    expect(more, contains('showDialog<void>'));
    expect(more, contains('Dialog('));
    expect(more, contains('BorderRadius.circular(20)'));
    expect(more, contains('maxHeight: maxH'));
    expect(more, contains('全部添加到我喜欢的音乐'));
    expect(more, contains('await ref'));
    expect(more, contains('.addAllSongsToFavorites(playlist.id)'));
    expect(more, isNot(contains('showModalBottomSheet')));
  });

  test('playlist detail more menu does not host bulk favorites action', () {
    final source = File(
      'lib/features/playlist/presentation/playlist_detail_screen.dart',
    ).readAsStringSync();
    expect(source, isNot(contains("case 'add_all_to_favorites':")));
    expect(source, isNot(contains('全部添加到我喜欢的音乐')));
  });

  testWidgets('replaceAll removal shows missing playlist without stale actions',
      (tester) async {
    final now = DateTime.utc(2026);
    final selected = Playlist(
      id: 'selected',
      name: 'Selected',
      createdAt: now,
      updatedAt: now,
    );
    final repository = _MemoryRepository(PlaylistSnapshot(
      schemaVersion: 1,
      playlists: [
        Playlist(
            id: 'favorites', name: 'Favorites', createdAt: now, updatedAt: now),
        Playlist(id: 'recent', name: 'Recent', createdAt: now, updatedAt: now),
        selected,
      ],
    ));
    final container = ProviderContainer(overrides: [
      playlistRepositoryProvider.overrideWithValue(repository),
    ]);
    addTearDown(container.dispose);
    final service = container.read(playlistServiceProvider);
    await service.init();

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: PlaylistDetailScreen(playlistId: selected.id)),
    ));
    expect(find.textContaining('Selected'), findsOneWidget);

    await service.replaceAll(service.playlists
        .where((playlist) => playlist.id != selected.id)
        .toList());
    await tester.pump();

    expect(find.text('歌单不存在'), findsOneWidget);
    expect(find.byIcon(Icons.more_vert), findsNothing);
  });
}

final class _MemoryRepository implements PlaylistRepository {
  _MemoryRepository(this.snapshot);

  PlaylistSnapshot snapshot;

  @override
  Future<PlaylistSnapshot> load() async => snapshot;

  @override
  Future<void> save(PlaylistSnapshot snapshot) async {
    this.snapshot = snapshot;
  }
}
