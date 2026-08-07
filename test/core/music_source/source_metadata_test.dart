import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/music_source/platform/kw_source.dart';
import 'package:lx_music_flutter/core/music_source/platform/tx_source.dart';

void main() {
  test('TX parsed songs retain raw UserApi fields', () {
    final source = TxSource();
    addTearDown(source.dispose);
    final raw = <String, dynamic>{
      'songmid': 'song-mid',
      'songname': 'Song',
      'albumname': 'Album',
      'albummid': 'album-mid',
      'interval': 180,
      'strMediaMid': 'media-mid',
      'pay': {'payplay': 1},
      'singer': [
        {'name': 'Singer'}
      ],
    };

    final song = source.parseItem(raw, 'tx');

    expect(song.meta?['strMediaMid'], 'media-mid');
    expect(song.meta?['pay'], {'payplay': 1});
  });

  test('KW parsed songs retain raw UserApi fields', () {
    final source = KwSource();
    addTearDown(source.dispose);
    final raw = <String, dynamic>{
      'MUSICRID': 'MUSIC_12345',
      'SONGNAME': 'Song',
      'ARTIST': 'Singer',
      'formats': 'MP3H',
      'pay': '1',
    };

    final song = source.parseItem(raw, 'kw');

    expect(song.meta?['MUSICRID'], 'MUSIC_12345');
    expect(song.meta?['formats'], 'MP3H');
    expect(song.meta?['pay'], '1');
  });
}
