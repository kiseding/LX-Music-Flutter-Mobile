import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/features/playlist/data/file_playlist_repository.dart';
import 'package:lx_music_flutter/features/playlist/data/playlist_repository.dart';
import 'package:lx_music_flutter/features/playlist/domain/playlist.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir =
        await Directory.systemTemp.createTemp('playlist_repository_test_');
  });
  tearDown(() => tempDir.delete(recursive: true));

  test('legacy migration keeps fallback until new file loads successfully',
      () async {
    final prefs = await preferences({'playlists': jsonEncode(legacyPlaylists)});
    final repository = repositoryFor(tempDir, prefs);

    final migrated = await repository.load();

    expect(migrated.playlists, isNotEmpty);
    expect(prefs.containsKey('playlists'), isTrue);
    expect(File('${tempDir.path}/playlists.v1.recovery.json').existsSync(),
        isTrue);

    final reloaded = await repository.load();

    expect(reloaded.playlists, isNotEmpty);
    expect(prefs.containsKey('playlists'), isFalse);
    expect(File('${tempDir.path}/playlists.v1.recovery.json').existsSync(),
        isFalse);
  });

  test('corrupt current file is quarantined and restored from recovery',
      () async {
    final snapshot = snapshotFixture();
    await writeValidRecovery(tempDir, snapshot);
    await File('${tempDir.path}/playlists.v1.json').writeAsString('{broken');

    final loaded = await repositoryFor(tempDir, await preferences({})).load();

    expect(loaded.playlists.single.id, 'favorites');
    expect(tempDir.listSync().where((file) => file.path.contains('.corrupt.')),
        hasLength(1));
    expect(
      () => const PlaylistSnapshotCodec().decode(
        File('${tempDir.path}/playlists.v1.json').readAsStringSync(),
      ),
      returnsNormally,
    );
  });

  test('previous snapshot is restored after an interrupted replacement',
      () async {
    final previous = snapshotFixture(id: 'previous');
    await File('${tempDir.path}/playlists.v1.previous')
        .writeAsString(const PlaylistSnapshotCodec().encode(previous));

    final loaded = await repositoryFor(tempDir, await preferences({})).load();

    expect(loaded.playlists.single.id, 'previous');
    expect(
      const PlaylistSnapshotCodec()
          .decode(
            await File('${tempDir.path}/playlists.v1.json').readAsString(),
          )
          .playlists
          .single
          .id,
      'previous',
    );
  });

  test('validated current takes precedence and completes migration cleanup',
      () async {
    final current = snapshotFixture(id: 'current');
    final recovery = snapshotFixture(id: 'recovery');
    final prefs = await preferences({'playlists': jsonEncode(legacyPlaylists)});
    final codec = const PlaylistSnapshotCodec();
    await File('${tempDir.path}/playlists.v1.json')
        .writeAsString(codec.encode(current));
    await File('${tempDir.path}/playlists.v1.recovery.json')
        .writeAsString(codec.encode(recovery));

    final loaded = await repositoryFor(tempDir, prefs).load();

    expect(loaded.playlists.single.id, 'current');
    expect(prefs.containsKey('playlists'), isFalse);
    expect(File('${tempDir.path}/playlists.v1.recovery.json').existsSync(),
        isFalse);
  });

  test('recovery restore retains fallbacks until a later current reload',
      () async {
    final recovery = snapshotFixture();
    final prefs = await preferences({'playlists': jsonEncode(legacyPlaylists)});
    await writeValidRecovery(tempDir, recovery);
    final repository = repositoryFor(tempDir, prefs);

    await repository.load();

    expect(prefs.containsKey('playlists'), isTrue);
    expect(File('${tempDir.path}/playlists.v1.recovery.json').existsSync(),
        isTrue);
  });

  test('malformed legacy data remains untouched', () async {
    final prefs = await preferences({'playlists': '{broken'});

    final loaded = await repositoryFor(tempDir, prefs).load();

    expect(loaded.playlists, isEmpty);
    expect(prefs.getString('playlists'), '{broken');
  });

  test('failed temporary write leaves the current file readable', () async {
    final existing = snapshotFixture(id: 'existing');
    final next = snapshotFixture(id: 'next');
    final codec = const PlaylistSnapshotCodec();
    await File('${tempDir.path}/playlists.v1.json')
        .writeAsString(codec.encode(existing));
    final repository = repositoryFor(
      tempDir,
      await preferences({}),
      fileSystem: FailingTemporaryWriteFileSystem(),
    );

    await expectLater(
        repository.save(next), throwsA(isA<FileSystemException>()));

    expect(
        codec
            .decode(
                await File('${tempDir.path}/playlists.v1.json').readAsString())
            .playlists
            .single
            .id,
        'existing');
  });

  test('failed replacement rolls back the current snapshot from previous',
      () async {
    final existing = snapshotFixture(id: 'existing');
    final codec = const PlaylistSnapshotCodec();
    await File('${tempDir.path}/playlists.v1.json')
        .writeAsString(codec.encode(existing));
    final repository = repositoryFor(
      tempDir,
      await preferences({}),
      fileSystem: FailingRenameFileSystem(),
    );

    await expectLater(repository.save(snapshotFixture(id: 'next')),
        throwsA(isA<FileSystemException>()));

    expect(
        codec
            .decode(
                await File('${tempDir.path}/playlists.v1.json').readAsString())
            .playlists
            .single
            .id,
        'existing');
  });

  test('save durably flushes and closes previous before replacing current',
      () async {
    final codec = const PlaylistSnapshotCodec();
    await File('${tempDir.path}/playlists.v1.json')
        .writeAsString(codec.encode(snapshotFixture(id: 'existing')));
    final fileSystem = RecordingDurabilityFileSystem();
    final repository = repositoryFor(
      tempDir,
      await preferences({}),
      fileSystem: fileSystem,
    );

    await repository.save(snapshotFixture(id: 'next'));

    expect(fileSystem.events, [
      'copy previous',
      'flush and close previous',
      'replace current',
    ]);
  });
}

FilePlaylistRepository repositoryFor(
  Directory directory,
  SharedPreferences preferences, {
  PlaylistFileSystem? fileSystem,
}) {
  return FilePlaylistRepository(
    directory: () async => directory,
    preferences: preferences,
    clock: () => DateTime.utc(2026, 7, 29),
    fileSystem: fileSystem,
  );
}

Future<SharedPreferences> preferences(Map<String, Object> values) async {
  SharedPreferences.setMockInitialValues(values);
  return SharedPreferences.getInstance();
}

Future<void> writeValidRecovery(
    Directory directory, PlaylistSnapshot snapshot) {
  return File('${directory.path}/playlists.v1.recovery.json')
      .writeAsString(const PlaylistSnapshotCodec().encode(snapshot));
}

PlaylistSnapshot snapshotFixture({String id = 'favorites'}) {
  final time = DateTime.utc(2026, 7, 29);
  return PlaylistSnapshot(
    schemaVersion: 1,
    playlists: [
      Playlist(
        id: id,
        name: 'Favorites',
        songs: const [],
        createdAt: time,
        updatedAt: time,
      ),
    ],
  );
}

final legacyPlaylists = [
  {
    'id': 'favorites',
    'name': 'Favorites',
    'description': null,
    'coverUrl': null,
    'songs': [],
    'createdAt': 1785283200000,
    'updatedAt': 1785283200000,
  },
];

final class FailingTemporaryWriteFileSystem extends PlaylistFileSystem {
  @override
  Future<void> write(String path, String contents, {bool flush = false}) {
    if (path.endsWith('playlists.v1.tmp')) {
      throw FileSystemException('temporary write failed', path);
    }
    return super.write(path, contents, flush: flush);
  }
}

final class FailingRenameFileSystem extends PlaylistFileSystem {
  @override
  Future<void> rename(String from, String to) {
    if (from.endsWith('playlists.v1.tmp')) {
      throw FileSystemException('replacement failed', from);
    }
    return super.rename(from, to);
  }
}

final class RecordingDurabilityFileSystem extends PlaylistFileSystem {
  final events = <String>[];

  @override
  Future<void> copy(String from, String to) async {
    await super.copy(from, to);
    if (to.endsWith('playlists.v1.previous')) {
      events.add('copy previous');
    }
  }

  @override
  Future<void> flushAndClose(String path) async {
    await super.flushAndClose(path);
    if (path.endsWith('playlists.v1.previous')) {
      events.add('flush and close previous');
    }
  }

  @override
  Future<void> rename(String from, String to) async {
    if (from.endsWith('playlists.v1.tmp') && to.endsWith('playlists.v1.json')) {
      events.add('replace current');
    }
    await super.rename(from, to);
  }
}
