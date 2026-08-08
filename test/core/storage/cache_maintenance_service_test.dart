import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/storage/cache_maintenance_service.dart';

void main() {
  test('clear runs only selected cache categories', () async {
    final calls = <String>[];
    final service = CacheMaintenanceService(
      clearPlaybackCache: () async {
        calls.add('playback');
        return 2;
      },
      clearArtworkCache: () async => calls.add('artwork'),
      clearTemporaryFiles: () async => calls.add('temporary'),
    );

    final summary = await service.clear({
      AppCacheCategory.playback,
      AppCacheCategory.temporaryFiles,
    });

    expect(calls, ['playback', 'temporary']);
    expect(summary.retainedPlaybackEntries, 2);
  });

  test('clear attempts every selected category before reporting failure',
      () async {
    final calls = <String>[];
    final failure = StateError('playback failed');
    final service = CacheMaintenanceService(
      clearPlaybackCache: () async {
        calls.add('playback');
        throw failure;
      },
      clearArtworkCache: () async => calls.add('artwork'),
      clearTemporaryFiles: () async => calls.add('temporary'),
    );

    await expectLater(
      service.clear(AppCacheCategory.values.toSet()),
      throwsA(same(failure)),
    );
    expect(calls, ['playback', 'artwork', 'temporary']);
  });

  test('attached playback cleaner detaches without replacing a newer one',
      () async {
    final service = CacheMaintenanceService(
      clearArtworkCache: () async {},
      clearTemporaryFiles: () async {},
    );
    final detachFirst = service.attachPlaybackCache(() async => 1);
    service.attachPlaybackCache(() async => 3);

    await detachFirst();
    final summary = await service.clear({AppCacheCategory.playback});

    expect(summary.retainedPlaybackEntries, 3);
  });
}
