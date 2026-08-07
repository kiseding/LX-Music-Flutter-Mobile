import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/features/custom_source/domain/custom_source_engine.dart';
import 'package:lx_music_flutter/features/player/domain/music_item.dart';
import 'package:lx_music_flutter/core/network/play_url_result.dart';

void main() {
  test('scraped song without types still exposes requested quality to scripts',
      () {
    final types = ensureMusicInfoTypes({}, 'flac');
    expect(types.first, 'flac');
    expect(types, contains('320k'));
    expect(types, contains('128k'));
  });

  test('existing types keep request quality at front', () {
    final types = ensureMusicInfoTypes({
      'types': ['128k', '320k'],
    }, 'flac');
    expect(types.first, 'flac');
    expect(types, containsAll(['flac', '320k', '128k']));
  });

  test('MusicItem meta roundtrip keeps types for custom play', () {
    final item = MusicItem(
      id: '1',
      name: 't',
      singer: 's',
      source: 'custom',
      platform: 'tx',
      songmid: 'mid',
      meta: {
        'songmid': 'mid',
        'types': ['flac', '320k', '128k'],
        'source': 'tx',
      },
    );
    final json = item.toJson();
    final back = MusicItem.fromJson(json);
    expect(back.meta?['types'], ['flac', '320k', '128k']);
  });

  test('normalizeScriptQuality accepts common script labels', () {
    expect(normalizeScriptQuality('flac'), 'flac');
    expect(normalizeScriptQuality('320k'), '320k');
    expect(normalizeScriptQuality('SQ'), 'flac');
    expect(normalizeScriptQuality('mp3'), '128k');
  });

  test('mobile music info keeps platform-specific identity fields', () {
    final tx = MusicItem(
      id: '101138130',
      name: 'ANGEL',
      singer: '尹美莱',
      album: 'Angel',
      source: 'custom',
      platform: 'tx',
      songmid: '004PjZLu3CjaYS',
      hash: null,
      meta: {
        'id': 101138130,
        'mid': '004PjZLu3CjaYS',
        'file': {'media_mid': '004ISWHG0pvJg9'},
        'album': {'mid': '000qiKcT05rSr9', 'name': 'Angel'},
      },
    );
    final info = buildLxMobileMusicInfo(tx, 'tx');

    expect(info['songmid'], '004PjZLu3CjaYS');
    expect(info.containsKey('hash'), isFalse);
    expect(info['songId'], '101138130');
    expect(info['strMediaMid'], '004ISWHG0pvJg9');
    expect(info['albumMid'], '000qiKcT05rSr9');
  });

  test('mobile music info only sends a real KuGou hash', () {
    final info = buildLxMobileMusicInfo(
      MusicItem(
        id: 'audio-id',
        name: 'song',
        singer: 'singer',
        source: 'custom',
        platform: 'kg',
        songmid: 'audio-id',
        meta: {'hash': 'ABCDEF'},
      ),
      'kg',
    );

    expect(info['hash'], 'ABCDEF');
    expect(info['songmid'], 'audio-id');
  });
}
