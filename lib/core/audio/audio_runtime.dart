import 'dart:async';

typedef RegisterDisposal = void Function() Function(
  Future<void> Function() dispose,
);

final class AudioRuntime {
  AudioRuntime({required Future<void> Function() disposeHandler})
      : _disposeHandler = disposeHandler;

  final Future<void> Function() _disposeHandler;
  Future<void> Function()? _disposeCache;
  final List<Future<void> Function()> _cancelSubscriptions = [];
  final Set<_TrackedCallback> _callbacks = {};
  final List<_CallbackFailure> _callbackFailures = [];
  bool _disposing = false;
  Future<void>? _disposeFuture;

  void ownCache(Future<void> Function() disposeCache) {
    if (_disposing || _disposeCache != null) {
      throw StateError('AudioRuntime cannot accept another cache owner');
    }
    _disposeCache = disposeCache;
  }

  void attachAudioSession<T>({
    required Stream<T> interruptionEvents,
    required Stream<void> noisyEvents,
    required Future<void> Function(T event) onInterruption,
    required Future<void> Function() onNoisy,
  }) {
    if (_disposing) throw StateError('AudioRuntime is disposing');
    final interruptionSubscription = interruptionEvents.listen((event) {
      if (!_disposing) _track(() => onInterruption(event));
    });
    _cancelSubscriptions.add(interruptionSubscription.cancel);
    final noisySubscription = noisyEvents.listen((_) {
      if (!_disposing) _track(onNoisy);
    });
    _cancelSubscriptions.add(noisySubscription.cancel);
  }

  void attachAudioDeviceChanges<T>({
    required Stream<T> deviceEvents,
    required Future<void> Function(T event) onDeviceChanged,
  }) {
    if (_disposing) throw StateError('AudioRuntime is disposing');
    final deviceSubscription = deviceEvents.listen((event) {
      if (!_disposing) _track(() => onDeviceChanged(event));
    });
    _cancelSubscriptions.add(deviceSubscription.cancel);
  }

  void _track(Future<void> Function() callback) {
    final tracked = _TrackedCallback();
    _callbacks.add(tracked);
    tracked.completion = Future<void>.sync(callback).catchError(
      (Object error, StackTrace stackTrace) {
        tracked.error = error;
        tracked.stackTrace = stackTrace;
        _callbackFailures.add(_CallbackFailure(error, stackTrace));
      },
    ).whenComplete(() => _callbacks.remove(tracked));
  }

  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    Object? firstError;
    StackTrace? firstStackTrace;
    Future<void> cleanup(FutureOr<void> Function() action) async {
      try {
        await Future<void>.sync(action);
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    _disposing = true;
    final cancellations = _cancelSubscriptions.toList(growable: false);
    _cancelSubscriptions.clear();
    for (final cancel in cancellations) {
      await cleanup(cancel);
    }

    while (_callbacks.isNotEmpty) {
      final callbacks = _callbacks.toList(growable: false);
      await Future.wait(callbacks.map((callback) => callback.completion));
    }
    for (final failure in _callbackFailures) {
      firstError ??= failure.error;
      firstStackTrace ??= failure.stackTrace;
    }
    _callbackFailures.clear();

    await cleanup(_disposeHandler);
    final disposeCache = _disposeCache;
    _disposeCache = null;
    if (disposeCache != null) await cleanup(disposeCache);

    if (firstError case final error?) {
      Error.throwWithStackTrace(error, firstStackTrace!);
    }
  }
}

Future<AudioRuntime> initializeOwnedAudioRuntime({
  required RegisterDisposal registerDisposal,
  required Future<void> Function() disposeHandler,
  required Future<void> Function(AudioRuntime runtime) initialize,
}) async {
  final runtime = AudioRuntime(disposeHandler: disposeHandler);
  registerDisposal(runtime.dispose);
  await initialize(runtime);
  return runtime;
}

final class _TrackedCallback {
  late final Future<void> completion;
  Object? error;
  StackTrace? stackTrace;
}

final class _CallbackFailure {
  const _CallbackFailure(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;
}
