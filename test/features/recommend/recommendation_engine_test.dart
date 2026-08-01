import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/features/player/domain/music_item.dart';
import 'package:lx_music_flutter/features/recommend/domain/recommendation_engine.dart';

MusicItem _song(String id, String name, String singer, String album,
    {String platform = 'tx'}) {
  return MusicItem(
    id: id,
    name: name,
    singer: singer,
    album: album,
    duration: const Duration(seconds: 200),
    source: 'x',
    platform: platform,
  );
}

void main() {
  final favorites = [
    _song('f1', '夜曲', '周杰伦', '十一月的萧邦'),
    _song('f2', '晴天', '周杰伦', '叶惠美'),
    _song('f3', '七里香', '周杰伦', '七里香'),
  ];

  final candidates = [
    _song('c1', '稻香', '周杰伦', '魔杰座'),
    _song('c2', '说谎', '林宥嘉', '感官世界'),
    _song('c3', '夜曲', '周杰伦', '十一月的萧邦'), // 与收藏同 id → 应被排除
  ];

  test('recommends same-artist songs first and excludes favorites', () {
    final engine = const RecommendationEngine();
    final recs = engine.recommend(favorites: favorites, candidates: candidates);

    expect(recs, hasLength(2));
    expect(recs.first.song.id, 'c1');
    expect(recs.first.score, greaterThan(recs.last.score));
  });

  test('returns empty when no favorites', () {
    final engine = const RecommendationEngine();
    final recs = engine.recommend(favorites: const [], candidates: candidates);
    expect(recs, isEmpty);
  });

  test('predict rewards artist affinity over platform affinity', () {
    final engine = const RecommendationEngine();
    final profile = engine.buildProfile(favorites);

    final sameArtist = _song('x1', '轨迹', '周杰伦', '其它');
    final samePlatformOnly = _song('x2', '轨迹', '林宥嘉', '其它', platform: 'tx');

    final a = engine.predict(candidate: sameArtist, profile: profile);
    final b = engine.predict(candidate: samePlatformOnly, profile: profile);
    expect(a, greaterThan(b));
  });
}
