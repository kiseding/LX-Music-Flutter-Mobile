import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/music_source/platform/wy_source.dart';

void main() {
  test('网易云搜索结果包含可用封面地址', () async {
    final results = await WySource().search('晴天', limit: 3);

    expect(results, isNotEmpty);
    // 真实接口有时返回 HTTP 图片地址；iOS 图片加载应使用 HTTPS。
    expect(
      results.first.artwork,
      allOf(isNotEmpty, startsWith('https://')),
      reason: '网易云搜索歌曲应映射专辑 picUrl 到 MusicItem.artwork',
    );
  });
}
