import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/logging/app_log.dart';

void main() {
  test('keeps a bounded in-memory log and redacts credentials', () {
    final log = AppLog(maximumEntries: 2);

    log.record('network', 'Authorization: Bearer secret-value');
    log.record('network', 'GET https://example.test/play?access_token=secret');
    expect(log.exportText(), isNot(contains('secret-value')));
    expect(log.exportText(), isNot(contains('access_token=secret')));
    expect(log.exportText(), contains('Authorization: ***'));
    expect(log.exportText(), contains('access_token=***'));

    log.record('playback', 'ready');

    expect(log.entries.value, hasLength(2));
    expect(
      log.entries.value.map((entry) => entry.message).join('\n'),
      isNot(contains('secret-value')),
    );

    log.clear();
    expect(log.entries.value, isEmpty);
  });
}
