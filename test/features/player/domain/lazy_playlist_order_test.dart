import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/features/player/domain/music_item.dart';
import 'package:lx_music_flutter/features/player/domain/lazy_playlist_order.dart';

void main() {
  test('shuffle order visits every song once without loading song objects', () {
    final order = LazyPlaylistOrder(
      length: 1000,
      initialIndex: 517,
      shuffle: true,
      random: Random(7),
    );
    final indices = <int>[];
    for (
      int? index = order.takeNext();
      index != null;
      index = order.takeNext()
    ) {
      indices.add(index);
    }

    expect(indices, hasLength(1000));
    expect(indices.first, 517);
    expect(indices.toSet(), hasLength(1000));
  });

  test(
    'lazy shuffle loads only the pages needed for its playback window',
    () async {
      final requestedPages = <int>[];
      final window = LazyPlaylistWindow(
        length: 1000,
        initialIndex: 517,
        shuffle: true,
        random: Random(7),
        loadPage: (offset, limit) async {
          requestedPages.add(offset);
          return List.generate(
            limit,
            (index) => MusicItem(
              id: '${offset + index}',
              name: 'Song ${offset + index}',
              singer: 'Singer',
              source: 'test',
            ),
          );
        },
      );

      final songs = await window.take(12);

      expect(songs, hasLength(12));
      expect(songs.first.id, '517');
      expect(songs.map((song) => song.id).toSet(), hasLength(12));
      expect(requestedPages.toSet().length, lessThanOrEqualTo(12));
      expect(requestedPages, isNot(contains(0)));
    },
  );

  test(
    'restart after current continues without replaying the current song',
    () async {
      final window = LazyPlaylistWindow(
        length: 10,
        initialIndex: 3,
        shuffle: false,
        loadPage: (offset, limit) async => List.generate(
          limit,
          (index) => MusicItem(
            id: '${offset + index}',
            name: 'Song ${offset + index}',
            singer: 'Singer',
            source: 'test',
          ),
        ),
      );

      final first = await window.take(5);
      final next = await window.restartAfterCurrent(
        currentIndex: 7,
        shuffle: false,
        count: 4,
      );

      expect(first.map((song) => song.id), ['3', '4', '5', '6', '7']);
      expect(next.map((song) => song.id), ['8', '9']);
    },
  );

  test(
    'restart from beginning repeats the whole playlist after the end',
    () async {
      final window = LazyPlaylistWindow(
        length: 5,
        initialIndex: 3,
        shuffle: false,
        loadPage: (offset, limit) async => List.generate(
          limit,
          (index) => MusicItem(
            id: '${offset + index}',
            name: 'Song ${offset + index}',
            singer: 'Singer',
            source: 'test',
          ),
        ),
      );

      final first = await window.take(2);
      final next = await window.restartFromBeginning(shuffle: false, count: 3);

      expect(first.map((song) => song.id), ['3', '4']);
      expect(next.map((song) => song.id), ['0', '1', '2']);
    },
  );
}
