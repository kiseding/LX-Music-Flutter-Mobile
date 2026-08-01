import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/storage/storage_service.dart';

/// 单条播放事件。
class PlayHistoryEntry {
  const PlayHistoryEntry({
    required this.songId,
    required this.songTitle,
    required this.artistName,
    required this.albumTitle,
    required this.playedAt,
    required this.listenedSec,
    required this.source,
  });

  final String songId;
  final String songTitle;
  final String artistName;
  final String albumTitle;
  final DateTime playedAt;
  final double listenedSec;
  final String source;

  String get id => '$songId-${playedAt.millisecondsSinceEpoch}';

  Map<String, dynamic> toJson() => {
        'songId': songId,
        'songTitle': songTitle,
        'artistName': artistName,
        'albumTitle': albumTitle,
        'playedAt': playedAt.millisecondsSinceEpoch,
        'listenedSec': listenedSec,
        'source': source,
      };

  static PlayHistoryEntry fromJson(Map<String, dynamic> json) {
    return PlayHistoryEntry(
      songId: json['songId']?.toString() ?? '',
      songTitle: json['songTitle']?.toString() ?? '',
      artistName: json['artistName']?.toString() ?? '',
      albumTitle: json['albumTitle']?.toString() ?? '',
      playedAt: DateTime.fromMillisecondsSinceEpoch(
        (json['playedAt'] as num?)?.toInt() ?? 0,
      ),
      listenedSec: (json['listenedSec'] as num?)?.toDouble() ?? 0,
      source: json['source']?.toString() ?? '',
    );
  }
}

enum StatsRange { week, month, year, all }

extension StatsRangeX on StatsRange {
  String get label => switch (this) {
        StatsRange.week => '本周',
        StatsRange.month => '本月',
        StatsRange.year => '今年',
        StatsRange.all => '全部',
      };

  DateTime startDate(DateTime now) {
    return switch (this) {
      StatsRange.week => now.subtract(const Duration(days: 7)),
      StatsRange.month => now.subtract(const Duration(days: 30)),
      StatsRange.year => now.subtract(const Duration(days: 365)),
      StatsRange.all => DateTime.fromMillisecondsSinceEpoch(0),
    };
  }
}

class RankedItem {
  const RankedItem({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.playCount,
    required this.totalSec,
  });

  final String id;
  final String title;
  final String subtitle;
  final int playCount;
  final double totalSec;
}

/// 本地播放历史 — 三段式 session（begin/tick/end），低于阈值不记录。
/// append-only JSON，滚动保留最近 [maxEntries] 条。
class PlayHistoryStore extends ChangeNotifier {
  PlayHistoryStore(this._storageLoader);

  static const double thresholdSec = 30;
  static const int maxEntries = 5000;
  static const String _storageKey = 'play_history_v1';

  final StorageLoader _storageLoader;
  StorageService? _storage;

  Future<StorageService> _storageAsync() async =>
      _storage ??= await _storageLoader();
  final StreamController<int> _revisionController =
      StreamController<int>.broadcast();
  List<PlayHistoryEntry> _entries = [];
  bool _loaded = false;

  Stream<int> get stream => _revisionController.stream;
  String? get currentSongId => _currentSongId;

  // 当前播放 session
  String? _currentSongId;
  DateTime? _startedAt;
  double _maxElapsedSec = 0;
  String? _currentTitle;
  String? _currentArtist;
  String? _currentAlbum;
  String? _currentSource;
  Timer? _saveDebounce;

  List<PlayHistoryEntry> get entries => List.unmodifiable(_entries);

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final storage = await _storageAsync();
      final list = storage.getJsonList(_storageKey);
      final loaded = list.map(PlayHistoryEntry.fromJson).toList()
        ..sort((a, b) => b.playedAt.compareTo(a.playedAt));
      if (loaded.length > maxEntries) {
        loaded.removeRange(maxEntries, loaded.length);
      }
      _entries = loaded;
      _notify();
    } catch (_) {
      _entries = [];
    }
  }

  // MARK: - Session 生命周期（由播放器接入调用）

  void beginSession({
    required String songId,
    required String songTitle,
    required String artistName,
    required String albumTitle,
    required String source,
  }) {
    endSession();
    _currentSongId = songId;
    _currentTitle = songTitle;
    _currentArtist = artistName;
    _currentAlbum = albumTitle;
    _currentSource = source;
    _startedAt = DateTime.now();
    _maxElapsedSec = 0;
  }

  void tick(Duration position) {
    if (_currentSongId == null) return;
    final elapsed = position.inMilliseconds / 1000.0;
    if (elapsed > _maxElapsedSec) _maxElapsedSec = elapsed;
  }

  void endSession() {
    final songId = _currentSongId;
    final startedAt = _startedAt;
    if (songId == null || startedAt == null) return;
    final title = _currentTitle;
    final artist = _currentArtist;
    final album = _currentAlbum;
    final source = _currentSource;
    _currentSongId = null;
    _startedAt = null;
    _maxElapsedSec = 0;
    _currentTitle = null;
    _currentArtist = null;
    _currentAlbum = null;
    _currentSource = null;
    if (_maxElapsedSec < thresholdSec) return;
    record(
      songId: songId,
      songTitle: title ?? '',
      artistName: artist ?? '',
      albumTitle: album ?? '',
      source: source ?? '',
      startedAt: startedAt,
      listenedSec: _maxElapsedSec,
    );
  }

  void record({
    required String songId,
    required String songTitle,
    required String artistName,
    required String albumTitle,
    required String source,
    required DateTime startedAt,
    required double listenedSec,
  }) {
    if (listenedSec < thresholdSec) return;
    _entries.insert(
      0,
      PlayHistoryEntry(
        songId: songId,
        songTitle: songTitle,
        artistName: artistName,
        albumTitle: albumTitle,
        playedAt: startedAt,
        listenedSec: listenedSec,
        source: source,
      ),
    );
    if (_entries.length > maxEntries) {
      _entries.removeRange(maxEntries, _entries.length);
    }
    _scheduleSave();
    _notify();
  }

  Future<void> clearAll() async {
    _entries.clear();
    await (await _storageAsync()).setJsonList(_storageKey, const []);
    _notify();
  }

  // MARK: - 查询 / 聚合

  List<PlayHistoryEntry> entriesIn(StatsRange range, {DateTime? now}) {
    final cutoff = range.startDate(now ?? DateTime.now());
    return _entries.where((e) => e.playedAt.isAfter(cutoff)).toList();
  }

  List<RankedItem> topSongs(StatsRange range, {int limit = 20, DateTime? now}) {
    final grouped = <String, List<PlayHistoryEntry>>{};
    for (final e in entriesIn(range, now: now)) {
      grouped.putIfAbsent(e.songId, () => []).add(e);
    }
    final items = grouped.entries.map((g) {
      final first = g.value.first;
      return RankedItem(
        id: g.key,
        title: first.songTitle,
        subtitle: first.artistName,
        playCount: g.value.length,
        totalSec: g.value.fold<double>(0, (s, e) => s + e.listenedSec),
      );
    }).toList()
      ..sort((a, b) => b.playCount.compareTo(a.playCount));
    return items.take(limit).toList();
  }

  List<RankedItem> topArtists(StatsRange range, {int limit = 20, DateTime? now}) {
    final grouped = <String, List<PlayHistoryEntry>>{};
    for (final e in entriesIn(range, now: now)) {
      if (e.artistName.isEmpty) continue;
      grouped.putIfAbsent(e.artistName, () => []).add(e);
    }
    final items = grouped.entries.map((g) {
      final uniqueSongs = g.value.map((e) => e.songId).toSet().length;
      return RankedItem(
        id: 'artist:${g.key}',
        title: g.key,
        subtitle: '$uniqueSongs 首',
        playCount: g.value.length,
        totalSec: g.value.fold<double>(0, (s, e) => s + e.listenedSec),
      );
    }).toList()
      ..sort((a, b) => b.playCount.compareTo(a.playCount));
    return items.take(limit).toList();
  }

  List<RankedItem> topAlbums(StatsRange range, {int limit = 20, DateTime? now}) {
    final grouped = <String, List<PlayHistoryEntry>>{};
    for (final e in entriesIn(range, now: now)) {
      if (e.albumTitle.isEmpty) continue;
      grouped.putIfAbsent('${e.albumTitle}|${e.artistName}', () => []).add(e);
    }
    final items = grouped.entries.map((g) {
      final first = g.value.first;
      return RankedItem(
        id: 'album:${g.key}',
        title: first.albumTitle,
        subtitle: first.artistName,
        playCount: g.value.length,
        totalSec: g.value.fold<double>(0, (s, e) => s + e.listenedSec),
      );
    }).toList()
      ..sort((a, b) => b.playCount.compareTo(a.playCount));
    return items.take(limit).toList();
  }

  /// 按天聚合，供热力图使用。
  List<(DateTime, int)> dailyPlayCounts(StatsRange range, {DateTime? now}) {
    final now2 = now ?? DateTime.now();
    final today = DateTime(now2.year, now2.month, now2.day);
    final scoped = entriesIn(range, now: now);
    final counts = <DateTime, int>{};
    for (final e in scoped) {
      final day = DateTime(e.playedAt.year, e.playedAt.month, e.playedAt.day);
      counts[day] = (counts[day] ?? 0) + 1;
    }
    final start = range == StatsRange.all
        ? (scoped.isEmpty
            ? today
            : scoped.map((e) => e.playedAt).reduce((a, b) => a.isBefore(b) ? a : b))
        : range.startDate(now2);
    final floor = today.subtract(const Duration(days: 740));
    var cursor = start.isAfter(floor) ? start : floor;
    cursor = DateTime(cursor.year, cursor.month, cursor.day);
    final result = <(DateTime, int)>[];
    while (!cursor.isAfter(today)) {
      result.add((cursor, counts[cursor] ?? 0));
      cursor = DateTime(cursor.year, cursor.month, cursor.day + 1);
    }
    return result;
  }

  ({int totalPlays, double totalSec, int activeDays, int uniqueSongs}) summary(
    StatsRange range, {
    DateTime? now,
  }) {
    final scoped = entriesIn(range, now: now);
    final days = scoped.map((e) => DateTime(e.playedAt.year, e.playedAt.month, e.playedAt.day)).toSet();
    return (
      totalPlays: scoped.length,
      totalSec: scoped.fold<double>(0, (s, e) => s + e.listenedSec),
      activeDays: days.length,
      uniqueSongs: scoped.map((e) => e.songId).toSet().length,
    );
  }

  // 供 SmartPlaylist 引擎使用的聚合
  ({Map<String, int> countBySongId, Map<String, DateTime> lastPlayedBySongId})
      get playStats {
    final count = <String, int>{};
    final last = <String, DateTime>{};
    for (final e in _entries) {
      count[e.songId] = (count[e.songId] ?? 0) + 1;
      final prev = last[e.songId];
      if (prev == null || e.playedAt.isAfter(prev)) {
        last[e.songId] = e.playedAt;
      }
    }
    return (countBySongId: count, lastPlayedBySongId: last);
  }

  // MARK: - 持久化

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(seconds: 2), () async {
      await (await _storageAsync()).setJsonList(
        _storageKey,
        _entries.map((e) => e.toJson()).toList(),
      );
    });
  }

  void _notify() {
    notifyListeners();
    _revisionController.add(1);
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    _revisionController.close();
    super.dispose();
  }
}
