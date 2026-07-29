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
  test('dispose drains resources registered synchronously by a disposer',
      () async {
    final calls = <String, int>{};
    final tracker = ResourceDisposalTracker();
    tracker.register(() {
      calls.update('outer', (count) => count + 1, ifAbsent: () => 1);
      tracker.register(() async {
        calls.update('inner', (count) => count + 1, ifAbsent: () => 1);
      });
      return Future<void>.value();
    });

    await tracker.disposeAndDrain();
    await tracker.disposeAndDrain();

    expect(calls, {'outer': 1, 'inner': 1});
  });

  test('dispose reaches a fixed point before and after container teardown',
      () async {
    final events = <String>[];
    final tracker = ResourceDisposalTracker();
    tracker.register(() async {
      await Future<void>.delayed(Duration.zero);
      tracker.register(() async {
        events.add('during-drain-resource');
      });
      tracker.track(Future<void>.microtask(() {
        events.add('during-drain-future');
      }));
    });
    final provider = Provider<void>((ref) {
      ref.onDispose(() {
        tracker.register(() async {
          await Future<void>.delayed(Duration.zero);
          tracker.register(() async {
            events.add('post-container-resource');
          });
          tracker.track(Future<void>.microtask(() {
            events.add('post-container-future');
          }));
        });
      });
    });
    final container = ProviderContainer();
    container.read(provider);

    await StartupLifecycle(container, tracker).dispose();

    expect(
      events,
      containsAll(<String>[
        'during-drain-resource',
        'during-drain-future',
        'post-container-resource',
        'post-container-future',
      ]),
    );
  });

  test('synchronous disposer failure does not stop remaining cleanup',
      () async {
    final failure = StateError('synchronous disposal failed');
    final events = <String>[];
    final tracker = ResourceDisposalTracker();
    tracker.track(Future<void>.microtask(() => events.add('pending')));
    tracker.register(() async {
      events.add('later-resource');
    });
    tracker.register(() {
      events.add('throwing-resource');
      throw failure;
    });

    await expectLater(tracker.disposeAndDrain(), throwsA(same(failure)));

    expect(
      events,
      ['throwing-resource', 'later-resource', 'pending'],
    );
  });

  test('asynchronous disposer failure does not stop callback-started cleanup',
      () async {
    final failure = StateError('asynchronous disposal failed');
    final events = <String>[];
    final tracker = ResourceDisposalTracker();
    tracker.register(() async {
      await Future<void>.delayed(Duration.zero);
      tracker.register(() async {
        events.add('callback-resource');
      });
      tracker.track(Future<void>.microtask(() {
        events.add('callback-future');
      }));
      throw failure;
    });

    await expectLater(tracker.disposeAndDrain(), throwsA(same(failure)));

    expect(events, containsAll(['callback-resource', 'callback-future']));
  });

  test('repeated dispose shares one drain and reports failure after cleanup',
      () async {
    final releaseCleanup = Completer<void>();
    final failure = StateError('cleanup failed');
    var failingCalls = 0;
    var cleanupCalls = 0;
    final tracker = ResourceDisposalTracker();
    tracker.track(releaseCleanup.future);
    tracker.register(() async {
      cleanupCalls++;
    });
    tracker.register(() {
      failingCalls++;
      throw failure;
    });
    final lifecycle = StartupLifecycle(ProviderContainer(), tracker);

    final first = lifecycle.dispose();
    final second = lifecycle.dispose();
    var completed = false;
    first.whenComplete(() => completed = true).ignore();

    expect(identical(first, second), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    releaseCleanup.complete();
    await expectLater(first, throwsA(same(failure)));
    await expectLater(lifecycle.dispose(), throwsA(same(failure)));
    expect(failingCalls, 1);
    expect(cleanupCalls, 1);
  });

  testWidgets('owned provider scope reports asynchronous cleanup failure',
      (tester) async {
    final failure = StateError('root teardown failed');
    final reported = <FlutterErrorDetails>[];
    final previousOnError = FlutterError.onError;
    FlutterError.onError = reported.add;
    addTearDown(() => FlutterError.onError = previousOnError);
    final tracker = ResourceDisposalTracker();
    tracker.register(() async => throw failure);
    final lifecycle = StartupLifecycle(ProviderContainer(), tracker);

    await tester.pumpWidget(
      OwnedProviderScope(lifecycle: lifecycle, child: const SizedBox()),
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    expect(reported, hasLength(1));
    expect(reported.single.exception, same(failure));
  });

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
