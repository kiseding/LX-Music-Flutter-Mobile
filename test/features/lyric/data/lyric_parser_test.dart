import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/features/lyric/data/lyric_parser.dart';

void main() {
  test('parseLrc plain lines without word timing', () {
    const raw = '''
[00:12.00]第一行
[00:15.50]第二行
''';
    final lyrics = LyricParser.parseLrc(raw);
    expect(lyrics.lines.length, 2);
    expect(lyrics.lines[0].text, '第一行');
    expect(lyrics.lines[0].hasWordTiming, isFalse);
    expect(lyrics.lines[0].time, const Duration(seconds: 12));
  });

  test('parseLrc LRCX relative word tags', () {
    const raw = r'''
[00:10.00]<0,200>七<200,200>里<400,300>香
[00:15.00]下一行
''';
    final lyrics = LyricParser.parseLrc(raw);
    expect(lyrics.lines.length, 2);
    final line = lyrics.lines.first;
    expect(line.text, '七里香');
    expect(line.hasWordTiming, isTrue);
    expect(line.words!.length, 3);
    expect(line.words![0].text, '七');
    expect(line.words![0].time, const Duration(seconds: 10));
    expect(line.words![0].duration, const Duration(milliseconds: 200));
    expect(line.words![1].time, const Duration(milliseconds: 10200));
    expect(line.words![2].text, '香');
  });

  test('parseLrc yrc style word-before-tag', () {
    const raw = r'''
[00:05.00]你<0,180>好<180,220>吗
''';
    final lyrics = LyricParser.parseLrc(raw);
    expect(lyrics.lines.length, 1);
    final words = lyrics.lines.first.words!;
    expect(words.map((w) => w.text).join(), '你好吗');
    expect(words[0].duration, const Duration(milliseconds: 180));
    expect(words[1].time, const Duration(milliseconds: 5180));
  });

  test('parseQrc clock word tags', () {
    const raw = r'''
[00:12.34]<00:12.34>逐<00:12.50>字<00:12.70>歌
''';
    final lyrics = LyricParser.parseQrc(raw);
    expect(lyrics.lines.length, 1);
    final words = lyrics.lines.first.words!;
    expect(words.map((w) => w.text).join(), '逐字歌');
    expect(words[0].time, const Duration(minutes: 0, seconds: 12, milliseconds: 340));
    expect(words[1].time, const Duration(minutes: 0, seconds: 12, milliseconds: 500));
  });

  test('word fill progress for KTV', () {
    const raw = r'''
[00:10.00]<0,1000>A<1000,1000>B
''';
    final lyrics = LyricParser.parseLrc(raw);
    final line = lyrics.lines.first;
    expect(lyrics.getCurrentWordIndex(const Duration(seconds: 10, milliseconds: 500), 0), 0);
    expect(
      lyrics.getWordFillProgress(
        const Duration(seconds: 10, milliseconds: 500),
        0,
        0,
      ),
      closeTo(0.5, 0.01),
    );
    expect(lyrics.getCurrentWordIndex(const Duration(seconds: 11, milliseconds: 200), 0), 1);
    expect(line.words![1].text, 'B');
  });

  test('hasWordTiming detection', () {
    expect(LyricParser.hasWordTiming('[00:01.00]plain'), isFalse);
    expect(LyricParser.hasWordTiming(r'[00:01.00]<0,100>a'), isTrue);
    expect(LyricParser.hasWordTiming(r'<00:01.00>a'), isTrue);
  });
}
