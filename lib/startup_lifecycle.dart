import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final resourceDisposalTrackerProvider = Provider<ResourceDisposalTracker>(
  (_) => ResourceDisposalTracker(),
);

final class ResourceDisposalTracker {
  final List<Future<void>> _pending = [];
  final List<Future<void> Function()> _resources = [];

  void register(Future<void> Function() dispose) {
    _resources.add(dispose);
  }

  void track(Future<void> disposal) {
    _pending.add(disposal);
  }

  Future<void> disposeAndDrain() async {
    for (final dispose in _resources.reversed) {
      track(dispose());
    }
    _resources.clear();
    while (_pending.isNotEmpty) {
      final pending = List<Future<void>>.of(_pending);
      _pending.clear();
      await Future.wait(pending);
    }
  }
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
    container.dispose();
    await disposals.disposeAndDrain();
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
