import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/features/custom_source/domain/custom_source_engine.dart';

void main() {
  test('LX bridge exposes the Desktop event contract', () {
    final bridge = File(
      'lib/features/custom_source/domain/custom_source_engine.dart',
    ).readAsStringSync();

    expect(bridge, contains("env: 'desktop'"));
    expect(bridge, contains('group: function() {}'));
    expect(bridge, contains('groupEnd: function() {}'));

    // lx.on('request') 支持多 handler 数组，便于旧脚本注册多个 request 处理器。
    expect(
        bridge,
        contains(
            "globalThis._requestHandlers = globalThis._requestHandlers || [];"));
    expect(bridge, contains('globalThis._requestHandlers.push(handler);'));

    // lx.request 按 callback.length 做 arity 嗅探。
    // 2-arg 必须是 (err, response)：脚本写 request(url, opts, (err, resp) => { if (err) reject; const {body}=resp })
    expect(bridge, contains("if (typeof callback === 'function')"));
    expect(bridge, contains('if (cb.length === 1)'));
    expect(bridge, contains('else if (cb.length === 2)'));
    expect(bridge, contains('cb(err, res);'));
    expect(bridge, contains('cb(body || (res ? res.body : null));'));
    expect(bridge, contains('else cb(err, res, body);'));

    expect(bridge, contains("eventName !== globalThis.lx.EVENT_NAMES.request"));
    expect(bridge, contains("eventName !== globalThis.lx.EVENT_NAMES.inited"));
    expect(bridge, contains('The event is not supported:'));
    expect(bridge, contains("'statusMessage':"));
    expect(bridge, contains("'responseRaw':"));
    expect(bridge, contains('res.rawData = res.responseRaw;'));
    expect(bridge, isNot(contains("'rawData': base64Encode")));
    expect(bridge, contains("'bytes':"));
    expect(bridge, contains('lx_request_cancel'));
    expect(bridge, contains('SourceRequestSandbox'));
    expect(bridge, contains('await withSourceResponseLease(response'));
    expect(bridge, contains('if (!response.isCancelled)'));
    expect(bridge, contains('SourceRequestCancellation? requestCancellation;'));
    expect(bridge, contains('if (requestCancellation?.isCancelled != true)'));
    expect(
      bridge.indexOf('_httpCancellations.remove(callbackId);'),
      greaterThan(bridge.indexOf('await withSourceResponseLease(response')),
    );
    expect(bridge, contains('_supportsAction'));
    expect(bridge, contains('_validateCapabilities'));
    // _callRequestEvent 现在迭代 handler 数组，第一个非空返回即胜出。
    expect(
        bridge, contains('var handlers = globalThis._requestHandlers || [];'));
    expect(bridge, contains("handlers.length === 0"));
    expect(bridge, contains('for (var i = 0; i < handlers.length; i++)'));

    // 能力拒绝是正常回退路径（musicUrl/lyric/pic），不应当作错误冒泡到 UI，
    // 否则源未声明 lyric 时会刷出"Source does not support lyric"红字。
    expect(
      bridge,
      isNot(contains("_emitError('Source does not support")),
    );
  });

  test('secureRandomBytes returns independent bytes with the requested shape', () {
    final first = secureRandomBytes(32);
    final second = secureRandomBytes(32);

    expect(first, hasLength(32));
    expect(first.every((byte) => byte >= 0 && byte <= 255), isTrue);
    expect(second, hasLength(32));
    expect(second, isNot(equals(first)));
    expect(() => secureRandomBytes(-1), throwsRangeError);
    expect(() => secureRandomBytes(65537), throwsRangeError);
  });

  test('LX randomBytes delegates to the Dart crypto bridge', () {
    final bridge = File(
      'lib/features/custom_source/domain/custom_source_engine.dart',
    ).readAsStringSync();
    final randomBytesBlock = RegExp(
      r'globalThis\.lx\.utils\.crypto\.randomBytes = function\(size\) \{([\s\S]*?)\n      \};',
    ).firstMatch(bridge)!.group(1)!;

    expect(bridge, contains("method == 'randomBytes'"));
    expect(randomBytesBlock, contains("sendMessage('lx_crypto'"));
    expect(randomBytesBlock, isNot(contains('Math.random')));
  });
}
