import 'dart:async';

typedef AsyncErrorHandler = void Function(Object error, StackTrace stackTrace);

final class FireAndForgetObserver {
  final AsyncErrorHandler _onError;

  FireAndForgetObserver({AsyncErrorHandler? onError})
      : _onError = onError ?? Zone.current.handleUncaughtError;

  Future<void> observe(Future<void> future) async {
    try {
      await future;
    } catch (error, stackTrace) {
      _onError(error, stackTrace);
    }
  }

  void call(Future<void> future) {
    unawaited(observe(future));
  }
}
