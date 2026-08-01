import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/lyric.dart';
import '../domain/lyric_service.dart';
import '../../player/domain/music_item.dart';
import '../../player/presentation/player_provider.dart';
import '../../search/presentation/search_provider.dart';

final lyricServiceProvider = Provider<LyricService>((ref) {
  // 注入 MusicSourceService 以支持统一的歌词获取逻辑
  final musicSourceService = ref.watch(musicSourceServiceProvider);
  return LyricService(musicSourceService);
});

typedef LyricLoader = Future<Lyrics> Function(MusicItem music);

final lyricLoaderProvider = Provider<LyricLoader>((ref) {
  return ref.read(lyricServiceProvider).fetchLyric;
});

final currentLyricLoadProvider =
    StateNotifierProvider<LyricNotifier, LyricLoadState>((ref) {
  final notifier = LyricNotifier(ref.read(lyricLoaderProvider));
  ref.listen<MusicItem?>(currentMusicProvider, (_, next) {
    notifier.select(next).ignore();
  }, fireImmediately: true);
  return notifier;
});

final currentLyricProvider = Provider<Lyrics>((ref) {
  return ref.watch(currentLyricLoadProvider).lyrics;
});

class LyricLoadState {
  const LyricLoadState({
    required this.lyrics,
    this.isLoading = false,
    this.error,
    this.stackTrace,
  });

  factory LyricLoadState.empty() => LyricLoadState(lyrics: Lyrics.empty());

  final Lyrics lyrics;
  final bool isLoading;
  final Object? error;
  final StackTrace? stackTrace;
}

class LyricNotifier extends StateNotifier<LyricLoadState> {
  LyricNotifier(this._load) : super(LyricLoadState.empty());

  final LyricLoader _load;
  int _generation = 0;
  MusicItem? _selectedMusic;
  String? _selectedSongId;

  Future<void> select(MusicItem? music) async {
    // 同一首歌的元数据刷新（如封面下载后 patchQueueArtUri 触发 mediaItem
    // 变化）不应清空并重新加载歌词，否则逐字歌词会在播放中突然消失。
    if (music?.id == _selectedSongId && state.lyrics.isNotEmpty) {
      _selectedMusic = music;
      return;
    }
    final generation = ++_generation;
    _selectedMusic = music;
    _selectedSongId = music?.id;
    state = LyricLoadState(
      lyrics: Lyrics.empty(),
      isLoading: music != null,
    );
    if (music == null) return;

    try {
      final lyrics = await _load(music);
      if (!_owns(generation, music.id)) return;
      state = LyricLoadState(lyrics: lyrics);
    } catch (error, stackTrace) {
      if (!_owns(generation, music.id)) return;
      state = LyricLoadState(
        lyrics: Lyrics.empty(),
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> retry() async {
    final music = _selectedMusic;
    if (music == null) return;
    await select(music);
  }

  bool _owns(int generation, String songId) {
    return mounted && generation == _generation && songId == _selectedSongId;
  }

  @override
  void dispose() {
    _generation++;
    _selectedMusic = null;
    _selectedSongId = null;
    super.dispose();
  }
}

// 当前行索引
final currentLineIndexProvider = Provider<int>((ref) {
  final position = ref.watch(playerPositionProvider);
  final lyrics = ref.watch(currentLyricProvider);

  final pos = position;
  return lyrics.getCurrentLineIndex(pos);
});
