import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/lyric.dart';
import '../domain/lyric_service.dart';
import '../../player/presentation/player_provider.dart';
import '../../player/domain/music_item.dart';
import '../../search/presentation/search_provider.dart';

final lyricServiceProvider = Provider<LyricService>((ref) {
  // 注入 MusicSourceService 以支持统一的歌词获取逻辑
  final musicSourceService = ref.watch(musicSourceServiceProvider);
  return LyricService(musicSourceService);
});

// 当前歌词
final currentLyricProvider = StateNotifierProvider<LyricNotifier, Lyrics>((ref) {
  return LyricNotifier(ref);
});

class LyricNotifier extends StateNotifier<Lyrics> {
  final Ref _ref;
  String? _lastSongId;

  LyricNotifier(this._ref) : super(Lyrics.empty()) {
    // 监听当前播放歌曲，自动加载歌词
    _ref.listen(currentMusicProvider, (previous, next) {
      if (next != null && next.id != _lastSongId) {
        _lastSongId = next.id;
        loadLyric(next);
      } else if (next == null) {
        state = Lyrics.empty();
        _lastSongId = null;
      }
    });
  }

  Future<void> loadLyric(MusicItem music) async {
    final lyricService = _ref.read(lyricServiceProvider);
    state = Lyrics.empty(); // 重置
    final lyrics = await lyricService.fetchLyric(music);
    state = lyrics;
  }
}

// 当前行索引
final currentLineIndexProvider = Provider<int>((ref) {
  final position = ref.watch(playerPositionProvider);
  final lyrics = ref.watch(currentLyricProvider);
  
  final pos = position;
  return lyrics.getCurrentLineIndex(pos);
});
