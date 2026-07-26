import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/music_source/platform/built_in_source_manager.dart';
import 'package:lx_music_flutter/core/music_source/platform/kw_source.dart';
import 'package:lx_music_flutter/core/music_source/platform/tx_source.dart';
import 'package:lx_music_flutter/core/music_source/platform/wy_source.dart';

void main() {
  group('BuiltInSourceManager', () {
    test('仅注册酷我/腾讯/网易', () {
      final manager = BuiltInSourceManager();
      expect(manager.allIds, containsAll(['kw', 'tx', 'wy']));
      expect(manager.allIds, isNot(contains('kg')));
      expect(manager.allIds, isNot(contains('mg')));
      expect(manager.get('kg'), isNull);
      expect(manager.get('mg'), isNull);
      manager.dispose();
    });
  });

  group('KwSource', () {
    late KwSource source;
    setUp(() => source = KwSource());
    tearDown(() => source.dispose());

    test('搜索', () async {
      final results = await source.search('周杰伦', page: 1, limit: 3);
      expect(results, isNotEmpty);
      print('KW 搜索: ${results.length} 条');
      final item = results.first;
      print('  首条: ${item.name} - ${item.singer} (id: ${item.id})');
    });

    test('歌词', () async {
      final results = await source.search('周杰伦', page: 1, limit: 1);
      if (results.isNotEmpty) {
        final lyric = await source.getLyric(results.first);
        if (lyric != null) {
          print('KW 歌词: ${lyric.substring(0, lyric.length > 100 ? 100 : lyric.length)}...');
        } else {
          print('KW 歌词: null');
        }
      }
    });
  });

  group('TxSource', () {
    late TxSource source;
    setUp(() => source = TxSource());
    tearDown(() => source.dispose());

    test('搜索', () async {
      final results = await source.search('周杰伦', page: 1, limit: 3);
      expect(results, isNotEmpty);
      print('TX 搜索: ${results.length} 条');
      final item = results.first;
      print('  首条: ${item.name} - ${item.singer} (id: ${item.id})');
    });

    test('歌词', () async {
      final results = await source.search('周杰伦', page: 1, limit: 1);
      if (results.isNotEmpty) {
        final lyric = await source.getLyric(results.first);
        if (lyric != null) {
          print('TX 歌词: ${lyric.substring(0, lyric.length > 100 ? 100 : lyric.length)}...');
        } else {
          print('TX 歌词: null');
        }
      }
    });
  });

  group('WySource', () {
    late WySource source;
    setUp(() => source = WySource());
    tearDown(() => source.dispose());

    test('搜索', () async {
      final results = await source.search('周杰伦', page: 1, limit: 3);
      expect(results, isNotEmpty);
      print('WY 搜索: ${results.length} 条');
      final item = results.first;
      print('  首条: ${item.name} - ${item.singer} (id: ${item.id})');
    });

    test('歌词', () async {
      final results = await source.search('周杰伦', page: 1, limit: 1);
      if (results.isNotEmpty) {
        final lyric = await source.getLyric(results.first);
        if (lyric != null) {
          print('WY 歌词: ${lyric.substring(0, lyric.length > 100 ? 100 : lyric.length)}...');
        } else {
          print('WY 歌词: null');
        }
      }
    });
  });
}
