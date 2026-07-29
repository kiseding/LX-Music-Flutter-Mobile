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

MusicItem detailedSong(
  String id, {
  String? name,
  Map<String, dynamic>? meta,
}) =>
    MusicItem(
      id: id,
      name: name ?? 'Song $id',
      singer: 'Artist $id',
      album: 'Album $id',
      duration: Duration(seconds: id.length),
      source: 'test',
      platform: 'wy',
      artwork: 'https://example.com/$id.jpg',
      url: 'https://example.com/$id.mp3',
      lyricsUrl: 'https://example.com/$id.lrc',
      songmid: 'mid-$id',
      hash: 'hash-$id',
      meta: meta,
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

  test('init rejects empty and duplicate loaded ids without publication',
      () async {
    for (final invalid in [
      [playlist(''), playlist('favorites'), playlist('recent')],
      [playlist('favorites'), playlist('favorites'), playlist('recent')],
    ]) {
      final repository = MemoryPlaylistRepository(PlaylistSnapshot(
        schemaVersion: 1,
        playlists: invalid,
      ));
      final service = PlaylistService(repository: repository);

      await expectLater(service.init(), throwsStateError);

      expect(repository.saves, isEmpty);
      expect(service.playlists, isEmpty);
      expect(service.revision, 0);
      await service.dispose();
    }
  });

  test('create rejects explicit, generated, and protected id collisions',
      () async {
    final repository = MemoryPlaylistRepository(systemSnapshot(additional: [
      playlist('custom'),
    ]));
    final generatedIds = ['', 'custom', 'favorites'].iterator;
    final service = PlaylistService(
      repository: repository,
      createId: () {
        generatedIds.moveNext();
        return generatedIds.current;
      },
    );
    await service.init();

    for (final id in ['', 'custom', 'favorites', 'recent']) {
      await expectLater(
        service.createPlaylist(name: 'Rejected', id: id),
        throwsArgumentError,
      );
    }
    for (var index = 0; index < 3; index++) {
      await expectLater(
        service.createPlaylist(name: 'Rejected'),
        throwsArgumentError,
      );
    }

    expect(repository.saves, isEmpty);
    expect(service.revision, 0);
    await service.dispose();
  });

  test('replaceAll rejects duplicate ids without save or revision', () async {
    final repository = MemoryPlaylistRepository(systemSnapshot());
    final service = PlaylistService(repository: repository);
    await service.init();

    await expectLater(
      service.replaceAll([playlist('same'), playlist('same')]),
      throwsArgumentError,
    );

    expect(repository.saves, isEmpty);
    expect(service.revision, 0);
    await service.dispose();
  });

  test('updatePlaylist persists same-id song content and nested meta changes',
      () async {
    final original = detailedSong('a', meta: {
      'quality': {'bitrate': 128},
    });
    final refreshed = detailedSong('a', meta: {
      'quality': {'bitrate': 320},
    });
    final repository = MemoryPlaylistRepository(systemSnapshot(additional: [
      playlist('custom', songs: [original]),
    ]));
    final service = PlaylistService(repository: repository, clock: () => _now);
    await service.init();

    final updated =
        await service.updatePlaylist(id: 'custom', songs: [refreshed]);

    expect(updated.songs.single.meta, refreshed.meta);
    expect(repository.saves, hasLength(1));
    expect(service.revision, 1);
    await service.dispose();
  });

  test('equivalent replaceAll is a deep semantic no-op', () async {
    final initial = systemSnapshot(additional: [
      playlist('custom', songs: [
        detailedSong('a', meta: {
          'nested': [
            {'value': 1}
          ],
        }),
      ]),
    ]);
    final repository = MemoryPlaylistRepository(initial);
    final service = PlaylistService(repository: repository);
    await service.init();
    final equivalent = initial.playlists
        .map((item) => item.copyWith(
              songs: item.songs
                  .map((track) => MusicItem.fromJson(track.toJson()))
                  .toList(),
            ))
        .toList();

    await service.replaceAll(equivalent);

    expect(repository.saves, isEmpty);
    expect(service.revision, 0);
    await service.dispose();
  });

  test('dispose waits for an accepted mutation to save and publish', () async {
    final repository = ControlledPlaylistRepository(initial: systemSnapshot());
    final service = PlaylistService(
      repository: repository,
      createId: () => 'queued',
    );
    await service.init();
    final revisions = <int>[];
    final subscription = service.revisions.listen(revisions.add);

    final mutation = service.createPlaylist(name: 'Queued');
    await repository.waitForSaveCount(1);
    final disposal = service.dispose();
    var disposed = false;
    disposal.then((_) => disposed = true);
    await Future<void>.delayed(Duration.zero);
    expect(disposed, isFalse);

    repository.completeSave();
    await mutation;
    await disposal;

    expect(service.getPlaylist('queued'), isNotNull);
    expect(service.revision, 1);
    expect(revisions, [1]);
    await subscription.cancel();
  });

  test('mutations invoked after disposal starts are rejected without save',
      () async {
    final repository = MemoryPlaylistRepository(systemSnapshot());
    final service = PlaylistService(repository: repository);
    await service.init();

    final disposal = service.dispose();
    await expectLater(
      service.createPlaylist(name: 'Too late', id: 'late'),
      throwsStateError,
    );
    await disposal;

    expect(repository.saves, isEmpty);
    expect(service.revision, 0);
  });

  test('concurrent init coalesces repair and retries after load failure',
      () async {
    final repository = RetryLoadPlaylistRepository(PlaylistSnapshot(
      schemaVersion: 1,
      playlists: [playlist('custom')],
    ));
    final service = PlaylistService(repository: repository, clock: () => _now);

    final failedFirst = service.init();
    final failedSecond = service.init();
    repository.failLoad(StateError('temporary load failure'));
    await expectLater(failedFirst, throwsStateError);
    await expectLater(failedSecond, throwsStateError);
    expect(repository.loadCount, 1);

    final first = service.init();
    final second = service.init();
    repository.completeLoad();
    await Future.wait([first, second]);

    expect(repository.loadCount, 2);
    expect(repository.saves, hasLength(1));
    expect(service.revision, 1);
    expect(service.playlists.map((item) => item.id),
        containsAll(['custom', 'favorites', 'recent']));
    await service.dispose();
  });

  test('addToRecent refreshes same-id content but exact repeats are no-ops',
      () async {
    final original = detailedSong('a', name: 'Old', meta: {'version': 1});
    final refreshed = detailedSong('a', name: 'New', meta: {'version': 2});
    final repository = MemoryPlaylistRepository(PlaylistSnapshot(
      schemaVersion: 1,
      playlists: [
        playlist('favorites'),
        playlist('recent', songs: [original]),
      ],
    ));
    final service = PlaylistService(repository: repository, clock: () => _now);
    await service.init();

    expect(await service.addToRecent(refreshed), isTrue);
    expect(service.recent!.songs.single.name, 'New');
    expect(service.recent!.songs.single.meta, {'version': 2});
    expect(await service.addToRecent(refreshed), isFalse);

    expect(repository.saves, hasLength(1));
    expect(service.revision, 1);
    await service.dispose();
  });

  test('successful removal, reorder, sorts, and deletion publish timestamps',
      () async {
    final firstUpdate = _now.add(const Duration(minutes: 1));
    final secondUpdate = _now.add(const Duration(minutes: 2));
    final thirdUpdate = _now.add(const Duration(minutes: 3));
    final fourthUpdate = _now.add(const Duration(minutes: 4));
    final times =
        [firstUpdate, secondUpdate, thirdUpdate, fourthUpdate].iterator;
    final repository = MemoryPlaylistRepository(systemSnapshot(additional: [
      playlist('custom', songs: [
        MusicItem(
          id: 'long-z',
          name: 'Z',
          singer: 'C',
          source: 'test',
          duration: const Duration(seconds: 30),
        ),
        MusicItem(
          id: 'short-a',
          name: 'A',
          singer: 'A',
          source: 'test',
          duration: const Duration(seconds: 10),
        ),
        MusicItem(
          id: 'medium-b',
          name: 'B',
          singer: 'B',
          source: 'test',
          duration: const Duration(seconds: 20),
        ),
      ]),
      playlist('delete-me'),
    ]));
    final service = PlaylistService(
      repository: repository,
      clock: () {
        times.moveNext();
        return times.current;
      },
    );
    await service.init();

    expect(await service.removeSongFromPlaylist('custom', 'medium-b'), isTrue);
    expect(service.getPlaylist('custom')!.updatedAt, firstUpdate);
    expect(
      await service.sortSongsInPlaylist('custom', oldIndex: 0, newIndex: 2),
      isTrue,
    );
    expect(service.getPlaylist('custom')!.updatedAt, secondUpdate);
    expect(await service.sortSongsByArtist('custom', ascending: false), isTrue);
    expect(service.getPlaylist('custom')!.updatedAt, thirdUpdate);
    expect(await service.sortSongsByDuration('custom'), isTrue);
    expect(service.getPlaylist('custom')!.updatedAt, fourthUpdate);
    expect(await service.deletePlaylist('delete-me'), isTrue);

    expect(service.getPlaylist('custom')!.songs.map((item) => item.id),
        ['short-a', 'long-z']);
    expect(service.getPlaylist('delete-me'), isNull);
    expect(repository.saves, hasLength(5));
    expect(service.revision, 5);
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

final class RetryLoadPlaylistRepository implements PlaylistRepository {
  RetryLoadPlaylistRepository(this.snapshot);

  final PlaylistSnapshot snapshot;
  final List<PlaylistSnapshot> saves = [];
  Completer<PlaylistSnapshot> _load = Completer<PlaylistSnapshot>();
  int loadCount = 0;

  @override
  Future<PlaylistSnapshot> load() {
    loadCount++;
    return _load.future;
  }

  void failLoad(Object error) {
    _load.completeError(error);
    _load = Completer<PlaylistSnapshot>();
  }

  void completeLoad() => _load.complete(snapshot);

  @override
  Future<void> save(PlaylistSnapshot value) async => saves.add(value);
}
