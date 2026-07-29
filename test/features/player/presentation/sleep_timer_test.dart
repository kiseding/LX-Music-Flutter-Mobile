import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/features/player/presentation/player_provider.dart';

void main() {
  testWidgets('timer publishes idle only after pause succeeds', (tester) async {
    final pause = Completer<void>();
    var pauseCalls = 0;
    final notifier = SleepTimerNotifier(() {
      pauseCalls++;
      return pause.future;
    });
    addTearDown(notifier.dispose);

    notifier.startTimer(const Duration(seconds: 1));
    expect(notifier.state, isA<SleepTimerRunning>());
    await tester.pump(const Duration(seconds: 1));

    expect(pauseCalls, 1);
    expect(notifier.state, isA<SleepTimerRunning>());

    pause.complete();
    await tester.pump();
    expect(notifier.state, isA<SleepTimerIdle>());
  });

  testWidgets('timer exposes pause failure deterministically', (tester) async {
    const duration = Duration(seconds: 1);
    final failure = StateError(
      'pause failed token=secret-token https://user:password@example.com',
    );
    final notifier = SleepTimerNotifier(() async => throw failure);
    addTearDown(notifier.dispose);

    notifier.startTimer(duration);
    await tester.pump(duration);
    await tester.pump();

    final state = notifier.state;
    expect(state, isA<SleepTimerFailed>());
    expect(
      (state as SleepTimerFailed).reason,
      SleepTimerFailureReason.pauseFailed,
    );
    expect(state.duration, duration);
    expect(state.endTime, isNull);
    expect(state.toString(), isNot(contains('secret-token')));
    expect(state.toString(), isNot(contains('example.com')));
  });

  testWidgets('failed timer can retry and cancel explicitly', (tester) async {
    var pauseCalls = 0;
    final notifier = SleepTimerNotifier(() async {
      pauseCalls++;
      if (pauseCalls == 1) throw StateError('pause failed');
    });
    addTearDown(notifier.dispose);

    notifier.startTimer(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(notifier.state, isA<SleepTimerFailed>());

    notifier.retryTimer();
    expect(notifier.state, isA<SleepTimerRunning>());
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(pauseCalls, 2);
    expect(notifier.state, isA<SleepTimerIdle>());

    notifier.startTimer(const Duration(seconds: 1));
    notifier.cancelTimer();
    expect(notifier.state, isA<SleepTimerIdle>());
  });

  testWidgets('reset prevents an old pause completion from publishing',
      (tester) async {
    final oldPause = Completer<void>();
    var pauseCalls = 0;
    final notifier = SleepTimerNotifier(() {
      pauseCalls++;
      return oldPause.future;
    });
    addTearDown(notifier.dispose);

    notifier.startTimer(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    notifier.startTimer(const Duration(minutes: 1));
    final replacement = notifier.state as SleepTimerRunning;

    oldPause.complete();
    await tester.pump();
    expect(notifier.state, same(replacement));
    expect(pauseCalls, 1);
    notifier.cancelTimer();
  });

  testWidgets('cancel prevents an old pause failure from publishing',
      (tester) async {
    final oldPause = Completer<void>();
    final notifier = SleepTimerNotifier(() => oldPause.future);
    addTearDown(notifier.dispose);

    notifier.startTimer(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    notifier.cancelTimer();

    oldPause.completeError(StateError('late failure'));
    await tester.pump();
    expect(notifier.state, isA<SleepTimerIdle>());
  });

  testWidgets('dispose prevents an old pause failure from escaping the zone',
      (tester) async {
    final oldPause = Completer<void>();
    final notifier = SleepTimerNotifier(() => oldPause.future);

    notifier.startTimer(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    notifier.dispose();

    oldPause.completeError(StateError('late failure'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
