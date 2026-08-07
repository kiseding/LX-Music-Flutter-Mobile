import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/widgets/artwork_image.dart';

void main() {
  const neteaseUrl =
      'https://p1.music.126.net/F0fTkmBTVykCa2o7Vgu1rQ==/109951173569626660.jpg';
  const qqUrl = 'https://y.gtimg.cn/music/photo_new/T002R300x300M000abc.jpg';

  test('artwork provider normalizes dynamic HTTP URLs', () {
    const image = ArtworkNetworkImage('http://images.example.com/cover.jpg');
    expect(image.resolvedUrl, 'https://images.example.com/cover.jpg');
  });

  test('netease artwork requests use browser headers', () {
    final headers = artworkRequestHeaders(neteaseUrl);
    expect(headers['User-Agent'], contains('Mozilla'));
    expect(headers['Referer'], 'https://music.163.com/');
    expect(artworkNeedsBrowserClient(neteaseUrl), isTrue);
  });

  test('non-netease artwork uses its own referer headers', () {
    final headers = artworkRequestHeaders(qqUrl);
    expect(headers['Referer'], 'https://y.qq.com/');
    expect(artworkNeedsBrowserClient(qqUrl), isTrue);
  });

  test('artwork loader closes client when request fails', () async {
    final client = FakeArtworkClient()..requestError = StateError('offline');
    final loader = ArtworkBytesLoader(createClient: () => client);

    await expectLater(
      loader.load(Uri.parse(qqUrl), const {}, (_, __) {}),
      throwsStateError,
    );
    expect(client.closeCalls, 1);
  });

  test('artwork loader rejects declared content length over limit', () async {
    final client = FakeArtworkClient.response(
      statusCode: 200,
      contentLength: 9,
      chunks: const [
        [1, 2]
      ],
    );
    final loader = ArtworkBytesLoader(
      createClient: () => client,
      maximumBytes: 8,
    );

    await expectLater(
      loader.load(Uri.parse(qqUrl), const {}, (_, __) {}),
      throwsA(isA<ArtworkLimitException>()),
    );
    expect(client.closeCalls, 1);
  });

  test('artwork loader rejects streamed bytes over limit and closes', () async {
    final client = FakeArtworkClient.response(
      statusCode: 200,
      contentLength: -1,
      chunks: const [
        [1, 2, 3],
        [4, 5, 6]
      ],
    );
    final loader = ArtworkBytesLoader(
      createClient: () => client,
      maximumBytes: 5,
    );

    await expectLater(
      loader.load(Uri.parse(qqUrl), const {}, (_, __) {}),
      throwsA(isA<ArtworkLimitException>()),
    );
    expect(client.closeCalls, 1);
  });

  test('artwork total timeout closes a stalled client', () async {
    final client = FakeArtworkClient.stalled();
    final loader = ArtworkBytesLoader(
      createClient: () => client,
      timeout: const Duration(milliseconds: 10),
    );

    await expectLater(
      loader.load(Uri.parse(qqUrl), const {}, (_, __) {}),
      throwsA(isA<TimeoutException>()),
    );
    expect(client.closeCalls, 1);
  });

  test('artwork loader closes client after successful load', () async {
    final client = FakeArtworkClient.response(
      statusCode: 200,
      contentLength: 4,
      chunks: const [
        [1, 2],
        [3, 4]
      ],
    );
    final loader = ArtworkBytesLoader(createClient: () => client);
    final received = <int>[];
    final bytes = await loader.load(
      Uri.parse(qqUrl),
      const {},
      (loaded, total) => received.add(loaded),
    );

    expect(bytes, Uint8List.fromList([1, 2, 3, 4]));
    expect(client.closeCalls, 1);
    expect(received, isNotEmpty);
  });

  test('artwork loader closes client on HTTP error status', () async {
    final client = FakeArtworkClient.response(
      statusCode: 403,
      contentLength: 2,
      chunks: const [
        [0x3C, 0x68]
      ],
    );
    final loader = ArtworkBytesLoader(createClient: () => client);

    await expectLater(
      loader.load(Uri.parse(qqUrl), const {}, (_, __) {}),
      throwsA(isA<NetworkImageLoadException>()),
    );
    expect(client.closeCalls, 1);
  });

  test('injected loader does not affect ArtworkNetworkImage equality', () {
    final a = ArtworkNetworkImage(
      qqUrl,
      loader: ArtworkBytesLoader(createClient: FakeArtworkClient.new),
    );
    final b = ArtworkNetworkImage(qqUrl);
    expect(a, b);
    expect(a.hashCode, b.hashCode);
  });
}

/// Deterministic [ArtworkHttpClient] for loader closure/limit tests.
class FakeArtworkClient implements ArtworkHttpClient {
  FakeArtworkClient({
    this.requestError,
    this.statusCode = 200,
    this.contentLength = -1,
    this.chunks = const [],
    this.stall = false,
  });

  factory FakeArtworkClient.response({
    required int statusCode,
    required int contentLength,
    required List<List<int>> chunks,
  }) {
    return FakeArtworkClient(
      statusCode: statusCode,
      contentLength: contentLength,
      chunks: chunks,
    );
  }

  factory FakeArtworkClient.stalled() => FakeArtworkClient(stall: true);

  Object? requestError;
  final int statusCode;
  final int contentLength;
  final List<List<int>> chunks;
  final bool stall;
  int closeCalls = 0;

  @override
  set userAgent(String? value) {}

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    if (requestError != null) {
      throw requestError!;
    }
    if (stall) {
      return Completer<HttpClientRequest>().future;
    }
    return _FakeHttpClientRequest(
      statusCode: statusCode,
      contentLength: contentLength,
      chunks: chunks,
    );
  }

  @override
  void close({bool force = false}) {
    closeCalls++;
  }
}

class _FakeHttpClientRequest implements HttpClientRequest {
  _FakeHttpClientRequest({
    required this.statusCode,
    required this.contentLength,
    required this.chunks,
  });

  final int statusCode;
  @override
  final int contentLength;
  final List<List<int>> chunks;
  final _FakeHttpHeaders _headers = _FakeHttpHeaders();

  @override
  HttpHeaders get headers => _headers;

  @override
  Future<HttpClientResponse> close() async {
    return _FakeHttpClientResponse(
      statusCode: statusCode,
      contentLength: contentLength,
      chunks: chunks,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _FakeHttpClientResponse({
    required this.statusCode,
    required this.contentLength,
    required List<List<int>> chunks,
  }) : _chunks = chunks;

  @override
  final int statusCode;

  @override
  final int contentLength;

  final List<List<int>> _chunks;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.fromIterable(_chunks).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  Future<E> drain<E>([E? futureValue]) async => futureValue as E;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpHeaders implements HttpHeaders {
  final Map<String, List<String>> _values = {};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _values[name.toLowerCase()] = [value.toString()];
  }

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {
    _values.putIfAbsent(name.toLowerCase(), () => []).add(value.toString());
  }

  @override
  List<String>? operator [](String name) => _values[name.toLowerCase()];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
