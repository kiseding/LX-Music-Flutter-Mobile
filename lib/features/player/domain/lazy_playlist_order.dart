import 'dart:math';

import 'music_item.dart';

final class LazyPlaylistOrder {
  LazyPlaylistOrder({
    required int length,
    required int initialIndex,
    required bool shuffle,
    Random? random,
  }) : _indices = _buildIndices(
          length: length,
          initialIndex: initialIndex,
          shuffle: shuffle,
          random: random ?? Random(),
        );

  final List<int> _indices;
  int _cursor = 0;

  int? takeNext() {
    if (_cursor >= _indices.length) return null;
    return _indices[_cursor++];
  }

  static List<int> _buildIndices({
    required int length,
    required int initialIndex,
    required bool shuffle,
    required Random random,
  }) {
    if (length <= 0) return const [];
    final safeIndex = initialIndex.clamp(0, length - 1).toInt();
    if (!shuffle) {
      return List<int>.generate(
        length - safeIndex,
        (index) => safeIndex + index,
      );
    }

    final remaining = List<int>.generate(length, (index) => index)
      ..remove(safeIndex);
    for (var index = remaining.length - 1; index > 0; index--) {
      final other = random.nextInt(index + 1);
      final value = remaining[index];
      remaining[index] = remaining[other];
      remaining[other] = value;
    }
    return [safeIndex, ...remaining];
  }
}

/// Retains only a small number of decoded playlist pages while preserving a
/// complete sequential or shuffled order of playlist indexes.
final class LazyPlaylistWindow {
  LazyPlaylistWindow({
    required this.length,
    required int initialIndex,
    required bool shuffle,
    required this.loadPage,
    this.pageSize = 100,
    this.maxCachedPages = 4,
    Random? random,
  })  : assert(pageSize > 0),
        assert(maxCachedPages > 0),
        _random = random ?? Random() {
    _restart(
      initialIndex: initialIndex,
      shuffle: shuffle,
      includeCurrent: true,
    );
  }

  final int length;
  final Future<List<MusicItem>> Function(int offset, int limit) loadPage;
  final int pageSize;
  final int maxCachedPages;
  final Random _random;
  final Map<int, List<MusicItem>> _pages = {};
  late LazyPlaylistOrder _order;
  int? _lastLoadedIndex;

  int? get lastLoadedIndex => _lastLoadedIndex;

  Future<List<MusicItem>> take(int count) async {
    return (await takeEntries(count)).map((entry) => entry.song).toList();
  }

  Future<List<LazyPlaylistEntry>> takeEntries(int count) async {
    if (count <= 0 || length <= 0) return const [];
    final entries = <LazyPlaylistEntry>[];
    while (entries.length < count) {
      final index = _order.takeNext();
      if (index == null) break;
      entries.add(LazyPlaylistEntry(index, await _songAt(index)));
      _lastLoadedIndex = index;
    }
    return entries;
  }

  Future<List<MusicItem>> restartAfterCurrent({
    required int currentIndex,
    required bool shuffle,
    required int count,
  }) async {
    _restart(
      initialIndex: currentIndex,
      shuffle: shuffle,
      includeCurrent: false,
    );
    _lastLoadedIndex = currentIndex;
    return take(count);
  }

  Future<List<LazyPlaylistEntry>> restartEntriesAfterCurrent({
    required int currentIndex,
    required bool shuffle,
    required int count,
  }) async {
    _restart(
      initialIndex: currentIndex,
      shuffle: shuffle,
      includeCurrent: false,
    );
    _lastLoadedIndex = currentIndex;
    return takeEntries(count);
  }

  Future<List<LazyPlaylistEntry>> restartFromBeginning({
    required bool shuffle,
    required int count,
  }) async {
    _restart(initialIndex: 0, shuffle: shuffle, includeCurrent: true);
    return takeEntries(count);
  }

  void _restart({
    required int initialIndex,
    required bool shuffle,
    required bool includeCurrent,
  }) {
    _order = LazyPlaylistOrder(
      length: length,
      initialIndex: initialIndex,
      shuffle: shuffle,
      random: _random,
    );
    if (!includeCurrent) _order.takeNext();
  }

  Future<MusicItem> _songAt(int index) async {
    final offset = (index ~/ pageSize) * pageSize;
    var page = _pages.remove(offset);
    page ??= await loadPage(offset, pageSize);
    _pages[offset] = page;
    while (_pages.length > maxCachedPages) {
      _pages.remove(_pages.keys.first);
    }
    final pageIndex = index - offset;
    if (pageIndex < 0 || pageIndex >= page.length) {
      throw StateError('Playlist page $offset does not contain song $index');
    }
    return page[pageIndex];
  }
}

final class LazyPlaylistEntry {
  const LazyPlaylistEntry(this.index, this.song);

  final int index;
  final MusicItem song;
}
