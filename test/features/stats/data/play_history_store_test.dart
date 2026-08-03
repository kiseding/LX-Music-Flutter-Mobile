import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/storage/storage_service.dart';
import 'package:lx_music_flutter/features/stats/data/play_history_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('records the maximum elapsed time when a session ends', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final store = PlayHistoryStore(
      () async => StorageService.forTesting(preferences),
    );

    store.beginSession(
      songId: 'song-1',
      songTitle: 'Title',
      artistName: 'Artist',
      albumTitle: 'Album',
      source: 'tx',
    );
    store.tick(const Duration(seconds: 45));
    store.endSession();

    expect(store.entries, hasLength(1));
    expect(store.entries.single.songId, 'song-1');
    expect(store.entries.single.listenedSec, 45);

    store.dispose();
  });

  test('does not record sessions below the threshold', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final store = PlayHistoryStore(
      () async => StorageService.forTesting(preferences),
    );

    store.beginSession(
      songId: 'song-1',
      songTitle: 'Title',
      artistName: 'Artist',
      albumTitle: 'Album',
      source: 'tx',
    );
    store.tick(const Duration(seconds: 29));
    store.endSession();

    expect(store.entries, isEmpty);
    store.dispose();
  });
}
