# LX Source Host Compatibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make iOS execute imported LX Music source scripts with the observable `globalThis.lx` API contract used by LX Music Desktop.

**Architecture:** Keep source scripts opaque and run them in one JavaScriptCore runtime per source. Replace the ad hoc host bridge with explicit event, HTTP, binary/crypto/zlib, capability, and error-boundary behavior aligned to the official desktop preload host.

**Tech Stack:** Flutter, Dart, `flutter_js` JavaScriptCore, Dio, crypto, encrypt, pointycastle, Flutter test, GitHub Actions iOS build.

## Global Constraints

- Target iOS JavaScriptCore in this implementation; do not claim Android parity.
- Do not extract or transform source API URLs, keys, templates, signatures, or source business logic.
- Do not add back built-in third-party music URL resolver APIs.
- Preserve the imported script verbatim and keep each source in an isolated runtime.
- Never log API key, authorization, cookie, or token header values.
- Validate with Huibq and Flower fixture scripts plus an iOS IPA build.

---

### Task 1: Create LX host protocol models and capability validation

**Files:**
- Create: `lib/features/custom_source/domain/lx_source_protocol.dart`
- Create: `test/features/custom_source/domain/lx_source_protocol_test.dart`
- Modify: `lib/features/custom_source/domain/custom_source_engine.dart`

**Interfaces:**
- Produces `LxSourceCapabilities`, `LxRequestOptions`, `LxHttpResponse`, and `LxSourceFailure`.
- `LxSourceCapabilities.fromInitData(Map<String, dynamic>)` returns validated platforms/actions/qualities.

- [ ] **Step 1: Write failing capability tests**

```dart
test('keeps only official platforms, actions, and qualities', () {
  final capabilities = LxSourceCapabilities.fromInitData({
    'sources': {
      'tx': {'type': 'music', 'actions': ['musicUrl', 'lyric'], 'qualitys': ['128k', '320k', 'bad']},
      'unknown': {'type': 'music', 'actions': ['musicUrl'], 'qualitys': ['128k']},
    },
  });

  expect(capabilities.supports('tx', 'musicUrl', '320k'), isTrue);
  expect(capabilities.supports('tx', 'lyric'), isFalse);
  expect(capabilities.platforms, equals({'tx'}));
});
```

- [ ] **Step 2: Run the protocol test to verify failure**

Run: `TMPDIR=/home/yys/work flutter test test/features/custom_source/domain/lx_source_protocol_test.dart`

Expected: compilation failure because `LxSourceCapabilities` does not exist.

- [ ] **Step 3: Implement the protocol models**

```dart
class LxSourceCapabilities {
  static const supportedPlatforms = {'kw', 'kg', 'tx', 'wy', 'mg', 'local'};
  static const supportedActions = {'musicUrl', 'lyric', 'pic'};
  static const supportedQualities = {'128k', '192k', '320k', 'flac', 'flac24bit'};

  final Map<String, Set<String>> actions;
  final Map<String, Set<String>> qualities;

  bool supports(String source, String action, [String? quality]) =>
      actions[source]?.contains(action) == true &&
      (quality == null || qualities[source]?.contains(quality) == true);
}
```

- [ ] **Step 4: Run the protocol test to verify success**

Run: `TMPDIR=/home/yys/work flutter test test/features/custom_source/domain/lx_source_protocol_test.dart`

Expected: `All tests passed!`

- [ ] **Step 5: Commit**

```bash
git add lib/features/custom_source/domain/lx_source_protocol.dart test/features/custom_source/domain/lx_source_protocol_test.dart
```

### Task 2: Align source event registration and initialization semantics

**Files:**
- Modify: `lib/features/custom_source/domain/custom_source_engine.dart`
- Modify: `test/features/custom_source/domain/custom_source_engine_test.dart`

**Interfaces:**
- Consumes `LxSourceCapabilities` from Task 1.
- Produces `Future<LxSourceCapabilities> loadSource(CustomSource source)` and source error events.

- [ ] **Step 1: Write failing host-contract tests**

```dart
test('replaces a prior request handler and accepts inited capabilities', () async {
  final engine = CustomSourceEngine();
  addTearDown(engine.dispose);
  final source = sourceWithScript(r'''
    lx.on(lx.EVENT_NAMES.request, async () => 'https://first.example');
    lx.on(lx.EVENT_NAMES.request, async () => 'https://second.example');
    lx.send(lx.EVENT_NAMES.inited, { sources: { tx: { type: 'music', actions: ['musicUrl'], qualitys: ['128k'] } } });
  ''');

  final loaded = await engine.loadSource(source);
  expect(loaded.capabilities.supports('tx', 'musicUrl', '128k'), isTrue);
  expect(await engine.getMusicUrl(txSong), 'https://second.example');
});
```

- [ ] **Step 2: Run the test to verify failure**

Run: `TMPDIR=/home/yys/work flutter test test/features/custom_source/domain/custom_source_engine_test.dart --plain-name "replaces a prior request handler and accepts inited capabilities"`

Expected: failure because the current host accumulates handlers and returns only a Boolean load result.

- [ ] **Step 3: Implement one-handler registration and Promise-based send/on**

```javascript
on: function(eventName, handler) {
  if (eventName !== EVENT_NAMES.request) return Promise.reject(new Error('The event is not supported: ' + eventName));
  globalThis._requestHandler = handler;
  return Promise.resolve();
},
send: function(eventName, data) {
  if (eventName === EVENT_NAMES.inited || eventName === EVENT_NAMES.updateAlert) {
    sendMessage('lx_send', JSON.stringify({ event: eventName, data: data }));
    return Promise.resolve();
  }
  return Promise.reject(new Error('The event is not supported: ' + eventName));
},
```

- [ ] **Step 4: Validate `inited` payload in Dart and make load fail when initialization fails**

```dart
if (event == 'inited') {
  final capabilities = LxSourceCapabilities.fromInitData(data['data'] as Map<String, dynamic>);
  _initCompleter?.complete(capabilities);
}
```

- [ ] **Step 5: Run the test to verify success**

Run: `TMPDIR=/home/yys/work flutter test test/features/custom_source/domain/custom_source_engine_test.dart --plain-name "replaces a prior request handler and accepts inited capabilities"`

Expected: `All tests passed!`

- [ ] **Step 6: Commit**

```bash
git add lib/features/custom_source/domain/custom_source_engine.dart test/features/custom_source/domain/custom_source_engine_test.dart
```

### Task 3: Rebuild the HTTP bridge around the official request contract

**Files:**
- Create: `lib/features/custom_source/domain/lx_http_bridge.dart`
- Create: `test/features/custom_source/domain/lx_http_bridge_test.dart`
- Modify: `lib/features/custom_source/domain/custom_source_engine.dart`

**Interfaces:**
- Produces `Future<LxHttpResponse> LxHttpBridge.request(LxRequestOptions options)`.
- Handles cancellation using a request ID and Dio `CancelToken`.

- [ ] **Step 1: Write local-server request tests**

```dart
test('returns parsed JSON in response and third callback argument', () async {
  final response = await bridge.request(LxRequestOptions(
    url: server.url('/json'),
    method: 'GET',
    headers: {'X-Source-Key': 'redacted-in-logs'},
  ));

  expect(response.statusCode, 200);
  expect(response.body, {'url': 'https://media.example/song.mp3'});
  expect(response.raw, isNotEmpty);
});

test('cancels an in-flight request', () async {
  final pending = bridge.request(LxRequestOptions(url: server.url('/slow')));
  bridge.cancel(pending.id);
  await expectLater(pending.future, throwsA(isA<LxSourceFailure>()));
});
```

- [ ] **Step 2: Run tests to verify failure**

Run: `TMPDIR=/home/yys/work flutter test test/features/custom_source/domain/lx_http_bridge_test.dart`

Expected: compilation failure because `LxHttpBridge` does not exist.

- [ ] **Step 3: Implement HTTP request mapping and cancellation**

```dart
final response = await _dio.request<dynamic>(
  options.url,
  data: options.body ?? options.form ?? options.formData,
  options: Options(
    method: options.method,
    headers: options.headers,
    responseType: options.binary ? ResponseType.bytes : ResponseType.plain,
    receiveTimeout: Duration(milliseconds: options.timeoutMs.clamp(1, 60000)),
    validateStatus: (_) => true,
  ),
  cancelToken: token,
);
```

- [ ] **Step 4: Send exactly one JavaScript callback with official response fields**

```javascript
cb(error, {
  statusCode: response.statusCode,
  statusMessage: response.statusMessage,
  headers: response.headers,
  bytes: response.bytes,
  raw: response.raw,
  body: response.body,
}, response.body)
```

- [ ] **Step 5: Run tests to verify success**

Run: `TMPDIR=/home/yys/work flutter test test/features/custom_source/domain/lx_http_bridge_test.dart`

Expected: `All tests passed!`

- [ ] **Step 6: Commit**

```bash
git add lib/features/custom_source/domain/lx_http_bridge.dart test/features/custom_source/domain/lx_http_bridge_test.dart lib/features/custom_source/domain/custom_source_engine.dart
```

### Task 4: Implement binary, crypto, and zlib host compatibility

**Files:**
- Create: `lib/features/custom_source/domain/lx_binary_bridge.dart`
- Create: `test/features/custom_source/domain/lx_binary_bridge_test.dart`
- Modify: `lib/features/custom_source/domain/custom_source_engine.dart`

**Interfaces:**
- Produces JSON-safe byte conversion used by Buffer, crypto, and zlib host calls.
- All asynchronous zlib operations resolve/reject JavaScript Promises.

- [ ] **Step 1: Write failing tests for Buffer and crypto values**

```dart
test('encodes UTF-8 Buffer values as hex and base64', () {
  final buffer = LxBinaryBridge.fromUtf8('abc');
  expect(buffer.toHex(), '616263');
  expect(buffer.toBase64(), 'YWJj');
});

test('matches MD5 and AES-CBC expected values', () {
  expect(LxBinaryBridge.md5('hello'), '5d41402abc4b2a76b9719d911017c592');
  expect(LxBinaryBridge.aesEncrypt(...).toBase64(), expectedCiphertext);
});
```

- [ ] **Step 2: Run tests to verify failure**

Run: `TMPDIR=/home/yys/work flutter test test/features/custom_source/domain/lx_binary_bridge_test.dart`

Expected: compilation failure because `LxBinaryBridge` does not exist.

- [ ] **Step 3: Implement JSON-safe binary values and host functions**

```javascript
utils: {
  buffer: {
    from: function(data, encoding) { return sendMessage('lx_buffer_from', JSON.stringify({ data: data, encoding: encoding })); },
    bufToString: function(buffer, format) { return sendMessage('lx_buffer_to_string', JSON.stringify({ buffer: buffer, format: format })); },
  },
  crypto: { md5: ..., aesEncrypt: ..., rsaEncrypt: ..., randomBytes: ... },
  zlib: { inflate: ..., deflate: ... },
}
```

- [ ] **Step 4: Run tests to verify success**

Run: `TMPDIR=/home/yys/work flutter test test/features/custom_source/domain/lx_binary_bridge_test.dart`

Expected: `All tests passed!`

- [ ] **Step 5: Commit**

```bash
git add lib/features/custom_source/domain/lx_binary_bridge.dart test/features/custom_source/domain/lx_binary_bridge_test.dart lib/features/custom_source/domain/custom_source_engine.dart
```

### Task 5: Wire capabilities and errors through the source service and player

**Files:**
- Modify: `lib/features/custom_source/domain/custom_source_service.dart`
- Modify: `lib/core/network/music_source_service.dart`
- Modify: `lib/features/custom_source/presentation/custom_source_screen.dart`
- Create: `test/core/network/custom_source_playback_test.dart`

**Interfaces:**
- Consumes `LxSourceCapabilities` and `LxSourceFailure` from Tasks 1-4.
- Produces source-specific playback errors and source log entries.

- [ ] **Step 1: Write failing playback selection tests**

```dart
test('does not call a source that did not declare musicUrl for the platform', () async {
  final result = await service.getPlayUrlDetailed(unsupportedSong);
  expect(result, isNull);
  expect(logs, contains(predicate((event) => event['message'].contains('未声明 musicUrl'))));
});

test('surfaces the script API error when URL resolution fails', () async {
  await service.getPlayUrlDetailed(song);
  expect(logs.last['message'], contains('禁止批量下载'));
});
```

- [ ] **Step 2: Run tests to verify failure**

Run: `TMPDIR=/home/yys/work flutter test test/core/network/custom_source_playback_test.dart`

Expected: failure because capability checks and propagated errors are not implemented.

- [ ] **Step 3: Implement capability-gated dispatch and structured errors**

```dart
if (!capabilities.supports(platform, 'musicUrl', quality)) {
  throw LxSourceFailure.unsupportedAction(source.id, platform, 'musicUrl', quality);
}
```

- [ ] **Step 4: Update the log UI to show action, status, and sanitized endpoint**

```dart
TextSpan(text: '${log['action'] ?? ''} ${log['status'] ?? ''} ${log['message'] ?? ''}\n')
```

- [ ] **Step 5: Run tests to verify success**

Run: `TMPDIR=/home/yys/work flutter test test/core/network/custom_source_playback_test.dart`

Expected: `All tests passed!`

- [ ] **Step 6: Commit**

```bash
git add lib/features/custom_source/domain/custom_source_service.dart lib/core/network/music_source_service.dart lib/features/custom_source/presentation/custom_source_screen.dart test/core/network/custom_source_playback_test.dart
```

### Task 6: Add Huibq and Flower compatibility fixtures and iOS verification

**Files:**
- Create: `test/fixtures/custom_sources/huibq.js`
- Create: `test/fixtures/custom_sources/flower.js`
- Create: `test/features/custom_source/domain/lx_source_compatibility_test.dart`
- Modify: `.github/workflows/build-ios.yml`

**Interfaces:**
- Uses the source host from Tasks 1-5.
- Produces an IPA artifact from the final pushed commit.

- [ ] **Step 1: Add immutable fixture copies of the two source scripts**

```text
test/fixtures/custom_sources/huibq.js
test/fixtures/custom_sources/flower.js
```

- [ ] **Step 2: Write failing fixture contract tests**

```dart
test('Huibq computes its script-defined request URL and key header', () async {
  final capture = await executeWithCapturedRequest(huibqFixture, txSong);
  expect(capture.url, 'https://lxmusicapi.onrender.com/url/tx/mid-1/128k');
  expect(capture.headers['X-Request-Key'], 'share-v3');
});

test('Flower emits platform-specific URL and request metadata', () async {
  final capture = await executeWithCapturedRequest(flowerFixture, kgSong);
  expect(capture.url, contains('/flower/v1/url/kg/'));
  expect(capture.headers, containsPair('source-ver', '1'));
  expect(capture.headers, contains('tag'));
});
```

- [ ] **Step 3: Run tests to verify failure**

Run: `TMPDIR=/home/yys/work flutter test test/features/custom_source/domain/lx_source_compatibility_test.dart`

Expected: Flower fixture fails until the complete host API supports its initialization, buffer, crypto, and request flow.

- [ ] **Step 4: Complete any remaining host gaps revealed by the fixtures**

Only add behavior exercised by a failing fixture or official host contract. Keep script text unchanged.

- [ ] **Step 5: Run the focused compatibility suite**

Run: `TMPDIR=/home/yys/work flutter test test/features/custom_source/domain/lx_source_compatibility_test.dart`

Expected: `All tests passed!` on an iOS-capable runner; document local Linux runtime limitations if they remain.

- [ ] **Step 6: Build iOS IPA locally or through GitHub Actions**

Run: `gh run watch <final-build-run-id> --exit-status`

Expected: Build unsigned IPA workflow ends with `success` and publishes the IPA artifact.

- [ ] **Step 7: Commit and push**

```bash
git add test/fixtures/custom_sources test/features/custom_source/domain/lx_source_compatibility_test.dart .github/workflows/build-ios.yml
git push origin main
```
