import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/music_source/platform/wy_source.dart';
import 'package:lx_music_flutter/features/lyric/data/lyric_parser.dart';

void main() {
  test('NetEase EAPI request endpoints use HTTPS', () {
    expect(
      neteaseSearchEndpoint,
      'https://interface.music.163.com/eapi/batch',
    );
    expect(
      neteaseLyricEndpoint,
      'https://interface.music.163.com/eapi/song/lyric/v1',
    );
  });

  test('wyYrcToLrc converts word-timed yrc lines to LRCX', () {
    // 真实网易云 yrc 逐字行格式
    const yrc = '''
{"t":0,"c":[{"tx":"作词: "},{"tx":"唐恬"}]}
{"t":0,"c":[{"tx":"作曲: "},{"tx":"钱雷"}]}
[235780,5470](235780,430,0)谁(236210,260,0)说(236470,460,0)站(236930,420,0)在
[241320,5300](241320,380,0)光(241700,360,0)里(242060,360,0)的(242420,280,0)才
''';
    final converted = WySource.wyYrcToLrc(yrc);
    expect(converted, isNotNull);
    expect(converted, contains('[03:55.780]'));
    expect(converted, contains('<0,430>谁'));
    expect(converted, contains('<430,260>说'));

    // 转换结果能被解析器识别为逐字歌词
    final parsed = LyricParser.parseLrc(converted!);
    final wordLines = parsed.lines.where((l) => l.hasWordTiming).toList();
    expect(wordLines, isNotEmpty);
    expect(wordLines.first.words!.map((w) => w.text).join(), '谁说站在');
    expect(wordLines.first.words!.length, 4);
    expect(wordLines.first.words![0].text, '谁');
    expect(wordLines.first.words![1].text, '说');
  });

  test('wyYrcToLrc falls back to null for empty input', () {
    expect(WySource.wyYrcToLrc(''), isNull);
    expect(WySource.wyYrcToLrc('   \n  '), isNull);
  });
}
