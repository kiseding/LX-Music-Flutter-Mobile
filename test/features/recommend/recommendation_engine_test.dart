import 'dart:math';

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
  final favorites = List.generate(
    100,
    (index) => _song(
      'f$index',
      '收藏歌曲 $index',
      '周杰伦',
      '收藏专辑 ${index % 5}',
    ),
  );

  final candidates = [
    _song('c1', '稻香', '周杰伦', '魔杰座'),
    _song('c2', '说谎', '林宥嘉', '感官世界'),
    _song('c3', '夜曲', '周杰伦', '十一月的萧邦'), // 与收藏同 id → 应被排除
  ];

  test('requires 100 favorites and caps at 30 results', () {
    final engine = const RecommendationEngine();
    final enoughCandidates = List.generate(
      30,
      (index) => _song('c$index', '候选歌曲 $index', '周杰伦', '候选专辑'),
    );
    final recs = engine.recommend(
      favorites: favorites,
      candidates: enoughCandidates,
      random: Random(1),
    );

    expect(recs, hasLength(30));
    expect(recs.every((rec) => rec.song.singer == '周杰伦'), isTrue);
    // 收藏不足 100 首时不生成推荐
    expect(
      engine.recommend(
        favorites: favorites.take(99).toList(),
        candidates: enoughCandidates,
        random: Random(1),
      ),
      isEmpty,
    );
    // 候选不足 30 首时返回已有结果，而非空
    final partial = engine.recommend(
      favorites: favorites,
      candidates: candidates,
      random: Random(1),
    );
    expect(partial, isNotEmpty);
    expect(partial.length, lessThanOrEqualTo(candidates.length));
  });

  test('returns empty when favorites are below the sample threshold', () {
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
