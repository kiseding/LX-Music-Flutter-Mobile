import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/io/bounded_input.dart';
import 'package:lx_music_flutter/core/storage/storage_service.dart';
import 'package:lx_music_flutter/features/playlist/data/playlist_repository.dart';
import 'package:lx_music_flutter/features/playlist/domain/playlist.dart';
import 'package:lx_music_flutter/features/playlist/domain/playlist_service.dart';
import 'package:lx_music_flutter/features/settings/domain/playlist_backup.dart';
import 'package:lx_music_flutter/features/settings/presentation/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'failed setting write restores preferences and never publishes live state',
    () async {
      SharedPreferences.setMockInitialValues({
        'theme_mode': ThemeMode.light.index,
      });
      final prefs = await SharedPreferences.getInstance();
      var failAudioOnce = true;
      final storage = StorageService.forTesting(
        prefs,
        writeOverride: (operation, key, value) async {
          if (key == 'audio_quality' && failAudioOnce) {
            failAudioOnce = false;
            return false;
          }
          return switch ((operation, value)) {
            ('setInt', int value) => prefs.setInt(key, value),
            ('setBool', bool value) => prefs.setBool(key, value),
            ('setStringList', List<String> value) => prefs.setStringList(
                key,
                value,
              ),
            ('setString', String value) => prefs.setString(key, value),
            ('remove', _) => prefs.remove(key),
            _ => throw StateError('unexpected write: $operation $key'),
          };
        },
      );
      final repository = _MemoryRepository(_systemSnapshot());
      final playlists = PlaylistService(repository: repository);
      await playlists.init();
      var publications = 0;
      final coordinator = BackupRestoreCoordinator(
        storage: storage,
        playlists: playlists,
        publishCommitted: (_) => publications++,
      );

      await expectLater(
        coordinator.restore(_backupData()),
        throwsA(isA<StorageWriteException>()),
      );

      expect(storage.getInt('theme_mode'), ThemeMode.light.index);
      expect(repository.saves, isEmpty);
      expect(publications, 0);
    },
  );

  test('playlist save failure compensates playlists and preferences', () async {
    SharedPreferences.setMockInitialValues({
      'theme_mode': ThemeMode.light.index,
    });
    final storage = StorageService.forTesting(
      await SharedPreferences.getInstance(),
    );
    final repository = _FailOnceAfterReplaceRepository(_systemSnapshot());
    final playlists = PlaylistService(repository: repository);
    await playlists.init();
    var publications = 0;
    final coordinator = BackupRestoreCoordinator(
      storage: storage,
      playlists: playlists,
      publishCommitted: (_) => publications++,
    );

    await expectLater(coordinator.restore(_backupData()), throwsStateError);

    expect(storage.getInt('theme_mode'), ThemeMode.light.index);
    expect(repository.saves, hasLength(2));
    expect(
      repository.snapshot.playlists.map((playlist) => playlist.id),
      _systemSnapshot().playlists.map((playlist) => playlist.id),
    );
    expect(
      playlists.playlists.map((playlist) => playlist.id),
      _systemSnapshot().playlists.map((playlist) => playlist.id),
    );
    expect(publications, 0);
  });

  test(
    'successful restore writes settings then playlists and publishes once',
    () async {
      SharedPreferences.setMockInitialValues({
        'theme_mode': ThemeMode.light.index,
      });
      final storage = StorageService.forTesting(
        await SharedPreferences.getInstance(),
      );
      final repository = _MemoryRepository(_systemSnapshot());
      final playlists = PlaylistService(repository: repository);
      await playlists.init();
      BackupData? published;
      final coordinator = BackupRestoreCoordinator(
        storage: storage,
        playlists: playlists,
        publishCommitted: (data) => published = data,
      );

      final backup = _backupData();
      await coordinator.restore(backup);

      expect(storage.getInt('theme_mode'), ThemeMode.dark.index);
      expect(
        storage.getInt('audio_quality'),
        AudioQualityOption.lossless.index,
      );
      expect(storage.getInt('download_quality'), AudioQualityOption.high.index);
      expect(storage.getBool('wifi_only_download'), isFalse);
      expect(storage.getBool('auto_resume_playback'), isTrue);
      expect(storage.getString('default_search_platform'), 'wy');
      expect(storage.getStringList('search_history'), ['query-one']);
      expect(
        playlists.playlists.map((playlist) => playlist.id),
        containsAll(['favorites', 'recent', 'imported']),
      );
      expect(published, same(backup));
    },
  );

  test('decodeBackup rejects unknown keys and oversized history', () {
    final now = DateTime.utc(2026);
    final playlist = Playlist(
      id: 'one',
      name: 'One',
      createdAt: now,
      updatedAt: now,
    );
    final snapshot = jsonLikeSnapshot([playlist]);
    final history = List.generate(21, (index) => '"q$index"').join(',');

    expect(
      () => decodeBackup('{"version":1,"playlists":$snapshot,"extra":true}'),
      throwsFormatException,
    );
    expect(
      () => decodeBackup(
        '{"version":1,"playlists":$snapshot,"search_history":[$history]}',
      ),
      throwsA(anyOf(isA<FormatException>(), isA<InputLimitException>())),
    );
  });
}

BackupData _backupData() {
  final now = DateTime.utc(2026, 1, 2);
  return BackupData(
    version: 1,
    timestamp: now.toIso8601String(),
    playlists: [
      Playlist(
        id: 'imported',
        name: 'Imported',
        createdAt: now,
        updatedAt: now,
      ),
    ],
    searchHistory: const ['query-one'],
    themeMode: ThemeMode.dark,
    audioQuality: AudioQualityOption.lossless,
    downloadQuality: AudioQualityOption.high,
    wifiOnlyDownload: false,
    autoResumePlayback: true,
    defaultSearchPlatform: 'wy',
  );
}

PlaylistSnapshot _systemSnapshot() {
  final now = DateTime.utc(2026);
  return PlaylistSnapshot(
    schemaVersion: 1,
    playlists: [
      Playlist(
        id: 'favorites',
        name: 'Favorites',
        createdAt: now,
        updatedAt: now,
      ),
      Playlist(id: 'recent', name: 'Recent', createdAt: now, updatedAt: now),
    ],
  );
}

String jsonLikeSnapshot(List<Playlist> playlists) {
  return const PlaylistSnapshotCodec().encode(
    PlaylistSnapshot(schemaVersion: 1, playlists: playlists),
  );
}

final class _MemoryRepository implements PlaylistRepository {
  _MemoryRepository(this.snapshot);

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

final class _FailOnceAfterReplaceRepository implements PlaylistRepository {
  _FailOnceAfterReplaceRepository(this.snapshot);

  PlaylistSnapshot snapshot;
  final List<PlaylistSnapshot> saves = [];
  var _failedOnce = false;

  @override
  Future<PlaylistSnapshot> load() async => snapshot;

  @override
  Future<void> save(PlaylistSnapshot value) async {
    saves.add(value);
    if (!_failedOnce) {
      _failedOnce = true;
      snapshot = value;
      throw StateError('simulated durable replace failure');
    }
    snapshot = value;
  }
}
