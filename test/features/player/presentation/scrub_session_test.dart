import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/features/player/presentation/scrub_session.dart';

void main() {
  test('dispose cancels a begin that completes after disposal', () async {
    final begin = Completer<int>();
    final cancelled = <int>[];
    final session = ScrubSession(
      begin: () => begin.future,
      finish: (_, __, {required resumeAfter}) async {},
      cancel: (generation) async => cancelled.add(generation),
    );

    session.begin();
    session.dispose();
    begin.complete(7);
    await pumpEventQueue();

    expect(cancelled, [7]);
  });

  test('stale completion cannot clear or finish a newer operation', () async {
    final firstBegin = Completer<int>();
    final secondBegin = Completer<int>();
    final begins = <Completer<int>>[firstBegin, secondBegin];
    final finishes = <int>[];
    final cancelled = <int>[];
    final session = ScrubSession(
      begin: () => begins.removeAt(0).future,
      finish: (generation, _, {required resumeAfter}) async {
        finishes.add(generation);
      },
      cancel: (generation) async => cancelled.add(generation),
    );

    final oldTap = session.begin();
    final oldCompletion = session.finish(
      oldTap,
      const Duration(seconds: 10),
      resumeAfter: true,
    );
    final newDrag = session.begin();
    firstBegin.complete(1);
    expect(await oldCompletion, isFalse);
    secondBegin.complete(2);
    session.cancelCurrent();
    await pumpEventQueue();

    expect(finishes, isEmpty);
    expect(cancelled, [1, 2]);
    expect(newDrag, isNot(oldTap));
  });

  test('current completion reports whether widget state may be cleared',
      () async {
    final session = ScrubSession(
      begin: () async => 9,
      finish: (_, __, {required resumeAfter}) async {},
      cancel: (_) async {},
    );
    final operation = session.begin();

    final mayClear = await session.finish(
      operation,
      const Duration(seconds: 12),
      resumeAfter: false,
    );

    expect(mayClear, isTrue);
  });

  test('old drag cancel cannot cancel a newer tap transaction', () async {
    final firstBegin = Completer<int>();
    final secondBegin = Completer<int>();
    final begins = <Completer<int>>[firstBegin, secondBegin];
    final cancelled = <int>[];
    final session = ScrubSession(
      begin: () => begins.removeAt(0).future,
      finish: (_, __, {required resumeAfter}) async {},
      cancel: (generation) async => cancelled.add(generation),
    );

    final drag = session.begin();
    final tap = session.begin();
    expect(session.cancel(drag), isFalse);
    firstBegin.complete(3);
    await pumpEventQueue();
    expect(cancelled, [3]);

    expect(session.cancel(tap), isTrue);
    secondBegin.complete(4);
    await pumpEventQueue();
    expect(cancelled, [3, 4]);
  });

  test('begin cancels a superseded operation without its continuation',
      () async {
    final firstBegin = Completer<int>();
    final secondBegin = Completer<int>();
    final begins = <Completer<int>>[firstBegin, secondBegin];
    final cancelled = <int>[];
    final session = ScrubSession(
      begin: () => begins.removeAt(0).future,
      finish: (_, __, {required resumeAfter}) async {},
      cancel: (generation) async => cancelled.add(generation),
    );

    session.begin();
    session.begin();
    firstBegin.complete(5);
    await pumpEventQueue();

    expect(cancelled, [5]);
    session.dispose();
    secondBegin.complete(6);
    await pumpEventQueue();
    expect(cancelled, [5, 6]);
  });

  test('failed begin is reported once without escaping and session continues',
      () async {
    final reports = <Object>[];
    final escaped = <Object>[];
    final finishes = <int>[];

    await runZonedGuarded(() async {
      var beginCalls = 0;
      final session = ScrubSession(
        begin: () {
          beginCalls++;
          return beginCalls == 1
              ? Future<int>.error(StateError('begin failed'))
              : Future<int>.value(8);
        },
        finish: (generation, _, {required resumeAfter}) async {
          finishes.add(generation);
        },
        cancel: (_) async {},
        onError: (error, stackTrace) => reports.add(error),
      );

      final failed = session.begin();
      final current = session.begin();
      session.cancel(failed);
      await pumpEventQueue();
      expect(
        await session.finish(
          current,
          const Duration(seconds: 8),
          resumeAfter: false,
        ),
        isTrue,
      );
    }, (error, stackTrace) => escaped.add(error));

    expect(reports, hasLength(1));
    expect(reports.single, isA<StateError>());
    expect(escaped, isEmpty);
    expect(finishes, [8]);
  });

  test('failed cancel is reported once without escaping and dispose stays safe',
      () async {
    final reports = <Object>[];
    final escaped = <Object>[];
    final cancelCalls = <int>[];

    await runZonedGuarded(() async {
      var generation = 0;
      final session = ScrubSession(
        begin: () async => ++generation,
        finish: (_, __, {required resumeAfter}) async {},
        cancel: (value) async {
          cancelCalls.add(value);
          if (value == 1) throw StateError('cancel failed');
        },
        onError: (error, stackTrace) => reports.add(error),
      );

      final failed = session.begin();
      session.cancel(failed);
      session.cancel(failed);
      await pumpEventQueue();

      session.begin();
      session.dispose();
      await pumpEventQueue();
    }, (error, stackTrace) => escaped.add(error));

    expect(reports, hasLength(1));
    expect(reports.single, isA<StateError>());
    expect(escaped, isEmpty);
    expect(cancelCalls, [1, 2]);
  });

  test('default error handler captures construction zone and reports once',
      () async {
    final reported = Completer<Object>();
    var reportCalls = 0;
    final cancelError = StateError('cancel failed');
    final session = runZonedGuarded(
      () => ScrubSession(
        begin: () async => 1,
        finish: (_, __, {required resumeAfter}) async {},
        cancel: (_) async => throw cancelError,
      ),
      (error, stackTrace) {
        reportCalls++;
        if (!reported.isCompleted) reported.complete(error);
      },
    )!;

    final operation = session.begin();
    session.cancel(operation);
    session.cancel(operation);

    expect(await reported.future, same(cancelError));
    await pumpEventQueue();
    expect(reportCalls, 1);
  });
}
