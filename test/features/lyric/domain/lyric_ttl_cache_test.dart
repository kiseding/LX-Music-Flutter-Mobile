import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/storage/ttl_cache.dart';
import 'package:lx_music_flutter/features/lyric/domain/lyric.dart';
import 'package:lx_music_flutter/features/lyric/domain/lyric_service.dart';
import 'package:lx_music_flutter/features/player/domain/music_item.dart';

void main() {
  test('netease yrc payload parses into word-timed lyrics', () async {
    // 网易云 /api/song/lyric/v1 的 yrc.lyric 为 YRC 字级格式
    const yrc = r'''
[00:05.00]你<0,180>好<180,220>世<400,200>界
[00:09.00]下<0,180>一<180,220>行
''';
    final service = LyricService(null, TtlCache<Lyrics>(ttl: const Duration(hours: 1)));
    final music = MusicItem(
      id: 'yrc-song',
      name: 't',
      singer: 's',
      source: 'wy',
      platform: 'wy',
      lyricsUrl: null,
    );

    final lyrics = await service.fetchLyric(music);
    // 无歌词源时返回空；这里直接走解析路径验证 YRC 识别
    expect(lyrics.lines, isEmpty);

    final parsed = service.parseLrc(yrc);
    expect(parsed.lines.length, 2);
    final first = parsed.lines.first;
    expect(first.hasWordTiming, isTrue);
    expect(first.words!.map((w) => w.text).join(), '你好世界');
    expect(first.words![0].text, '你');
    expect(first.words![1].text, '好');
    expect(first.words![1].duration, const Duration(milliseconds: 220));
    expect(first.words![2].time, const Duration(milliseconds: 5400));
  });

  test('lyric service reuses in-memory cache within 12h ttl', () async {
    var now = DateTime(2026, 7, 30, 10);
    final cache = TtlCache<Lyrics>(
      ttl: const Duration(hours: 12),
      clock: () => now,
    );
    final service = LyricService(null, cache);
    final music = MusicItem(
      id: 'song-1',
      name: 't',
      singer: 's',
      source: 'tx',
      platform: 'tx',
      lyricsUrl: null,
    );

    // Empty path caches nothing useful; seed via set through first empty fetch
    // then put known lyrics into the injected cache and assert hit.
    cache.set(
      music.id,
      Lyrics(
        raw: '[00:00.00]hello',
        lines: const [
          LyricLine(time: Duration.zero, text: 'hello'),
        ],
      ),
    );
    final hit = await service.fetchLyric(music);
    expect(hit.lines.single.text, 'hello');

    now = now.add(const Duration(hours: 13));
    final miss = await service.fetchLyric(music);
    expect(miss.lines, isEmpty);
  });
}
