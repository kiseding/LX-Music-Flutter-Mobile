import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/storage/storage_service.dart';
import 'package:lx_music_flutter/features/stats/data/play_history_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('records actual position and wall-clock deltas', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    var now = DateTime.utc(2026);
    final store = PlayHistoryStore(
      () async => StorageService.forTesting(preferences),
      clock: () => now,
    );

    store.beginSession(
      songId: 'song-1',
      songTitle: 'Title',
      artistName: 'Artist',
      albumTitle: 'Album',
      source: 'tx',
    );
    store.tick(Duration.zero);
    now = now.add(const Duration(seconds: 20));
    store.tick(const Duration(seconds: 20));
    now = now.add(const Duration(seconds: 25));
    store.tick(const Duration(seconds: 45));
    store.endSession();

    expect(store.entries, hasLength(1));
    expect(store.entries.single.songId, 'song-1');
    expect(store.entries.single.listenedSec, 45);

    await store.disposeAsync();
  });

  test('seek jumps do not inflate listened time', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    var now = DateTime.utc(2026);
    final store = PlayHistoryStore(
      () async => StorageService.forTesting(preferences),
      clock: () => now,
    );

    store.beginSession(
      songId: 'song-1',
      songTitle: 'Title',
      artistName: 'Artist',
      albumTitle: 'Album',
      source: 'tx',
    );
    store.tick(Duration.zero);
    now = now.add(const Duration(seconds: 10));
    store.tick(const Duration(minutes: 10));
    now = now.add(const Duration(seconds: 25));
    store.tick(const Duration(minutes: 10, seconds: 25));
    store.endSession();

    expect(store.entries, isEmpty);
    await store.disposeAsync();
  });

  test('disposeAsync ends the session and flushes the pending save', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    var now = DateTime.utc(2026);
    final store = PlayHistoryStore(
      () async => StorageService.forTesting(preferences),
      clock: () => now,
    );

    store.beginSession(
      songId: 'song-1',
      songTitle: 'Title',
      artistName: 'Artist',
      albumTitle: 'Album',
      source: 'tx',
    );
    store.tick(Duration.zero);
    now = now.add(const Duration(seconds: 35));
    store.tick(const Duration(seconds: 35));

    await store.disposeAsync();

    final persisted = StorageService.forTesting(
      preferences,
    ).getJsonList('play_history_v1');
    expect(persisted.single['songId'], 'song-1');
    expect(persisted.single['listenedSec'], 35);
  });
}
