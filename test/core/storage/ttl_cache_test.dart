import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/storage/ttl_cache.dart';

void main() {
  test('expires entries after ttl from last access', () {
    var now = DateTime(2026, 7, 30, 12);
    final cache = TtlCache<String>(
      ttl: const Duration(hours: 12),
      clock: () => now,
    );

    cache.set('a', 'value');
    expect(cache.get('a'), 'value');

    now = now.add(const Duration(hours: 11));
    expect(cache.get('a'), 'value');

    now = now.add(const Duration(hours: 12, minutes: 1));
    expect(cache.get('a'), isNull);
  });

  test('touch on get extends retention', () {
    var now = DateTime(2026, 7, 30, 12);
    final cache = TtlCache<int>(
      ttl: const Duration(hours: 12),
      clock: () => now,
    );
    cache.set('n', 1);
    now = now.add(const Duration(hours: 11));
    expect(cache.get('n'), 1);
    now = now.add(const Duration(hours: 11));
    expect(cache.get('n'), 1);
  });
}
