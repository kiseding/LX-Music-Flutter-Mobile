import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/network/play_url_result.dart';

void main() {
  test('QQ filename prefixes imply bitrate', () {
    expect(
      correctQualityFromUrl(
        'https://dl.stream.qqmusic.qq.com/C400xxx.m4a?vkey=1',
        'flac',
      ),
      '128k',
    );
    expect(
      correctQualityFromUrl(
        'https://dl.stream.qqmusic.qq.com/M800xxx.mp3?vkey=1',
        'flac',
      ),
      '320k',
    );
    expect(
      correctQualityFromUrl(
        'https://dl.stream.qqmusic.qq.com/F000xxx.flac?vkey=1',
        'flac',
      ),
      'flac',
    );
  });
}
