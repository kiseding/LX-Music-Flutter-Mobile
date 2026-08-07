import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
      'source-load messages are drained by Dart without evaluating native sendMessage',
      () {
    final bridge = File(
      'lib/features/custom_source/domain/custom_source_engine.dart',
    ).readAsStringSync();

    expect(bridge, contains('_drainDeferredMessages'));
    expect(bridge, contains('_deferredMessages'));
    expect(
      bridge,
      isNot(
          contains('globalThis.sendMessage(msgs[i].channel, msgs[i].message)')),
    );
  });

  test('zlib requests made while loading use an asynchronous deferred result',
      () {
    final bridge = File(
      'lib/features/custom_source/domain/custom_source_engine.dart',
    ).readAsStringSync();

    expect(bridge, contains('_deferredResolvers'));
    expect(bridge, contains("channel === 'lx_zlib'"));
    expect(bridge, contains('_resolveDeferredMessage'));
  });

  test('deferred HTTP requests use the normal Dart request handler', () {
    final bridge = File(
      'lib/features/custom_source/domain/custom_source_engine.dart',
    ).readAsStringSync();

    expect(bridge, contains("channel == 'lx_request'"));
    expect(bridge, contains('_handleLxRequest'));
  });

  test('keeps the dispatcher installed until deferred continuations drain', () {
    final bridge = File(
      'lib/features/custom_source/domain/custom_source_engine.dart',
    ).readAsStringSync();

    expect(bridge, contains('_captureFrozenMessages'));
    expect(bridge, contains('_restoreSourceMessageDispatcher'));
    expect(
      bridge.indexOf('_restoreSourceMessageDispatcher();'),
      greaterThan(bridge.indexOf('await _drainDeferredMessages();')),
    );
  });

  test('host request path keeps safe query merge without implicit cookies', () {
    final bridge = File(
      'lib/features/custom_source/domain/custom_source_engine.dart',
    ).readAsStringSync();

    expect(bridge, isNot(contains('_cookieJar')));
    expect(bridge, isNot(contains('_applyStoredCookies')));
    expect(bridge, isNot(contains('_storeCookiesFromResponse')));
    expect(bridge, contains('base.queryParametersAll'));
    expect(bridge, contains("'rawData': rawB64"));
    expect(
      bridge,
      contains(
        'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/69.0.3497.100 Safari/537.36',
      ),
    );
  });
}
