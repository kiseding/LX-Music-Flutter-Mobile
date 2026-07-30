import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'lyric.dart';
import '../data/lyric_parser.dart';
import '../../player/domain/music_item.dart';
import '../../../core/network/music_source_service.dart';
import '../../../core/network/outbound_url.dart';
import '../../../core/storage/ttl_cache.dart';

class LyricService {
  final Dio _dio = Dio();
  final MusicSourceService? _musicSourceService;
  final TtlCache<Lyrics> _cache;

  LyricService([
    this._musicSourceService,
    TtlCache<Lyrics>? cache,
  ]) : _cache = cache ??
            TtlCache<Lyrics>(ttl: TtlCache.defaultTtl);

  Future<Lyrics> fetchLyric(MusicItem music) async {
    debugPrint(
        '[LyricService] fetchLyric: ${music.name}, platform=${music.platform}, songmid=${music.songmid}, source=${music.source}');

    final cached = _cache.get(music.id);
    if (cached != null) {
      debugPrint('[LyricService] 命中缓存');
      return cached;
    }

    if (music.lyricsUrl != null && music.lyricsUrl!.isNotEmpty) {
      try {
        debugPrint('[LyricService] 尝试从 lyricsUrl 获取: ${music.lyricsUrl}');
        final response = await _dio.get(normalizeOutboundUrl(music.lyricsUrl!));
        if (response.statusCode == 200 && response.data is String) {
          final lyrics = _parseLyricString(response.data);
          debugPrint('[LyricService] lyricsUrl 获取成功, ${lyrics.lines.length} 行');
          _cache.set(music.id, lyrics);
          return lyrics;
        }
      } catch (e) {
        debugPrint('[LyricService] lyricsUrl 获取失败: $e');
      }
    }

    if (_musicSourceService != null) {
      try {
        debugPrint('[LyricService] 尝试从 MusicSourceService 获取歌词');
        final lyricStr = await _musicSourceService.getLyric(music);
        if (lyricStr != null && lyricStr.isNotEmpty) {
          final lyrics = _parseLyricString(lyricStr);
          debugPrint(
              '[LyricService] MusicSourceService 获取成功, ${lyrics.lines.length} 行');
          _cache.set(music.id, lyrics);
          return lyrics;
        } else {
          debugPrint('[LyricService] MusicSourceService 返回空');
        }
      } catch (e) {
        debugPrint('[LyricService] MusicSourceService 获取失败: $e');
      }
    }

    debugPrint('[LyricService] 所有途径均失败，返回空歌词');
    return Lyrics.empty();
  }

  void clearCache() {
    _cache.clear();
  }

  Lyrics _parseLyricString(String lyricStr) {
    // 有逐字标签时优先走能保留 words 的解析
    if (LyricParser.hasWordTiming(lyricStr)) {
      final hasLrcTimeTag =
          RegExp(r'\[\d{2}:\d{2}[\.\d]*\]').hasMatch(lyricStr);
      if (hasLrcTimeTag) {
        // LRC + LRCX/QRC 字标签：parseLrc 已支持字级
        return LyricParser.parseLrc(lyricStr);
      }
      return LyricParser.parseQrc(lyricStr);
    }

    final hasLrcTimeTag = RegExp(r'\[\d{2}:\d{2}[\.\d]*\]').hasMatch(lyricStr);
    if (hasLrcTimeTag) {
      return LyricParser.parseLrc(lyricStr);
    }
    return LyricParser.parseQrc(lyricStr);
  }

  Lyrics parseLrc(String lrc) => LyricParser.parseLrc(lrc);

  Lyrics parseQrc(String qrc) => LyricParser.parseQrc(qrc);

  void dispose() {
    _dio.close();
  }
}
