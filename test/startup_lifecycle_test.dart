import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/startup_lifecycle.dart';

void main() {
  test('startup failure disposes container and drains tracked resources once',
      () async {
    final release = Completer<void>();
    var disposeCalls = 0;
    final tracker = ResourceDisposalTracker();
    final resourceProvider = Provider<void>((ref) {
      ref.onDispose(() {
        disposeCalls++;
        tracker.track(release.future);
      });
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
}
