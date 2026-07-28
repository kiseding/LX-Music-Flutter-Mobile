import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/network/outbound_url.dart';

void main() {
  test('normalizes dynamic HTTP URLs without changing request components', () {
    expect(
      normalizeOutboundUrl('http://example.com/a?x=1#part'),
      'https://example.com/a?x=1#part',
    );
    expect(
      normalizeOutboundUrl('https://example.com/a?x=1#part'),
      'https://example.com/a?x=1#part',
    );
  });

  test('leaves local file paths and invalid values unchanged', () {
    expect(
        normalizeOutboundUrl('file:///tmp/song.mp3'), 'file:///tmp/song.mp3');
    expect(normalizeOutboundUrl('/tmp/song.mp3'), '/tmp/song.mp3');
    expect(normalizeOutboundUrl('not a url'), 'not a url');
  });
}
