import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/music_source/platform/music_platform.dart';
import 'package:lx_music_flutter/features/player/domain/music_item.dart';

void main() {
  test('platform must opt in before legacy URL lookup is treated as exact',
      () async {
    final platform = _LegacyPlatform();
    final music = MusicItem(
      id: 'song',
      name: 'Song',
      singer: 'Singer',
      source: 'legacy',
      platform: 'legacy',
    );

    expect(await platform.getMusicUrlExact(music, quality: 'flac'), isNull);
    expect(platform.legacyCalls, 0);
  });
}

class _LegacyPlatform extends MusicPlatform {
  var legacyCalls = 0;

  @override
  String get id => 'legacy';

  @override
  String get name => 'Legacy';

  @override
  Future<String?> getMusicUrl(MusicItem music,
      {String quality = '128k'}) async {
    legacyCalls++;
    return 'https://media.example/song.mp3';
  }

  @override
  Future<String?> getLyric(MusicItem music) async => null;

  @override
  MusicItem parseItem(Map<String, dynamic> raw, String source) =>
      throw UnimplementedError();

  @override
  Future<List<MusicItem>> search(String keyword,
          {int page = 1, int limit = 20}) async =>
      [];
}
