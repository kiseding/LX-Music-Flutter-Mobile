import '../../player/domain/music_item.dart';

/// 重复歌曲分组：按 (标题, 歌手, 时长±2s) 指纹分组，每组超过 1 首视为重复。
class DuplicateGroup {
  const DuplicateGroup({
    required this.id,
    required this.title,
    required this.artist,
    required this.bestSong,
    required this.songs,
  });

  final String id;
  final String title;
  final String artist;
  final MusicItem bestSong;
  final List<MusicItem> songs;

  List<MusicItem> get redundantSongs => songs.skip(1).toList();
  int get count => songs.length;
}

class DuplicateDetector {
  DuplicateDetector({
    required this.songs,
    required this.favoriteIds,
  });

  final List<MusicItem> songs;
  final Set<String> favoriteIds;

  static const int durationBucketSec = 2;

  List<DuplicateGroup> detect() {
    final grouped = <_DuplicateKey, List<MusicItem>>{};
    for (final song in songs) {
      final key = _DuplicateKey(
        title: _normalize(song.name),
        artist: _normalize(song.singer),
        durationBucket:
            (song.duration.inSeconds / durationBucketSec).floor(),
      );
      grouped.putIfAbsent(key, () => []).add(song);
    }

    final result = grouped.entries
        .where((e) => e.value.length > 1 && e.key.title.isNotEmpty)
        .map((e) {
      final members = List<MusicItem>.of(e.value)
        ..sort((a, b) => _qualityScore(b).compareTo(_qualityScore(a)));
      return DuplicateGroup(
        id: '${e.key.title}|${e.key.artist}|${e.key.durationBucket}',
        title: members.first.name,
        artist: members.first.singer,
        bestSong: members.first,
        songs: members,
      );
    }).toList()
      ..sort((a, b) => a.title.compareTo(b.title));
    return result;
  }

  /// 质量评分（推荐保留分高的）。在线歌曲无 bitrate/格式信息，
  /// 用收藏状态 + 元数据完整度近似。
  int _qualityScore(MusicItem song) {
    var score = 0;
    if (favoriteIds.contains(song.id)) score += 1000;
    if ((song.lyricsUrl?.isNotEmpty ?? false)) score += 100;
    if ((song.artwork?.isNotEmpty ?? false)) score += 50;
    if ((song.songmid?.isNotEmpty ?? false)) score += 20;
    if ((song.hash?.isNotEmpty ?? false)) score += 20;
    if ((song.url?.isNotEmpty ?? false)) score += 10;
    return score;
  }

  static String _normalize(String s) => s
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), ' ');
}

class _DuplicateKey {
  const _DuplicateKey({
    required this.title,
    required this.artist,
    required this.durationBucket,
  });

  final String title;
  final String artist;
  final int durationBucket;

  @override
  bool operator ==(Object other) =>
      other is _DuplicateKey &&
      other.title == title &&
      other.artist == artist &&
      other.durationBucket == durationBucket;

  @override
  int get hashCode => Object.hash(title, artist, durationBucket);
}
