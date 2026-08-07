import 'music_item.dart';

/// 退出前可恢复的播放会话：歌单/队列 + 当前歌曲，不保存播放进度。
class PlaybackSession {
  const PlaybackSession({
    this.playlistId,
    required this.startIndex,
    required this.song,
    this.queue = const [],
  });

  final String? playlistId;
  final int startIndex;
  final MusicItem song;
  final List<MusicItem> queue;

  Map<String, dynamic> toJson() {
    return {
      'playlistId': playlistId,
      'startIndex': startIndex,
      'song': song.toJson(),
      'queue': [for (final item in queue) item.toJson()],
    };
  }

  factory PlaybackSession.fromJson(Map<String, dynamic> json) {
    final rawSong = json['song'];
    final rawQueue = json['queue'];
    return PlaybackSession(
      playlistId: json['playlistId']?.toString(),
      startIndex: (json['startIndex'] as num?)?.toInt() ?? 0,
      song: MusicItem.fromJson(
        rawSong is Map
            ? Map<String, dynamic>.from(rawSong)
            : const <String, dynamic>{},
      ),
      queue: rawQueue is List
          ? [
              for (final item in rawQueue)
                if (item is Map)
                  MusicItem.fromJson(Map<String, dynamic>.from(item)),
            ]
          : const [],
    );
  }
}
