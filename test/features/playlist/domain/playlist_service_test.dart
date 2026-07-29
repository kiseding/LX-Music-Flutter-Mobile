import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/features/player/domain/music_item.dart';
import 'package:lx_music_flutter/features/playlist/data/playlist_repository.dart';
import 'package:lx_music_flutter/features/playlist/domain/playlist.dart';
import 'package:lx_music_flutter/features/playlist/domain/playlist_service.dart';

final _now = DateTime.fromMillisecondsSinceEpoch(1785283200000, isUtc: true);

MusicItem song(String id) => MusicItem(
      id: id,
      name: 'Song $id',
      singer: 'Artist $id',
      source: 'test',
      duration: Duration(seconds: id.length),
    );

Playlist playlist(
  String id, {
  String? name,
  List<MusicItem> songs = const [],
}) {
  return Playlist(
    id: id,
    name: name ?? 'Playlist $id',
    songs: songs,
    createdAt: _now,
    updatedAt: _now,
  );
}

PlaylistSnapshot systemSnapshot({List<Playlist> additional = const []}) {
  return PlaylistSnapshot(
    schemaVersion: 1,
    playlists: [
      playlist('favorites', name: 'Favorites'),
      playlist('recent', name: 'Recent'),
      ...additional,
    ],
  );
}

void main() {
  test('successful mutation writes before publishing exactly one revision',
      () async {
    final repository = ControlledPlaylistRepository(initial: systemSnapshot());
    final service =
        PlaylistService(repository: repository, createId: () => 'new');
    await service.init();
    final revisions = <int>[];
    final subscription = service.revisions.listen(revisions.add);

    final future = service.createPlaylist(name: 'Road trip');
    await repository.waitForSaveCount(1);
    expect(service.getPlaylist('new'), isNull);
    expect(revisions, isEmpty);

    repository.completeSave();
    final created = await future;

    expect(created.id, 'new');
    expect(service.getPlaylist('new'), isNotNull);
    expect(revisions, [1]);
    await subscription.cancel();
    await service.dispose();
  });

  test('failed, protected, and no-op mutations emit no revision', () async {
    final repository = ControlledPlaylistRepository(initial: systemSnapshot());
    final service =
        PlaylistService(repository: repository, createId: () => 'failed');
    await service.init();
    final revisions = <int>[];
    final subscription = service.revisions.listen(revisions.add);

    await expectLater(service.deletePlaylist('favorites'), throwsStateError);

    final failed = service.createPlaylist(name: 'Will fail');
    await repository.waitForSaveCount(1);
    repository.failSave(StateError('disk full'));
    await expectLater(failed, throwsStateError);
    expect(service.getPlaylist('failed'), isNull);

    final added = service.addSongToPlaylist('favorites', song('a'));
    await repository.waitForSaveCount(2);
    repository.completeSave();
    expect(await added, isTrue);
    expect(await service.addSongToPlaylist('favorites', song('a')), isFalse);

    expect(repository.saves, hasLength(2));
    expect(revisions, [1]);
    expect(service.revision, 1);
    await subscription.cancel();
    await service.dispose();
  });

  test('concurrent mutations preserve invocation order', () async {
    final ids = ['first', 'second'].iterator;
    final repository = ControlledPlaylistRepository(initial: systemSnapshot());
    final service = PlaylistService(
      repository: repository,
      createId: () {
        ids.moveNext();
        return ids.current;
      },
    );
    await service.init();

    final first = service.createPlaylist(name: 'First');
    final second = service.createPlaylist(name: 'Second');
    await repository.waitForSaveCount(1);
    expect(repository.saves.single.playlists.map((item) => item.id),
        isNot(contains('second')));

    repository.completeSave();
    await first;
    await repository.waitForSaveCount(2);
    expect(
      repository.saves.last.playlists.map((item) => item.id),
      containsAllInOrder(['first', 'second']),
    );

    repository.completeSave();
    await second;
    expect(service.playlists.map((item) => item.id),
        containsAllInOrder(['first', 'second']));
    expect(service.revision, 2);
    await service.dispose();
  });

  test('init restores missing system playlists with one durable revision',
      () async {
    final repository = ControlledPlaylistRepository(
      initial: PlaylistSnapshot(
        schemaVersion: 1,
        playlists: [playlist('custom')],
      ),
    );
    final service = PlaylistService(repository: repository, clock: () => _now);
    final revisions = <int>[];
    final subscription = service.revisions.listen(revisions.add);

    final init = service.init();
    await repository.waitForSaveCount(1);
    expect(service.playlists, isEmpty);
    expect(repository.saves.single.playlists.map((item) => item.id),
        containsAll(['custom', 'favorites', 'recent']));
    expect(revisions, isEmpty);

    repository.completeSave();
    await init;
    expect(service.playlists.map((item) => item.id),
        containsAll(['custom', 'favorites', 'recent']));
    expect(revisions, [1]);
    await subscription.cancel();
    await service.dispose();
  });

  test('init of a valid snapshot performs no save or revision', () async {
    final repository = MemoryPlaylistRepository(systemSnapshot());
    final service = PlaylistService(repository: repository);
    final revisions = <int>[];
    final subscription = service.revisions.listen(revisions.add);

    await service.init();

    expect(repository.saves, isEmpty);
    expect(service.revision, 0);
    expect(revisions, isEmpty);
    await subscription.cancel();
    await service.dispose();
  });

  test('recent is durably capped at 100 songs in newest-first order', () async {
    final oldSongs = [for (var index = 0; index < 100; index++) song('$index')];
    final repository = MemoryPlaylistRepository(PlaylistSnapshot(
      schemaVersion: 1,
      playlists: [
        playlist('favorites'),
        playlist('recent', songs: oldSongs),
      ],
    ));
    final service = PlaylistService(repository: repository, clock: () => _now);
    await service.init();

    expect(await service.addToRecent(song('new')), isTrue);

    expect(service.recent!.songs, hasLength(100));
    expect(service.recent!.songs.first.id, 'new');
    expect(service.recent!.songs.map((item) => item.id), isNot(contains('99')));
    expect(
        repository.saves.single.playlists
            .firstWhere((item) => item.id == 'recent')
            .songs
            .first
            .id,
        'new');
    await service.dispose();
  });

  test('replaceAll repairs system lists before one save and revision',
      () async {
    final repository = ControlledPlaylistRepository(initial: systemSnapshot());
    final service = PlaylistService(repository: repository, clock: () => _now);
    await service.init();
    final revisions = <int>[];
    final subscription = service.revisions.listen(revisions.add);

    final replace = service.replaceAll([playlist('imported')]);
    await repository.waitForSaveCount(1);
    expect(repository.saves.single.playlists.map((item) => item.id),
        containsAll(['imported', 'favorites', 'recent']));
    expect(service.getPlaylist('imported'), isNull);

    repository.completeSave();
    await replace;
    expect(service.playlists.map((item) => item.id),
        containsAll(['imported', 'favorites', 'recent']));
    expect(revisions, [1]);
    await subscription.cancel();
    await service.dispose();
  });

  test('playlist mutations report durable changes and no-ops', () async {
    final repository = MemoryPlaylistRepository(systemSnapshot(additional: [
      playlist('source', songs: [song('b'), song('a')]),
    ]));
    final service = PlaylistService(repository: repository, clock: () => _now);
    await service.init();

    expect(await service.addAllSongsToFavorites('source'), 2);
    expect(await service.addAllSongsToFavorites('source'), 0);
    expect(await service.removeSongFromPlaylist('source', 'missing'), isFalse);
    expect(await service.sortSongsByName('source'), isTrue);
    expect(await service.sortSongsByName('source'), isFalse);
    expect(await service.deletePlaylist('missing'), isFalse);
    expect(service.revision, 2);
    expect(repository.saves, hasLength(2));
    await service.dispose();
  });
}

final class ControlledPlaylistRepository implements PlaylistRepository {
  ControlledPlaylistRepository({required PlaylistSnapshot initial})
      : _initial = initial;

  final PlaylistSnapshot _initial;
  final List<PlaylistSnapshot> saves = [];
  final List<Completer<void>> _pending = [];
  Completer<void>? _saveObserved;

  @override
  Future<PlaylistSnapshot> load() async => _initial;

  @override
  Future<void> save(PlaylistSnapshot snapshot) {
    saves.add(snapshot);
    final pending = Completer<void>();
    _pending.add(pending);
    _saveObserved?.complete();
    _saveObserved = null;
    return pending.future;
  }

  Future<void> waitForSaveCount(int count) async {
    while (saves.length < count) {
      _saveObserved ??= Completer<void>();
      await _saveObserved!.future;
    }
  }

  void completeSave() => _pending.removeAt(0).complete();

  void failSave(Object error) => _pending.removeAt(0).completeError(error);
}

final class MemoryPlaylistRepository implements PlaylistRepository {
  MemoryPlaylistRepository(this.snapshot);

  PlaylistSnapshot snapshot;
  final List<PlaylistSnapshot> saves = [];

  @override
  Future<PlaylistSnapshot> load() async => snapshot;

  @override
  Future<void> save(PlaylistSnapshot value) async {
    saves.add(value);
    snapshot = value;
  }
}
