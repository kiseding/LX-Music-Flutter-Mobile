import '../../player/domain/music_item.dart';
import 'smart_playlist.dart';

/// 智能歌单匹配引擎：给定规则定义和候选歌曲，返回命中的歌曲列表。
/// 纯内存过滤，几千首歌 × 几条规则在几十 ms 内完成。
class SmartPlaylistEngine {
  const SmartPlaylistEngine({
    required this.songs,
    required this.playStats,
    required this.playlistMembership,
  });

  /// 候选歌曲（所有歌单去重后的并集）。
  final List<MusicItem> songs;

  /// 播放历史聚合 {songId -> 播放次数} / {songId -> 最近播放时间}。
  final ({
    Map<String, int> countBySongId,
    Map<String, DateTime> lastPlayedBySongId,
  }) playStats;

  /// songId -> 所属歌单 id 集合。
  final Map<String, Set<String>> playlistMembership;

  List<MusicItem> match(SmartPlaylist smart) {
    final activeGroups = smart.groups.where((g) => g.rules.isNotEmpty).toList();
    final matched = activeGroups.isEmpty
        ? List<MusicItem>.of(songs)
        : songs.where((song) {
            final groupMatches = <bool>[];
            for (final group in activeGroups) {
              final m = _evaluateGroup(group, song);
              groupMatches.add(group.isExcluded ? !m : m);
            }
            return switch (smart.groupCombinator) {
              SmartPlaylistCombinator.and =>
                groupMatches.every((m) => m),
              SmartPlaylistCombinator.or => groupMatches.any((m) => m),
            };
          }).toList();
    return _sortAndLimit(matched, smart);
  }

  bool _evaluateGroup(SmartPlaylistRuleGroup group, MusicItem song) {
    final results = group.rules.map((r) => _evaluateRule(r, song));
    return switch (group.combinator) {
      SmartPlaylistCombinator.and => results.every((r) => r),
      SmartPlaylistCombinator.or => results.any((r) => r),
    };
  }

  bool _evaluateRule(SmartPlaylistRule rule, MusicItem song) {
    switch (rule.field) {
      case SmartPlaylistField.title:
        return _compareString(song.name, rule);
      case SmartPlaylistField.artist:
        return _compareString(song.singer, rule);
      case SmartPlaylistField.album:
        return _compareString(song.album, rule);
      case SmartPlaylistField.platform:
        return _compareString(song.platform, rule);
      case SmartPlaylistField.duration:
        return _compareDouble(song.duration.inSeconds.toDouble(), rule);
      case SmartPlaylistField.playCount:
        return _compareInt(playStats.countBySongId[song.id] ?? 0, rule);
      case SmartPlaylistField.lastPlayedAt:
        return _compareDate(playStats.lastPlayedBySongId[song.id], rule);
      case SmartPlaylistField.isInPlaylist:
        final inSet = playlistMembership[song.id]?.contains(rule.value) ?? false;
        return switch (rule.op) {
          SmartPlaylistOp.equals => inSet,
          SmartPlaylistOp.notEquals => !inSet,
          _ => false,
        };
    }
  }

  bool _compareString(String value, SmartPlaylistRule rule) {
    final v = value.toLowerCase();
    final t = rule.value.trim().toLowerCase();
    switch (rule.op) {
      case SmartPlaylistOp.equals:
        return v == t;
      case SmartPlaylistOp.notEquals:
        return v != t;
      case SmartPlaylistOp.contains:
        return t.isEmpty || v.contains(t);
      case SmartPlaylistOp.notContains:
        return !v.contains(t);
      case SmartPlaylistOp.greaterThan:
      case SmartPlaylistOp.lessThan:
        return false;
    }
  }

  bool _compareInt(int value, SmartPlaylistRule rule) {
    final target = int.tryParse(rule.value);
    switch (rule.op) {
      case SmartPlaylistOp.equals:
        return target != null && value == target;
      case SmartPlaylistOp.notEquals:
        return target != null && value != target;
      case SmartPlaylistOp.greaterThan:
        return target != null && value > target;
      case SmartPlaylistOp.lessThan:
        return target != null && value < target;
      case SmartPlaylistOp.contains:
      case SmartPlaylistOp.notContains:
        return false;
    }
  }

  bool _compareDouble(double value, SmartPlaylistRule rule) {
    final target = double.tryParse(rule.value);
    switch (rule.op) {
      case SmartPlaylistOp.equals:
        return target != null && (target - value).abs() < 0.0001;
      case SmartPlaylistOp.notEquals:
        return target != null && (target - value).abs() >= 0.0001;
      case SmartPlaylistOp.greaterThan:
        return target != null && value > target;
      case SmartPlaylistOp.lessThan:
        return target != null && value < target;
      case SmartPlaylistOp.contains:
      case SmartPlaylistOp.notContains:
        return false;
    }
  }

  bool _compareDate(DateTime? value, SmartPlaylistRule rule) {
    if (value == null) return false;
    final threshold = _parseDate(rule.value);
    if (threshold == null) return false;
    switch (rule.op) {
      case SmartPlaylistOp.equals:
      case SmartPlaylistOp.greaterThan:
        return value.isAfter(threshold) || value.isAtSameMomentAs(threshold);
      case SmartPlaylistOp.notEquals:
      case SmartPlaylistOp.lessThan:
        return value.isBefore(threshold);
      case SmartPlaylistOp.contains:
      case SmartPlaylistOp.notContains:
        return false;
    }
  }

  /// 支持 ISO8601 或相对天数 "days:N"（最近 N 天内）。
  DateTime? _parseDate(String text) {
    if (text.startsWith('days:')) {
      final days = int.tryParse(text.substring('days:'.length));
      if (days != null && days >= 0) {
        return DateTime.now().subtract(Duration(days: days));
      }
      return null;
    }
    return DateTime.tryParse(text);
  }

  List<MusicItem> _sortAndLimit(List<MusicItem> matched, SmartPlaylist smart) {
    var result = matched;
    if (smart.sortField == SmartPlaylistSortField.random) {
      result = List<MusicItem>.of(result)..shuffle();
    } else {
      result = List<MusicItem>.of(result)
        ..sort((a, b) => _compare(a, b, smart.sortField));
      if (smart.sortDirection == SmartPlaylistSortDirection.desc) {
        result = result.reversed.toList();
      }
    }
    if (smart.limit != null && result.length > smart.limit!) {
      result = result.take(smart.limit!).toList();
    }
    return result;
  }

  int _compare(MusicItem a, MusicItem b, SmartPlaylistSortField field) {
    switch (field) {
      case SmartPlaylistSortField.title:
        return a.name.compareTo(b.name);
      case SmartPlaylistSortField.artist:
        return a.singer.compareTo(b.singer);
      case SmartPlaylistSortField.album:
        return a.album.compareTo(b.album);
      case SmartPlaylistSortField.duration:
        return a.duration.compareTo(b.duration);
      case SmartPlaylistSortField.playCount:
        final ca = playStats.countBySongId[a.id] ?? 0;
        final cb = playStats.countBySongId[b.id] ?? 0;
        return ca.compareTo(cb);
      case SmartPlaylistSortField.lastPlayedAt:
        final la = playStats.lastPlayedBySongId[a.id];
        final lb = playStats.lastPlayedBySongId[b.id];
        final da = la ?? DateTime.fromMillisecondsSinceEpoch(0);
        final db = lb ?? DateTime.fromMillisecondsSinceEpoch(0);
        return da.compareTo(db);
      case SmartPlaylistSortField.random:
        return 0;
    }
  }
}
