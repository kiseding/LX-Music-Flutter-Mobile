import 'package:path_provider/path_provider.dart';

import '../widgets/artwork_disk_cache.dart';

enum AppCacheCategory {
  playback,
  artwork,
  temporaryFiles,
}

class CacheClearSummary {
  const CacheClearSummary({this.retainedPlaybackEntries = 0});

  final int retainedPlaybackEntries;
}

typedef PlaybackCacheClearer = Future<int> Function();

class CacheMaintenanceService {
  CacheMaintenanceService({
    PlaybackCacheClearer? clearPlaybackCache,
    Future<void> Function()? clearArtworkCache,
    Future<void> Function()? clearTemporaryFiles,
  })  : _clearPlaybackCache = clearPlaybackCache,
        _clearArtworkCache =
            clearArtworkCache ?? ArtworkDiskCache.instance.clear,
        _clearTemporaryFiles = clearTemporaryFiles ?? _clearTemporaryDirectory;

  PlaybackCacheClearer? _clearPlaybackCache;
  final Future<void> Function() _clearArtworkCache;
  final Future<void> Function() _clearTemporaryFiles;

  Future<void> Function() attachPlaybackCache(PlaybackCacheClearer clear) {
    _clearPlaybackCache = clear;
    return () async {
      if (identical(_clearPlaybackCache, clear)) {
        _clearPlaybackCache = null;
      }
    };
  }

  Future<CacheClearSummary> clear(Set<AppCacheCategory> categories) async {
    var retainedPlaybackEntries = 0;
    Object? firstError;
    StackTrace? firstStackTrace;

    Future<void> run(Future<void> Function() operation) async {
      try {
        await operation();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    if (categories.contains(AppCacheCategory.playback)) {
      await run(() async {
        final clearPlaybackCache = _clearPlaybackCache;
        if (clearPlaybackCache == null) {
          throw StateError('Playback cache is not available');
        }
        retainedPlaybackEntries = await clearPlaybackCache();
      });
    }
    if (categories.contains(AppCacheCategory.artwork)) {
      await run(_clearArtworkCache);
    }
    if (categories.contains(AppCacheCategory.temporaryFiles)) {
      await run(_clearTemporaryFiles);
    }

    if (firstError case final error?) {
      Error.throwWithStackTrace(error, firstStackTrace!);
    }
    return CacheClearSummary(
      retainedPlaybackEntries: retainedPlaybackEntries,
    );
  }

  static Future<void> _clearTemporaryDirectory() async {
    final directory = await getTemporaryDirectory();
    await directory.create(recursive: true);
    await for (final entity in directory.list(followLinks: false)) {
      await entity.delete(recursive: true);
    }
  }
}
