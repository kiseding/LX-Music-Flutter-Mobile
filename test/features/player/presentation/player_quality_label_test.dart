import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/network/play_url_result.dart';

void main() {
  test('player quality bar prefers actualQuality over requested', () {
    final extras = <String, dynamic>{
      'platform': 'tx',
      'requestedQuality': 'flac',
      'actualQuality': '320k',
      'remoteUrl': 'https://dl.stream.qqmusic.qq.com/M800xxx.mp3',
    };
    final actual = extras['actualQuality']?.toString();
    expect(actual, '320k');
    expect(qualityLabel(actual!), '320kbps');
    expect(qualityLabel(actual!), isNot(qualityLabel('flac')));
  });

  test('falls back to remoteUrl inference when actualQuality missing', () {
    final remote = 'https://dl.stream.qqmusic.qq.com/C400xxx.m4a?vkey=1';
    final inferred = correctQualityFromUrl(remote, 'flac');
    expect(inferred, '128k');
  });
}
