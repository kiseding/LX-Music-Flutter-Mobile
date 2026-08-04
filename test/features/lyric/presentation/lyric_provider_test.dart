import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/features/lyric/domain/lyric.dart';
import 'package:lx_music_flutter/features/lyric/presentation/lyric_provider.dart';
import 'package:lx_music_flutter/features/player/domain/music_item.dart';
import 'package:lx_music_flutter/features/player/presentation/player_provider.dart';

void main() {
  test('late lyric result cannot overwrite a newer song', () async {
    final first = Completer<Lyrics>();
    final second = Completer<Lyrics>();
    final notifier = LyricNotifier(
      (music) => music.id == 'A' ? first.future : second.future,
    );
    addTearDown(notifier.dispose);

    final loadA = notifier.select(_music('A'));
    final loadB = notifier.select(_music('B'));
    second.complete(_lyrics('B'));
    await loadB;
    first.complete(_lyrics('A'));
    await loadA;

    expect(notifier.state.lyrics.raw, 'B');
  });

  test('clearing selection invalidates an in-flight lyric request', () async {
    final pending = Completer<Lyrics>();
    final notifier = LyricNotifier((_) => pending.future);
    addTearDown(notifier.dispose);

    final load = notifier.select(_music('A'));
    await notifier.select(null);
    pending.complete(_lyrics('A'));
    await load;

    expect(notifier.state.lyrics.isEmpty, isTrue);
    expect(notifier.state.isLoading, isFalse);
    expect(notifier.state.error, isNull);
  });

  test('equal current music publication does not fetch twice', () async {
    final selectedMusicProvider = StateProvider<MusicItem?>((_) => _music('A'));
    var calls = 0;
    final container = ProviderContainer(
      overrides: [
        currentMusicProvider.overrideWith(
          (ref) => ref.watch(selectedMusicProvider),
        ),
        lyricLoaderProvider.overrideWithValue((music) async {
          calls++;
          return _lyrics(music.id);
        }),
      ],
    );
    addTearDown(container.dispose);

    container.listen(currentLyricLoadProvider, (_, __) {},
        fireImmediately: true);
    await pumpEventQueue();
    container.read(selectedMusicProvider.notifier).state = _music('A');
    await pumpEventQueue();

    expect(calls, 1);
    expect(container.read(currentLyricProvider).raw, 'A');
  });

  test('same item reloads when lyric platform identity changes', () async {
    var calls = 0;
    final notifier = LyricNotifier((music) async {
      calls++;
      return _lyrics(music.platform);
    });
    addTearDown(notifier.dispose);

    await notifier.select(MusicItem(
      id: 'A',
      name: 'A',
      singer: 'artist',
      source: 'custom',
      platform: 'custom',
    ));
    await notifier.select(MusicItem(
      id: 'A',
      songmid: 'qq-mid',
      name: 'A',
      singer: 'artist',
      source: 'custom',
      platform: 'tx',
    ));

    expect(calls, 2);
    expect(notifier.state.lyrics.raw, 'tx');
  });

  test('current error is state and retry starts a new successful generation',
      () async {
    final failure = StateError('current failure');
    var calls = 0;
    final notifier = LyricNotifier((_) async {
      if (calls++ == 0) throw failure;
      return _lyrics('retried');
    });
    addTearDown(notifier.dispose);

    await notifier.select(_music('A'));

    expect(notifier.state.lyrics.isEmpty, isTrue);
    expect(notifier.state.isLoading, isFalse);
    expect(notifier.state.error, same(failure));

    await notifier.retry();

    expect(calls, 2);
    expect(notifier.state.lyrics.raw, 'retried');
    expect(notifier.state.error, isNull);
  });

  test('stale success and error do not publish or escape their zone', () async {
    final failures = <Object>[];
    late LyricNotifier notifier;

    await runZonedGuarded(() async {
      final first = Completer<Lyrics>();
      final second = Completer<Lyrics>();
      final third = Completer<Lyrics>();
      notifier = LyricNotifier((music) {
        if (music.id == 'A') return first.future;
        if (music.id == 'B') return second.future;
        return third.future;
      });
      unawaited(notifier.select(_music('A')));
      unawaited(notifier.select(_music('B')));
      unawaited(notifier.select(_music('C')));
      third.complete(_lyrics('C'));
      await pumpEventQueue();
      first.complete(_lyrics('A'));
      second.completeError(StateError('stale failure'));
      await pumpEventQueue();
    }, (error, _) => failures.add(error));
    addTearDown(notifier.dispose);

    expect(notifier.state.lyrics.raw, 'C');
    expect(notifier.state.error, isNull);
    expect(failures, isEmpty);
  });

  test('disposed success and error do not publish or escape their zone',
      () async {
    final failures = <Object>[];

    await runZonedGuarded(() async {
      final success = Completer<Lyrics>();
      final error = Completer<Lyrics>();
      final successNotifier = LyricNotifier((_) => success.future);
      final errorNotifier = LyricNotifier((_) => error.future);
      unawaited(successNotifier.select(_music('A')));
      unawaited(errorNotifier.select(_music('B')));
      successNotifier.dispose();
      errorNotifier.dispose();
      success.complete(_lyrics('A'));
      error.completeError(StateError('disposed failure'));
      await pumpEventQueue();
    }, (failure, _) => failures.add(failure));

    expect(failures, isEmpty);
  });

  test('provider listener publishes current error and retry succeeds safely',
      () async {
    final selectedMusicProvider = StateProvider<MusicItem?>((_) => _music('A'));
    final failure = StateError('provider failure');
    final escaped = <Object>[];
    var calls = 0;
    late ProviderContainer container;

    await runZonedGuarded(() async {
      container = ProviderContainer(
        overrides: [
          currentMusicProvider.overrideWith(
            (ref) => ref.watch(selectedMusicProvider),
          ),
          lyricLoaderProvider.overrideWithValue((_) async {
            if (calls++ == 0) throw failure;
            return _lyrics('retried');
          }),
        ],
      );
      container.listen(currentLyricLoadProvider, (_, __) {},
          fireImmediately: true);
      await pumpEventQueue();
    }, (error, _) => escaped.add(error));
    addTearDown(container.dispose);

    expect(container.read(currentLyricLoadProvider).error, same(failure));
    await container.read(currentLyricLoadProvider.notifier).retry();
    expect(container.read(currentLyricLoadProvider).lyrics.raw, 'retried');
    expect(container.read(currentLyricLoadProvider).error, isNull);
    expect(calls, 2);
    expect(escaped, isEmpty);
  });
}

MusicItem _music(String id) => MusicItem(
      id: id,
      name: id,
      singer: 'artist',
      source: 'tx',
      platform: 'tx',
    );

Lyrics _lyrics(String value) => Lyrics(
      raw: value,
      lines: [LyricLine(time: Duration.zero, text: value)],
    );
