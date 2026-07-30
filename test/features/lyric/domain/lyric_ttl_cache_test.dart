import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/storage/ttl_cache.dart';
import 'package:lx_music_flutter/features/lyric/domain/lyric.dart';
import 'package:lx_music_flutter/features/lyric/domain/lyric_service.dart';
import 'package:lx_music_flutter/features/player/domain/music_item.dart';

void main() {
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
