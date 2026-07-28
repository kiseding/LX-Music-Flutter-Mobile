import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/network/source_request_policy.dart';

void main() {
  final publicAddress = InternetAddress('93.184.216.34');

  SourceRequestPolicy policyWith(Map<String, List<String>> records,
      {int maximumResponseBytes = 1024}) {
    return SourceRequestPolicy(
      resolve: (host) async =>
          (records[host] ?? const []).map(InternetAddress.new).toList(),
      maximumResponseBytes: maximumResponseBytes,
    );
  }

  group('SourceRequestPolicy', () {
    test('allows a public HTTPS destination', () async {
      final policy = policyWith({
        'example.com': ['93.184.216.34'],
      });

      final request =
          await policy.validate(Uri.parse('https://example.com/a'), {});

      expect(request.uri, Uri.parse('https://example.com/a'));
      expect(request.addresses, [publicAddress]);
    });

    test('rejects cleartext, credentials, and missing hosts', () async {
      final policy = policyWith({
        'example.com': ['93.184.216.34'],
      });

      for (final value in [
        'http://example.com/a',
        'https://user:pass@example.com/a',
        'https:///a',
      ]) {
        await expectLater(
          policy.validate(Uri.parse(value), {}),
          throwsA(isA<SourceRequestPolicyException>()),
          reason: value,
        );
      }
    });

    test('rejects non-public IPv4 destinations and DNS answers', () async {
      final policy = policyWith({});
      for (final address in [
        '0.0.0.0',
        '10.0.0.1',
        '100.64.0.1',
        '127.0.0.1',
        '169.254.1.1',
        '172.16.0.1',
        '192.168.0.1',
        '192.0.2.1',
        '198.18.0.1',
        '198.51.100.1',
        '203.0.113.1',
        '224.0.0.1',
        '240.0.0.1',
        '255.255.255.255',
      ]) {
        await expectLater(
          policy.validate(Uri.parse('https://$address/a'), {}),
          throwsA(isA<SourceRequestPolicyException>()),
          reason: address,
        );
      }
    });

    test('rejects non-public IPv6 destinations and DNS answers', () async {
      final policy = policyWith({});
      for (final address in [
        '::',
        '::1',
        '::ffff:127.0.0.1',
        'fc00::1',
        'fe80::1',
        'ff02::1',
        '2001:db8::1',
      ]) {
        await expectLater(
          policy.validate(Uri.parse('https://[$address]/a'), {}),
          throwsA(isA<SourceRequestPolicyException>()),
          reason: address,
        );
      }
    });

    test('rejects a DNS result containing any non-public address', () async {
      final policy = policyWith({
        'mixed.example': ['93.184.216.34', '127.0.0.1'],
      });

      await expectLater(
        policy.validate(Uri.parse('https://mixed.example/a'), {}),
        throwsA(
          isA<SourceRequestPolicyException>()
              .having((error) => error.code, 'code', 'blocked_address'),
        ),
      );
    });

    test('rejects empty DNS results', () async {
      final policy = policyWith({'missing.example': []});

      await expectLater(
        policy.validate(Uri.parse('https://missing.example/a'), {}),
        throwsA(
          isA<SourceRequestPolicyException>()
              .having((error) => error.code, 'code', 'dns_failed'),
        ),
      );
    });

    test('strips sensitive and hop-by-hop headers case-insensitively',
        () async {
      final policy = policyWith({
        'example.com': ['93.184.216.34'],
      });

      final request = await policy.validate(Uri.parse('https://example.com'), {
        'headers': {
          'Host': 'internal',
          'Authorization': 'secret',
          'Cookie': 'session=secret',
          'Proxy-Authorization': 'secret',
          'Connection': 'keep-alive',
          'Transfer-Encoding': 'chunked',
          'Content-Length': '999',
          'X-Forwarded-For': '127.0.0.1',
          'X-Custom': 'compatible',
        },
      });

      expect(request.headers['X-Custom'], 'compatible');
      expect(
        request.headers.keys.map((name) => name.toLowerCase()),
        isNot(containsAll([
          'host',
          'authorization',
          'cookie',
          'connection',
          'transfer-encoding',
          'content-length',
          'x-forwarded-for',
        ])),
      );
    });

    test('clamps timeout to the supported range', () async {
      final policy = policyWith({
        'example.com': ['93.184.216.34'],
      });

      final short = await policy
          .validate(Uri.parse('https://example.com'), {'timeout': -1});
      final long = await policy
          .validate(Uri.parse('https://example.com'), {'timeout': 999999});

      expect(short.timeout, const Duration(milliseconds: 1));
      expect(long.timeout, const Duration(seconds: 60));
    });
  });

  group('SourceRequestSandbox', () {
    test('validates every redirect and passes validated addresses to transport',
        () async {
      final resolvedHosts = <String>[];
      final transported = <ValidatedSourceRequest>[];
      final policy = SourceRequestPolicy(resolve: (host) async {
        resolvedHosts.add(host);
        return [publicAddress];
      });
      final sandbox = SourceRequestSandbox(
        policy: policy,
        transport: (request, cancellation) async {
          transported.add(request);
          if (request.uri.path == '/start') {
            return SourceTransportResponse(
              statusCode: 302,
              headers: {
                'location': ['/next']
              },
              body: const Stream.empty(),
            );
          }
          return SourceTransportResponse(
            statusCode: 200,
            statusMessage: 'OK',
            headers: const {},
            body: Stream.value([1, 2, 3]),
          );
        },
      );

      final response = await sandbox.request(
        Uri.parse('https://one.example/start'),
        {},
      );

      expect(response.bytes, [1, 2, 3]);
      expect(response.statusMessage, 'OK');
      expect(resolvedHosts, ['one.example', 'one.example']);
      expect(transported, hasLength(2));
      expect(
        transported.every((request) =>
            request.addresses.length == 1 &&
            request.addresses.single.address == publicAddress.address),
        isTrue,
      );
    });

    test('blocks a redirect whose DNS contains a private result', () async {
      final policy = policyWith({
        'public.example': ['93.184.216.34'],
        'private.example': ['93.184.216.34', '10.0.0.1'],
      });
      final sandbox = SourceRequestSandbox(
        policy: policy,
        transport: (request, cancellation) async => SourceTransportResponse(
          statusCode: 302,
          headers: {
            'location': ['https://private.example/secret']
          },
          body: const Stream.empty(),
        ),
      );

      await expectLater(
        sandbox.request(Uri.parse('https://public.example/start'), {}),
        throwsA(isA<SourceRequestPolicyException>()),
      );
    });

    test('bounds redirects', () async {
      final sandbox = SourceRequestSandbox(
        policy: policyWith({
          'example.com': ['93.184.216.34'],
        }),
        maximumRedirects: 1,
        transport: (request, cancellation) async => SourceTransportResponse(
          statusCode: 302,
          headers: {
            'location': ['/again']
          },
          body: const Stream.empty(),
        ),
      );

      await expectLater(
        sandbox.request(Uri.parse('https://example.com/start'), {}),
        throwsA(
          isA<SourceRequestPolicyException>()
              .having((error) => error.code, 'code', 'too_many_redirects'),
        ),
      );
    });

    test('rejects a streamed response over the byte limit', () async {
      final sandbox = SourceRequestSandbox(
        policy: policyWith({
          'example.com': ['93.184.216.34'],
        }, maximumResponseBytes: 4),
        transport: (request, cancellation) async => SourceTransportResponse(
          statusCode: 200,
          headers: const {},
          body: Stream.fromIterable([
            [1, 2, 3],
            [4, 5],
          ]),
        ),
      );

      await expectLater(
        sandbox.request(Uri.parse('https://example.com'), {}),
        throwsA(
          isA<SourceRequestPolicyException>()
              .having((error) => error.code, 'code', 'response_too_large'),
        ),
      );
    });

    test('cancellation prevents a late response from being exposed', () async {
      final body = StreamController<List<int>>();
      final cancellation = SourceRequestCancellation();
      final sandbox = SourceRequestSandbox(
        policy: policyWith({
          'example.com': ['93.184.216.34'],
        }),
        transport: (request, cancellation) async => SourceTransportResponse(
          statusCode: 200,
          headers: const {},
          body: body.stream,
        ),
      );

      final response = sandbox.request(
        Uri.parse('https://example.com'),
        {},
        cancellation: cancellation,
      );
      final expectation = expectLater(
        response,
        throwsA(
          isA<SourceRequestPolicyException>()
              .having((error) => error.code, 'code', 'cancelled'),
        ),
      );
      cancellation.cancel('disposed');
      await expectation;
      unawaited(body.close());
    });

    test('bounds a stalled transport by the validated timeout', () async {
      final sandbox = SourceRequestSandbox(
        policy: policyWith({
          'example.com': ['93.184.216.34'],
        }),
        transport: (request, cancellation) =>
            Completer<SourceTransportResponse>().future,
      );

      await expectLater(
        sandbox.request(
          Uri.parse('https://example.com'),
          {'timeout': 1},
        ),
        throwsA(
          isA<SourceRequestPolicyException>()
              .having((error) => error.code, 'code', 'timeout'),
        ),
      );
    });

    test('bounds stalled DNS resolution by the requested timeout', () async {
      final sandbox = SourceRequestSandbox(
        policy: SourceRequestPolicy(
          resolve: (host) => Completer<List<InternetAddress>>().future,
        ),
        transport: (request, cancellation) async => SourceTransportResponse(
          statusCode: 200,
          headers: const {},
          body: const Stream.empty(),
        ),
      );

      await expectLater(
        sandbox.request(
          Uri.parse('https://example.com'),
          {'timeout': 1},
        ),
        throwsA(
          isA<SourceRequestPolicyException>()
              .having((error) => error.code, 'code', 'timeout'),
        ),
      );
    });

    test('cancels while waiting for a stalled response chunk', () async {
      final body = StreamController<List<int>>();
      final transportStarted = Completer<void>();
      final cancellation = SourceRequestCancellation();
      final sandbox = SourceRequestSandbox(
        policy: policyWith({
          'example.com': ['93.184.216.34'],
        }),
        transport: (request, cancellation) async {
          transportStarted.complete();
          return SourceTransportResponse(
            statusCode: 200,
            headers: const {},
            body: body.stream,
          );
        },
      );

      final response = sandbox.request(
        Uri.parse('https://example.com'),
        {},
        cancellation: cancellation,
      );
      await transportStarted.future;
      cancellation.cancel('disposed');

      await expectLater(
        response.timeout(const Duration(seconds: 1)),
        throwsA(
          isA<SourceRequestPolicyException>()
              .having((error) => error.code, 'code', 'cancelled'),
        ),
      );
      unawaited(body.close());
    });

    test('closes an unconsumed redirect response', () async {
      var closed = false;
      final sandbox = SourceRequestSandbox(
        policy: policyWith({
          'example.com': ['93.184.216.34'],
        }),
        transport: (request, cancellation) async => SourceTransportResponse(
          statusCode: request.uri.path == '/start' ? 302 : 200,
          headers: request.uri.path == '/start'
              ? {
                  'location': ['/done']
                }
              : const {},
          body: const Stream.empty(),
          close: () => closed = true,
        ),
      );

      await sandbox.request(Uri.parse('https://example.com/start'), {});

      expect(closed, isTrue);
    });
  });
}
