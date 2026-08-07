import 'dart:async';

import 'fire_and_forget_observer.dart';

typedef BeginScrub = Future<int> Function();
typedef FinishScrub = Future<void> Function(
  int generation,
  Duration position, {
  required bool resumeAfter,
});
typedef CancelScrub = Future<void> Function(int generation);
typedef ScrubErrorHandler = AsyncErrorHandler;

final class ScrubOperation {
  final Future<int> generation;
  Future<void>? _cancellation;

  ScrubOperation._(this.generation);
}

final class ScrubSession {
  final BeginScrub _begin;
  final FinishScrub _finish;
  final CancelScrub _cancel;
  final FireAndForgetObserver _observer;
  ScrubOperation? _current;
  bool _disposed = false;

  ScrubSession({
    required BeginScrub begin,
    required FinishScrub finish,
    required CancelScrub cancel,
    ScrubErrorHandler? onError,
  })  : _begin = begin,
        _finish = finish,
        _cancel = cancel,
        _observer = FireAndForgetObserver(onError: onError);

  ScrubOperation begin() {
    final previous = _current;
    final operation = ScrubOperation._(_begin());
    _current = operation;
    if (previous != null) _ignoreCancellation(previous);
    if (_disposed) _ignoreCancellation(operation);
    return operation;
  }

  Future<bool> finish(
    ScrubOperation operation,
    Duration position, {
    required bool resumeAfter,
  }) async {
    final generation = await operation.generation;
    if (_disposed || !identical(_current, operation)) {
      await _cancelOperation(operation);
      return false;
    }
    await _finish(generation, position, resumeAfter: resumeAfter);
    if (!identical(_current, operation)) return false;
    _current = null;
    return true;
  }

  bool cancel(ScrubOperation operation) {
    final wasCurrent = identical(_current, operation);
    if (wasCurrent) _current = null;
    _ignoreCancellation(operation);
    return wasCurrent;
  }

  void cancelCurrent() {
    final operation = _current;
    if (operation == null) return;
    _current = null;
    _ignoreCancellation(operation);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    cancelCurrent();
  }

  Future<void> _cancelOperation(ScrubOperation operation) {
    return operation._cancellation ??= _observer.observe(
      () async {
        final generation = await operation.generation;
        await _cancel(generation);
      }(),
    );
  }

  void _ignoreCancellation(ScrubOperation operation) {
    unawaited(_cancelOperation(operation));
  }
}
