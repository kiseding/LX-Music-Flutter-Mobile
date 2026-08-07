import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/audio/audio_runtime.dart';
import 'package:lx_music_flutter/startup_lifecycle.dart';

void main() {
  test('dispose cancels listeners then drains started callback before owners',
      () async {
    final events = <String>[];
    final callbackStarted = Completer<void>();
    final releaseCallback = Completer<void>();
    final interruptions = StreamController<int>.broadcast(
      onCancel: () => events.add('interruption-cancel'),
    );
    final noisy = StreamController<void>.broadcast(
      onCancel: () => events.add('noisy-cancel'),
    );
    final runtime = AudioRuntime(
      disposeHandler: () async => events.add('handler'),
    )..ownCache(() async => events.add('cache'));
    runtime.attachAudioSession<int>(
      interruptionEvents: interruptions.stream,
      noisyEvents: noisy.stream,
      onInterruption: (_) async {
        events.add('callback-start');
        callbackStarted.complete();
        await releaseCallback.future;
        events.add('callback-complete');
      },
      onNoisy: () async {},
    );
    interruptions.add(1);
    await callbackStarted.future;

    var completed = false;
    final disposing = runtime.dispose().then((_) => completed = true);
    await pumpEventQueue();

    expect(completed, isFalse);
    expect(events, [
      'callback-start',
      'interruption-cancel',
      'noisy-cancel',
    ]);
    releaseCallback.complete();
    await disposing;
    expect(events, [
      'callback-start',
      'interruption-cancel',
      'noisy-cancel',
      'callback-complete',
      'handler',
      'cache',
    ]);
    await interruptions.close();
    await noisy.close();
  });

  test('dispose continues after listener callback handler and cache failures',
      () async {
    final listenerFailure = StateError('listener');
    final callbackFailure = StateError('callback');
    final handlerFailure = StateError('handler');
    final cacheFailure = StateError('cache');
    final events = <String>[];
    final interruptions = StreamController<int>.broadcast();
    final noisy = StreamController<void>.broadcast();
    final runtime = AudioRuntime(
      disposeHandler: () async {
        events.add('handler');
        throw handlerFailure;
      },
    )..ownCache(() async {
        events.add('cache');
        throw cacheFailure;
      });
    runtime.attachAudioSession<int>(
      interruptionEvents:
          _CancelFailingStream(interruptions.stream, listenerFailure),
      noisyEvents: noisy.stream,
      onInterruption: (_) async {
        events.add('callback');
        throw callbackFailure;
      },
      onNoisy: () async {},
    );
    interruptions.add(1);
    await pumpEventQueue();

    await expectLater(runtime.dispose(), throwsA(same(listenerFailure)));

    expect(events, ['callback', 'handler', 'cache']);
    await interruptions.close();
    await noisy.close();
  });

  test('dispose reports a callback failure that completed before teardown',
      () async {
    final callbackFailure = StateError('callback');
    final interruptions = StreamController<int>.broadcast();
    final noisy = StreamController<void>.broadcast();
    final runtime = AudioRuntime(disposeHandler: () async {});
    runtime.attachAudioSession<int>(
      interruptionEvents: interruptions.stream,
      noisyEvents: noisy.stream,
      onInterruption: (_) async => throw callbackFailure,
      onNoisy: () async {},
    );
    interruptions.add(1);
    await pumpEventQueue();

    await expectLater(runtime.dispose(), throwsA(same(callbackFailure)));

    await interruptions.close();
    await noisy.close();
  });

  test(
      'startup failure cleans immediately owned handler and uninitialized cache',
      () async {
    final startupFailure = StateError('cache init');
    final events = <String>[];
    final tracker = ResourceDisposalTracker();
    final lifecycle = StartupLifecycle(ProviderContainer(), tracker);

    final startup = lifecycle.run(() async {
      await initializeOwnedAudioRuntime(
        registerDisposal: tracker.register,
        disposeHandler: () async => events.add('handler'),
        initialize: (runtime) async {
          events.add('cache-created');
          runtime.ownCache(() async => events.add('cache'));
          throw startupFailure;
        },
      );
    });

    await expectLater(startup, throwsA(same(startupFailure)));
    expect(events, ['cache-created', 'handler', 'cache']);
  });

  test('startup failure after session wiring drains its started callback',
      () async {
    final startupFailure = StateError('later startup');
    final events = <String>[];
    final callbackStarted = Completer<void>();
    final releaseCallback = Completer<void>();
    final interruptions = StreamController<int>.broadcast(
      onCancel: () => events.add('interruption-cancel'),
    );
    final noisy = StreamController<void>.broadcast(
      onCancel: () => events.add('noisy-cancel'),
    );
    final tracker = ResourceDisposalTracker();
    final lifecycle = StartupLifecycle(ProviderContainer(), tracker);

    final startup = lifecycle.run(() async {
      await initializeOwnedAudioRuntime(
        registerDisposal: tracker.register,
        disposeHandler: () async => events.add('handler'),
        initialize: (runtime) async {
          runtime.ownCache(() async => events.add('cache'));
          runtime.attachAudioSession<int>(
            interruptionEvents: interruptions.stream,
            noisyEvents: noisy.stream,
            onInterruption: (_) async {
              events.add('callback-start');
              callbackStarted.complete();
              await releaseCallback.future;
              events.add('callback-complete');
            },
            onNoisy: () async {},
          );
          interruptions.add(1);
          await callbackStarted.future;
          throw startupFailure;
        },
      );
    });
    await callbackStarted.future;
    await pumpEventQueue();

    expect(events, [
      'callback-start',
      'interruption-cancel',
      'noisy-cancel',
    ]);
    releaseCallback.complete();
    await expectLater(startup, throwsA(same(startupFailure)));
    expect(events, [
      'callback-start',
      'interruption-cancel',
      'noisy-cancel',
      'callback-complete',
      'handler',
      'cache',
    ]);
    await interruptions.close();
    await noisy.close();
  });

  test('partial session wiring owns the first successful subscription',
      () async {
    final listenFailure = StateError('noisy listen');
    var interruptionCancels = 0;
    final interruptions = StreamController<int>.broadcast(
      onCancel: () => interruptionCancels++,
    );
    final tracker = ResourceDisposalTracker();
    final lifecycle = StartupLifecycle(ProviderContainer(), tracker);

    final startup = lifecycle.run(() async {
      await initializeOwnedAudioRuntime(
        registerDisposal: tracker.register,
        disposeHandler: () async {},
        initialize: (runtime) async {
          runtime.attachAudioSession<int>(
            interruptionEvents: interruptions.stream,
            noisyEvents: _ListenFailingStream<void>(listenFailure),
            onInterruption: (_) async {},
            onNoisy: () async {},
          );
        },
      );
    });

    await expectLater(startup, throwsA(same(listenFailure)));
    expect(interruptionCancels, 1);
    await interruptions.close();
  });
}

final class _CancelFailingStream<T> extends Stream<T> {
  _CancelFailingStream(this._source, this._cancelError);

  final Stream<T> _source;
  final Object _cancelError;

  @override
  StreamSubscription<T> listen(
    void Function(T event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _CancelFailingSubscription(
      _source.listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      ),
      _cancelError,
    );
  }
}

final class _ListenFailingStream<T> extends Stream<T> {
  _ListenFailingStream(this.error);

  final Object error;

  @override
  StreamSubscription<T> listen(
    void Function(T event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    throw error;
  }
}

final class _CancelFailingSubscription<T> implements StreamSubscription<T> {
  _CancelFailingSubscription(this._delegate, this._cancelError);

  final StreamSubscription<T> _delegate;
  final Object _cancelError;

  @override
  Future<void> cancel() async {
    await _delegate.cancel();
    throw _cancelError;
  }

  @override
  void onData(void Function(T data)? handleData) =>
      _delegate.onData(handleData);

  @override
  void onError(Function? handleError) => _delegate.onError(handleError);

  @override
  void onDone(void Function()? handleDone) => _delegate.onDone(handleDone);

  @override
  void pause([Future<void>? resumeSignal]) => _delegate.pause(resumeSignal);

  @override
  void resume() => _delegate.resume();

  @override
  bool get isPaused => _delegate.isPaused;

  @override
  Future<E> asFuture<E>([E? futureValue]) => _delegate.asFuture(futureValue);
}
