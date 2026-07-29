import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final resourceDisposalTrackerProvider = Provider<ResourceDisposalTracker>(
  (_) => ResourceDisposalTracker(),
);

final class ResourceDisposalTracker {
  final List<Future<void>> _pending = [];
  final List<_TrackedDisposal> _resources = [];

  void Function() register(Future<void> Function() dispose) {
    final resource = _TrackedDisposal(dispose);
    _resources.add(resource);
    return () => track(resource.dispose());
  }

  void track(Future<void> disposal) {
    _pending.add(disposal);
  }

  Future<void> disposeAndDrain() async {
    for (final resource in _resources.reversed) {
      track(resource.dispose());
    }
    _resources.clear();
    while (_pending.isNotEmpty) {
      final pending = List<Future<void>>.of(_pending);
      _pending.clear();
      await Future.wait(pending);
    }
  }
}

final class _TrackedDisposal {
  _TrackedDisposal(this._dispose);

  final Future<void> Function() _dispose;
  Future<void>? _future;

  Future<void> dispose() => _future ??= _dispose();
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
    try {
      await disposals.disposeAndDrain();
    } finally {
      container.dispose();
      await disposals.disposeAndDrain();
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
    unawaited(widget.lifecycle.dispose());
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
