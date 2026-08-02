import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/features/custom_source/domain/custom_source_engine.dart';
import 'package:lx_music_flutter/features/custom_source/domain/source_runtime_polyfill.dart';

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
    expect(bridge, contains('freezeObject(globalThis.lx, []);'));
    expect(bridge, contains('lockProperties(globalThis.lx, []);'));
    expect(bridge, contains("throw new Error('eval is not available');"));
    expect(bridge, contains("Dynamic code execution is not allowed."));

    // 官方移动端始终回调 (err, response, body)，不能依赖混淆后不稳定的
    // Function.length 来重排参数。
    expect(bridge, contains("if (typeof callback === 'function')"));
    expect(bridge, contains('cb(err, res, body);'));
    expect(bridge, isNot(contains('cb.length ===')));
    expect(
      bridge,
      contains('var input = unescape(encodeURIComponent(string));'),
    );
    expect(bridge, contains('globalThis._md5 = md5Utf8;'));
    expect(bridge, contains('Math.abs(Math.sin(i + 1)) * 4294967296'));

    expect(bridge, contains("eventName !== globalThis.lx.EVENT_NAMES.request"));
    expect(bridge, contains("eventName !== globalThis.lx.EVENT_NAMES.inited"));
    expect(bridge, contains('The event is not supported:'));
    expect(bridge, contains("'statusMessage':"));
    expect(bridge, contains("'responseRaw':"));
    expect(bridge, contains("'rawData':"));
    expect(bridge, contains('res.rawData = res.responseRaw;'));
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
    expect(bridge, contains('_cookieJar'));
    expect(bridge, contains('_mergeRequestUri'));
    expect(bridge, contains('_applyStoredCookies'));
    expect(bridge, contains('_storeCookiesFromResponse'));
    expect(bridge, contains('_formatRequestError'));
    expect(
        bridge, contains("setHeaderIfMissing('Accept', 'application/json')"));
    expect(bridge, contains('_encodeFormBody'));
    expect(bridge, contains('_normalizeFormDataMap'));
    expect(bridge,
        contains("const platforms = {'kw', 'tx', 'wy', 'kg', 'mg', 'local'}"));
    expect(bridge, contains("return '';"));
    expect(bridge, contains('maximumRedirects: 10'));
    expect(bridge, contains('_supportsAction'));
    expect(bridge, contains('_validateCapabilities'));
    expect(bridge, contains("'type': 'diagnostic'"));
    expect(bridge, contains("'capability_rejected'"));
    expect(bridge, contains("'empty_result'"));
    expect(bridge, contains("'invalid_result'"));
    expect(bridge, contains("'http_error_response'"));
    expect(bridge, contains("'statusCode': response.statusCode"));
    expect(bridge, contains("'bodyType': body.runtimeType.toString()"));
    expect(bridge, contains('body = json.decode(bodyStr);'));
    expect(
      bridge,
      isNot(contains("contentType.contains('application/json') ||")),
    );
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

  test('secureRandomBytes returns independent bytes with the requested shape',
      () {
    final first = secureRandomBytes(32);
    final second = secureRandomBytes(32);

    expect(first, hasLength(32));
    expect(first.every((byte) => byte >= 0 && byte <= 255), isTrue);
    expect(second, hasLength(32));
    expect(second, isNot(equals(first)));
    expect(() => secureRandomBytes(-1), throwsRangeError);
    expect(() => secureRandomBytes(65537), throwsRangeError);
  });

  test('LX randomBytes generates bytes in JS and returns Uint8Array', () {
    final bridge = File(
      'lib/features/custom_source/domain/custom_source_engine.dart',
    ).readAsStringSync();
    final randomBytesBlock = RegExp(
      r'globalThis\.lx\.utils\.crypto\.randomBytes = function\(size\) \{([\s\S]*?)\n      \};',
    ).firstMatch(bridge)!.group(1)!;

    expect(bridge, contains("method == 'randomBytes'"));
    expect(randomBytesBlock, contains('new Uint8Array(size)'));
    expect(randomBytesBlock, contains('Math.random'));
    expect(randomBytesBlock, isNot(contains("sendMessage('lx_crypto'")));
  });

  test('source runtime polyfill keeps official-style web primitives', () {
    final polyfill = SourceRuntimePolyfill.js();

    expect(polyfill, contains("action === 'md5_compute'"));
    expect(polyfill, contains('new TextEncoder().encode(input)'));
    expect(polyfill, contains('input instanceof ArrayBuffer'));
    expect(polyfill, contains('new TextDecoder().decode'));
    expect(polyfill, contains('options.headers._map'));
    expect(polyfill, contains('body instanceof URLSearchParams'));
    expect(polyfill, contains('URLSearchParams.prototype.entries'));
    expect(polyfill, contains('FormData.prototype.entries'));
    expect(polyfill, contains('body._data instanceof Array'));
    expect(polyfill, contains('formData._data instanceof Array'));
    expect(polyfill, contains('isBuffer:function'));
  });
}
