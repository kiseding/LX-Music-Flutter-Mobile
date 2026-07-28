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

  group('validateHttpsServiceUrl', () {
    test('normalizes whitespace and trailing slashes', () {
      expect(
        validateHttpsServiceUrl('  https://sync.example.com/base///  '),
        'https://sync.example.com/base',
      );
    });

    test('normalizes only the path and preserves query and fragment', () {
      expect(
        validateHttpsServiceUrl(
            'https://sync.example.com/base///?next=/#section/'),
        'https://sync.example.com/base?next=/#section/',
      );
    });

    test('rejects HTTP, credentials, missing hosts, and unsupported schemes',
        () {
      for (final value in [
        'http://sync.example.com',
        'https://user:pass@sync.example.com',
        'https:///missing-host',
        'ftp://sync.example.com',
        'sync.example.com',
      ]) {
        expect(
          () => validateHttpsServiceUrl(value),
          throwsA(isA<ArgumentError>()),
          reason: value,
        );
      }
    });
  });
}
