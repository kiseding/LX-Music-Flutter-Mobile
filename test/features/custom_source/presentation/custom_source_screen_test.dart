import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/features/custom_source/domain/custom_source.dart';
import 'package:lx_music_flutter/features/custom_source/domain/custom_source_service.dart';
import 'package:lx_music_flutter/features/custom_source/presentation/custom_source_provider.dart';
import 'package:lx_music_flutter/features/custom_source/presentation/custom_source_screen.dart';

void main() {
  testWidgets(
      'URL import completion after dismissal does not touch dead dialog',
      (tester) async {
    final completion = Completer<bool>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          customSourceServiceProvider.overrideWithValue(_NoopService()),
          importCustomSourceFromUrlProvider
              .overrideWithValue((_) => completion.future),
        ],
        child: const MaterialApp(home: CustomSourceScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('通过链接导入'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'https://example.com/a.js');
    await tester.tap(find.text('导入'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    completion.complete(true);
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('导入成功'), findsNothing);
  });

  testWidgets('closing log dialog cancels its event subscription',
      (tester) async {
    final stream = _TrackingStream<Map<String, dynamic>>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          customSourceServiceProvider.overrideWithValue(_NoopService()),
          customSourceEventStreamProvider
              .overrideWith((ref, sourceId) => stream),
        ],
        child: const MaterialApp(home: CustomSourceScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('日志'));
    await tester.pumpAndSettle();
    expect(stream.listenCount, 1);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(stream.cancelCount, 1);
  });
}

class _NoopService extends CustomSourceService {
  @override
  List<CustomSource> get sources => [
        CustomSource(
          id: 'source',
          name: 'Source',
          description: '',
          version: '1',
          author: 'Tester',
          script: '',
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        ),
      ];

  @override
  Future<void> init() async {}
}

class _TrackingStream<T> extends Stream<T> {
  final _controller = StreamController<T>.broadcast();
  int listenCount = 0;
  int cancelCount = 0;

  @override
  StreamSubscription<T> listen(
    void Function(T)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    listenCount++;
    final inner = _controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
    return _TrackingSubscription<T>(inner, () => cancelCount++);
  }
}

class _TrackingSubscription<T> implements StreamSubscription<T> {
  _TrackingSubscription(this._inner, this._onCancel);
  final StreamSubscription<T> _inner;
  final void Function() _onCancel;
  @override
  Future<void> cancel() {
    _onCancel();
    return _inner.cancel();
  }

  @override
  void onData(void Function(T data)? handleData) => _inner.onData(handleData);
  @override
  void onError(Function? handleError) => _inner.onError(handleError);
  @override
  void onDone(void Function()? handleDone) => _inner.onDone(handleDone);
  @override
  void pause([Future<void>? resumeSignal]) => _inner.pause(resumeSignal);
  @override
  void resume() => _inner.resume();
  @override
  bool get isPaused => _inner.isPaused;
  @override
  Future<E> asFuture<E>([E? futureValue]) => _inner.asFuture(futureValue);
}
