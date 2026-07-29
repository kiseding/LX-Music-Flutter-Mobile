import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final resourceDisposalTrackerProvider = Provider<ResourceDisposalTracker>(
  (_) => ResourceDisposalTracker(),
);

final class ResourceDisposalTracker {
  final List<_PendingDisposal> _pending = [];
  final List<_TrackedDisposal> _resources = [];
  Future<void>? _drainFuture;

  void Function() register(Future<void> Function() dispose) {
    final resource = _TrackedDisposal(dispose);
    _resources.add(resource);
    return () => track(resource.dispose());
  }

  void track(Future<void> disposal) {
    _pending.add(_PendingDisposal(disposal));
  }

  Future<void> disposeAndDrain() {
    final activeDrain = _drainFuture;
    if (activeDrain != null) return activeDrain;

    final drain = _drain();
    _drainFuture = drain;
    drain.whenComplete(() {
      if (identical(_drainFuture, drain)) _drainFuture = null;
    }).ignore();
    return drain;
  }

  Future<void> _drain() async {
    _DisposalFailure? firstFailure;
    while (_resources.isNotEmpty || _pending.isNotEmpty) {
      while (_resources.isNotEmpty) {
        try {
          await _resources.removeLast().dispose();
        } catch (error, stackTrace) {
          firstFailure ??= _DisposalFailure(error, stackTrace);
        }
      }

      final pending = List<_PendingDisposal>.of(_pending);
      _pending.clear();
      await Future.wait(pending.map((disposal) => disposal.completion));
      for (final disposal in pending) {
        firstFailure ??= disposal.failure;
      }
    }

    if (firstFailure case final failure?) {
      Error.throwWithStackTrace(failure.error, failure.stackTrace);
    }
  }
}

final class _PendingDisposal {
  _PendingDisposal(Future<void> disposal) {
    completion = _capture(disposal);
  }

  late final Future<void> completion;
  _DisposalFailure? failure;

  Future<void> _capture(Future<void> disposal) async {
    try {
      await disposal;
    } catch (error, stackTrace) {
      failure = _DisposalFailure(error, stackTrace);
    }
  }
}

final class _DisposalFailure {
  const _DisposalFailure(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;
}

final class _TrackedDisposal {
  _TrackedDisposal(this._dispose);

  final Future<void> Function() _dispose;
  Future<void>? _future;

  Future<void> dispose() => _future ??= Future<void>.sync(_dispose);
}

final class StartupLifecycle {
  StartupLifecycle(this.container, this.disposals);

  final ProviderContainer container;
  final ResourceDisposalTracker disposals;
  Future<void>? _disposeFuture;

  Future<T> run<T>(Future<T> Function() initialize) async {
    try {
      return await initialize();
    } catch (_) {
      await dispose();
      rethrow;
    }
  }

  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    _DisposalFailure? firstFailure;
    try {
      await disposals.disposeAndDrain();
    } catch (error, stackTrace) {
      firstFailure = _DisposalFailure(error, stackTrace);
    }
    try {
      container.dispose();
    } catch (error, stackTrace) {
      firstFailure ??= _DisposalFailure(error, stackTrace);
    }
    try {
      await disposals.disposeAndDrain();
    } catch (error, stackTrace) {
      firstFailure ??= _DisposalFailure(error, stackTrace);
    }

    if (firstFailure case final failure?) {
      Error.throwWithStackTrace(failure.error, failure.stackTrace);
    }
  }
}

class OwnedProviderScope extends StatefulWidget {
  const OwnedProviderScope({
    super.key,
    required this.lifecycle,
    required this.child,
  });

  final StartupLifecycle lifecycle;
  final Widget child;

  @override
  State<OwnedProviderScope> createState() => _OwnedProviderScopeState();
}

class _OwnedProviderScopeState extends State<OwnedProviderScope> {
  @override
  void dispose() {
    unawaited(widget.lifecycle.dispose().catchError((error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'startup lifecycle',
          context: ErrorDescription('while disposing the root provider scope'),
        ),
      );
    }));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return UncontrolledProviderScope(
      container: widget.lifecycle.container,
      child: widget.child,
    );
  }
}
