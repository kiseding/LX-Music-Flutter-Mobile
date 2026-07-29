import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/features/custom_source/domain/custom_source_service.dart';
import 'package:lx_music_flutter/features/custom_source/presentation/custom_source_provider.dart';
import 'package:lx_music_flutter/features/download/presentation/download_provider.dart';
import 'package:lx_music_flutter/features/playlist/data/playlist_repository.dart';
import 'package:lx_music_flutter/features/playlist/presentation/playlist_provider.dart';
import 'package:lx_music_flutter/startup_lifecycle.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('startup failure disposes container and drains tracked resources once',
      () async {
    final release = Completer<void>();
    var disposeCalls = 0;
    final tracker = ResourceDisposalTracker();
    final disposeResource = tracker.register(() {
      disposeCalls++;
      return release.future;
    });
    final resourceProvider = Provider<void>((ref) {
      ref.onDispose(disposeResource);
    });
    final container = ProviderContainer();
    container.read(resourceProvider);
    final lifecycle = StartupLifecycle(container, tracker);

    var completed = false;
    final startup = lifecycle.run(() async {
      throw StateError('initialization failed');
    }).whenComplete(() => completed = true);
    await Future<void>.delayed(Duration.zero);

    expect(disposeCalls, 1);
    expect(completed, isFalse);
    release.complete();
    await expectLater(startup, throwsStateError);
    await lifecycle.dispose();
    expect(disposeCalls, 1);
  });

  testWidgets('owned provider scope disposes lifecycle on teardown',
      (tester) async {
    var disposed = 0;
    final tracker = ResourceDisposalTracker();
    final container = ProviderContainer();
    final provider = Provider<void>((ref) {
      ref.onDispose(() {
        disposed++;
        tracker.track(Future<void>.value());
      });
    });
    container.read(provider);
    final lifecycle = StartupLifecycle(container, tracker);

    await tester.pumpWidget(
      OwnedProviderScope(lifecycle: lifecycle, child: const SizedBox()),
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    expect(disposed, 1);
  });

  test('production provider graph drains async services before dependencies',
      () async {
    SharedPreferences.setMockInitialValues({});
    final events = <String>[];
    final disposals = ResourceDisposalTracker();
    final customSourceService = _RecordingCustomSourceService(events);
    final container = ProviderContainer(overrides: [
      resourceDisposalTrackerProvider.overrideWithValue(disposals),
      playlistRepositoryProvider.overrideWithValue(_MemoryPlaylistRepository()),
      customSourceServiceProvider.overrideWith((ref) {
        ref.onDispose(customSourceService.dispose);
        return customSourceService;
      }),
    ]);
    final playlistService = container.read(playlistServiceProvider);
    final downloadService = container.read(downloadServiceProvider);
    final playlistSubscription = playlistService.revisions.listen(
      (_) {},
      onDone: () => events.add('playlist'),
    );
    final downloadSubscription = downloadService.tasksStream.listen(
      (_) {},
      onDone: () => events.add('download'),
    );
    final lifecycle = StartupLifecycle(container, disposals);

    await lifecycle.dispose();

    expect(
        events, containsAll(<String>['playlist', 'download', 'custom-source']));
    expect(
        events.indexOf('playlist'), lessThan(events.indexOf('custom-source')));
    expect(
        events.indexOf('download'), lessThan(events.indexOf('custom-source')));
    await playlistSubscription.cancel();
    await downloadSubscription.cancel();
  });
}

final class _RecordingCustomSourceService extends CustomSourceService {
  _RecordingCustomSourceService(this.events);

  final List<String> events;

  @override
  void dispose() {
    events.add('custom-source');
    super.dispose();
  }
}

final class _MemoryPlaylistRepository implements PlaylistRepository {
  @override
  Future<PlaylistSnapshot> load() async =>
      PlaylistSnapshot(schemaVersion: 1, playlists: const []);

  @override
  Future<void> save(PlaylistSnapshot snapshot) async {}
}
