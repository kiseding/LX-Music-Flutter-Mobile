import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/features/player/domain/music_item.dart';
import 'package:lx_music_flutter/features/search/presentation/search_provider.dart';

void main() {
  test('late first-page result cannot overwrite a newer query', () async {
    final first = Completer<List<MusicItem>>();
    final second = Completer<List<MusicItem>>();
    var source = 'tx';
    final notifier = SearchNotifier(
      (query, sourceId, page) => query == 'old' ? first.future : second.future,
      () => source,
    );
    addTearDown(notifier.dispose);

    final oldSearch = notifier.search('old');
    source = 'kw';
    final newSearch = notifier.search('new');
    second.complete([_item('new')]);
    await newSearch;
    first.complete([_item('old')]);
    await oldSearch;

    expect(notifier.state.query, 'new');
    expect(notifier.state.sourceId, 'kw');
    expect(notifier.state.generation, 2);
    expect(notifier.state.items.single.id, 'new');
  });

  test('loadMore uses state query and source snapshots', () async {
    final calls = <({String query, String source, int page})>[];
    var selectedSource = 'tx';
    final notifier = SearchNotifier((query, source, page) async {
      calls.add((query: query, source: source, page: page));
      return List.generate(20, (index) => _item('$query-$page-$index'));
    }, () => selectedSource);
    addTearDown(notifier.dispose);

    await notifier.search('stored');
    selectedSource = 'wy';
    await notifier.loadMore();

    expect(calls, [
      (query: 'stored', source: 'tx', page: 1),
      (query: 'stored', source: 'tx', page: 2),
    ]);
    expect(notifier.state.page, 2);
    expect(notifier.state.items, hasLength(40));
  });

  test('concurrent loadMore calls share the in-flight page', () async {
    final pageTwo = Completer<List<MusicItem>>();
    var pageTwoCalls = 0;
    final notifier = SearchNotifier((query, source, page) async {
      if (page == 1) {
        return List.generate(20, (index) => _item('first-$index'));
      }
      pageTwoCalls++;
      return pageTwo.future;
    }, () => 'tx');
    addTearDown(notifier.dispose);
    await notifier.search('stored');

    final firstLoadMore = notifier.loadMore();
    final duplicateLoadMore = notifier.loadMore();
    pageTwo.complete([_item('more')]);
    await Future.wait([firstLoadMore, duplicateLoadMore]);

    expect(pageTwoCalls, 1);
    expect(notifier.state.page, 2);
  });

  test('reset invalidates an in-flight request', () async {
    final result = Completer<List<MusicItem>>();
    final notifier = SearchNotifier(
      (query, source, page) => result.future,
      () => 'tx',
    );
    addTearDown(notifier.dispose);

    final search = notifier.search('old');
    notifier.reset();
    result.complete([_item('old')]);
    await search;

    expect(notifier.state.query, isEmpty);
    expect(notifier.state.items, isEmpty);
    expect(notifier.state.isLoading, isFalse);
  });

  test('stale error cannot overwrite a newer success', () async {
    final first = Completer<List<MusicItem>>();
    final second = Completer<List<MusicItem>>();
    final notifier = SearchNotifier(
      (query, source, page) => query == 'old' ? first.future : second.future,
      () => 'tx',
    );
    addTearDown(notifier.dispose);

    final oldSearch = notifier.search('old');
    final newSearch = notifier.search('new');
    second.complete([_item('new')]);
    await newSearch;
    first.completeError(StateError('stale failure'));
    await oldSearch;

    expect(notifier.state.items.single.id, 'new');
    expect(notifier.state.error, isNull);
  });

  test('current error is stored and search future does not throw', () async {
    final notifier = SearchNotifier(
      (query, source, page) => Future.error(StateError('network failure')),
      () => 'tx',
    );
    addTearDown(notifier.dispose);

    await expectLater(notifier.search('current'), completes);

    expect(notifier.state.query, 'current');
    expect(notifier.state.sourceId, 'tx');
    expect(notifier.state.isLoading, isFalse);
    expect(notifier.state.error, contains('network failure'));
  });

  test('dispose invalidates an in-flight request without async errors',
      () async {
    final result = Completer<List<MusicItem>>();
    final notifier = SearchNotifier(
      (query, source, page) => result.future,
      () => 'tx',
    );

    final search = notifier.search('old');
    notifier.dispose();
    result.complete([_item('old')]);

    await expectLater(search, completes);
  });
}

MusicItem _item(String id) => MusicItem(
      id: id,
      name: id,
      singer: 'artist',
      source: 'tx',
      platform: 'tx',
    );
