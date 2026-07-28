import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
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

    test('rejects every IPv4 special-purpose prefix at its boundaries',
        () async {
      final policy = policyWith({});
      const prefixes = <List<String>>[
        ['0.0.0.0', '0.255.255.255'],
        ['10.0.0.0', '10.255.255.255'],
        ['100.64.0.0', '100.127.255.255'],
        ['127.0.0.0', '127.255.255.255'],
        ['169.254.0.0', '169.254.255.255'],
        ['172.16.0.0', '172.31.255.255'],
        ['192.0.0.0', '192.0.0.255'],
        ['192.0.2.0', '192.0.2.255'],
        ['192.31.196.0', '192.31.196.255'],
        ['192.52.193.0', '192.52.193.255'],
        ['192.88.99.0', '192.88.99.255'],
        ['192.168.0.0', '192.168.255.255'],
        ['192.175.48.0', '192.175.48.255'],
        ['198.18.0.0', '198.19.255.255'],
        ['198.51.100.0', '198.51.100.255'],
        ['203.0.113.0', '203.0.113.255'],
        ['224.0.0.0', '239.255.255.255'],
        ['240.0.0.0', '255.255.255.255'],
      ];

      for (final prefix in prefixes) {
        for (final address in prefix) {
          await expectLater(
            policy.validate(Uri.parse('https://$address'), {}),
            throwsA(isA<SourceRequestPolicyException>()),
            reason: '$prefix boundary $address',
          );
        }
      }
    });

    test('allows known public IPv4 addresses around special blocks', () async {
      final policy = policyWith({});
      for (final address in [
        '8.8.8.8',
        '93.184.216.34',
        '192.31.195.255',
        '192.31.197.0',
        '192.52.192.255',
        '192.52.194.0',
        '192.88.98.255',
        '192.88.100.0',
        '192.175.47.255',
        '192.175.49.0',
      ]) {
        expect(
          await policy.validate(Uri.parse('https://$address'), {}),
          isA<ValidatedSourceRequest>(),
          reason: address,
        );
      }
    });

    test('rejects every IPv6 special-purpose prefix at its boundaries',
        () async {
      final policy = policyWith({});
      const prefixes = <List<String>>[
        ['::', '::ffff:ffff'],
        ['::ffff:0:0', '::ffff:ffff:ffff'],
        ['64:ff9b::', '64:ff9b::ffff:ffff'],
        ['64:ff9b:1::', '64:ff9b:1:ffff:ffff:ffff:ffff:ffff'],
        ['100::', '100::ffff:ffff:ffff:ffff'],
        ['2001::', '2001:1ff:ffff:ffff:ffff:ffff:ffff:ffff'],
        ['2001:db8::', '2001:db8:ffff:ffff:ffff:ffff:ffff:ffff'],
        ['2002::', '2002:ffff:ffff:ffff:ffff:ffff:ffff:ffff'],
        ['3fff::', '3fff:fff:ffff:ffff:ffff:ffff:ffff:ffff'],
        ['5f00::', '5f00:ffff:ffff:ffff:ffff:ffff:ffff:ffff'],
        ['fc00::', 'fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff'],
        ['fe80::', 'febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff'],
        ['ff00::', 'ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff'],
      ];

      for (final prefix in prefixes) {
        for (final address in prefix) {
          await expectLater(
            policy.validate(Uri.parse('https://[$address]'), {}),
            throwsA(isA<SourceRequestPolicyException>()),
            reason: '$prefix boundary $address',
          );
        }
      }
    });

    test('allows known public IPv6 addresses around special blocks', () async {
      final policy = policyWith({});
      for (final address in [
        '2001:200::1',
        '2001:4860:4860::8888',
        '2606:2800:220:1:248:1893:25c8:1946',
        '3ffe:ffff:ffff:ffff:ffff:ffff:ffff:ffff',
      ]) {
        expect(
          await policy.validate(Uri.parse('https://[$address]'), {}),
          isA<ValidatedSourceRequest>(),
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
    Future<List<ValidatedSourceRequest>> followRedirect({
      required int status,
      String method = 'POST',
      dynamic body = 'payload',
      String location = '/done',
      Map<String, dynamic>? headers,
    }) async {
      final requests = <ValidatedSourceRequest>[];
      final sandbox = SourceRequestSandbox(
        policy: policyWith({
          'one.example': ['93.184.216.34'],
          'two.example': ['93.184.216.35'],
        }),
        transport: (request, cancellation) async {
          requests.add(request);
          return SourceTransportResponse(
            statusCode: requests.length == 1 ? status : 200,
            headers: requests.length == 1
                ? {
                    'location': [location]
                  }
                : const {},
            body: const Stream.empty(),
          );
        },
      );
      await sandbox.request(
        Uri.parse('https://one.example/start'),
        {
          'method': method,
          'body': body,
          'headers': headers ??
              {
                'Content-Type': 'text/plain',
                'Content-Language': 'en',
                'X-Api-Key': 'secret',
              },
        },
      );
      return requests;
    }

    for (final status in [301, 302]) {
      test('$status rewrites POST to GET and drops body content headers',
          () async {
        final requests = await followRedirect(status: status);

        expect(requests.last.method, 'GET');
        expect(requests.last.body, isNull);
        expect(
          requests.last.headers.keys.map((name) => name.toLowerCase()),
          isNot(contains('content-type')),
        );
        expect(requests.last.headers['X-Api-Key'], 'secret');
      });

      test('$status rejects a retained one-shot PUT body', () async {
        await expectLater(
          followRedirect(
            status: status,
            method: 'PUT',
            body: Stream.value([1, 2, 3]),
          ),
          throwsA(
            isA<SourceRequestPolicyException>().having(
              (error) => error.code,
              'code',
              'redirect_body_not_replayable',
            ),
          ),
        );
      });
    }

    test('303 rewrites every method to GET and drops the body', () async {
      final requests = await followRedirect(status: 303, method: 'PUT');

      expect(requests.last.method, 'GET');
      expect(requests.last.body, isNull);
    });

    for (final status in [307, 308]) {
      test('$status preserves a replayable method and body', () async {
        final requests = await followRedirect(status: status, method: 'PUT');

        expect(requests.last.method, 'PUT');
        expect(requests.last.body, 'payload');
        expect(requests.last.headers['Content-Type'], 'text/plain');
      });

      test('$status rejects FormData as a one-shot redirect body', () async {
        await expectLater(
          followRedirect(status: status, body: FormData.fromMap({'a': 'b'})),
          throwsA(
            isA<SourceRequestPolicyException>().having(
              (error) => error.code,
              'code',
              'redirect_body_not_replayable',
            ),
          ),
        );
      });

      test('$status rejects a stream as a one-shot redirect body', () async {
        await expectLater(
          followRedirect(status: status, body: Stream.value([1, 2, 3])),
          throwsA(
            isA<SourceRequestPolicyException>().having(
              (error) => error.code,
              'code',
              'redirect_body_not_replayable',
            ),
          ),
        );
      });
    }

    test('cross-origin redirect forwards only allowlisted caller headers',
        () async {
      final requests = await followRedirect(
        status: 307,
        location: 'https://two.example/done',
        headers: {
          'Accept': 'application/json',
          'Accept-Language': 'en',
          'User-Agent': 'source-agent',
          'Content-Type': 'text/plain',
          'X-Api-Key': 'secret',
          'X-Custom': 'private',
        },
      );

      expect(requests.last.headers['Accept'], 'application/json');
      expect(requests.last.headers['Accept-Language'], 'en');
      expect(requests.last.headers['User-Agent'], 'source-agent');
      expect(requests.last.headers['Content-Type'], 'text/plain');
      expect(requests.last.headers, isNot(contains('X-Api-Key')));
      expect(requests.last.headers, isNot(contains('X-Custom')));
    });

    test('cross-origin body-dropping redirect forwards no content headers',
        () async {
      final requests = await followRedirect(
        status: 302,
        location: 'https://two.example/done',
      );

      expect(requests.last.method, 'GET');
      expect(requests.last.headers, isNot(contains('Content-Type')));
      expect(requests.last.headers, isNot(contains('X-Api-Key')));
    });

    test('rejects multiple Location field values', () async {
      final sandbox = SourceRequestSandbox(
        policy: policyWith({
          'example.com': ['93.184.216.34'],
        }),
        transport: (request, cancellation) async => SourceTransportResponse(
          statusCode: 302,
          headers: {
            'location': ['/one', '/two']
          },
          body: const Stream.empty(),
        ),
      );

      await expectLater(
        sandbox.request(Uri.parse('https://example.com/start'), {}),
        throwsA(
          isA<SourceRequestPolicyException>()
              .having((error) => error.code, 'code', 'ambiguous_redirect'),
        ),
      );
    });

    test('does not follow a non-redirect status carrying Location', () async {
      var calls = 0;
      final sandbox = SourceRequestSandbox(
        policy: policyWith({
          'example.com': ['93.184.216.34'],
        }),
        transport: (request, cancellation) async {
          calls++;
          return SourceTransportResponse(
            statusCode: 304,
            headers: {
              'location': ['/unexpected']
            },
            body: Stream.value([1]),
          );
        },
      );

      final response =
          await sandbox.request(Uri.parse('https://example.com/start'), {});

      expect(calls, 1);
      expect(response.statusCode, 304);
      expect(response.bytes, [1]);
    });

    test('ignores multiple Location values on a success response', () async {
      final sandbox = SourceRequestSandbox(
        policy: policyWith({
          'example.com': ['93.184.216.34'],
        }),
        transport: (request, cancellation) async => SourceTransportResponse(
          statusCode: 200,
          headers: {
            'location': ['/one', '/two']
          },
          body: Stream.value([1]),
        ),
      );

      final response =
          await sandbox.request(Uri.parse('https://example.com/start'), {});

      expect(response.bytes, [1]);
    });

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

    test(
        'cancellation closes a transport response that arrives after race loss',
        () async {
      final transportResult = Completer<SourceTransportResponse>();
      final cancellation = SourceRequestCancellation();
      var closes = 0;
      final sandbox = SourceRequestSandbox(
        policy: policyWith({
          'example.com': ['93.184.216.34'],
        }),
        transport: (request, cancellation) => transportResult.future,
      );

      final result = sandbox.request(
        Uri.parse('https://example.com'),
        {},
        cancellation: cancellation,
      );
      await Future<void>.delayed(Duration.zero);
      cancellation.cancel('disposed');
      await expectLater(result, throwsA(isA<SourceRequestPolicyException>()));

      transportResult.complete(SourceTransportResponse(
        statusCode: 200,
        headers: const {},
        body: const Stream.empty(),
        close: () => closes++,
      ));
      await Future<void>.delayed(Duration.zero);
      expect(closes, 1);
    });

    test('cancellation during DNS never invokes transport', () async {
      final dnsStarted = Completer<void>();
      final dnsResult = Completer<List<InternetAddress>>();
      final cancellation = SourceRequestCancellation();
      var transportCalls = 0;
      final sandbox = SourceRequestSandbox(
        policy: SourceRequestPolicy(resolve: (host) {
          dnsStarted.complete();
          return dnsResult.future;
        }),
        transport: (request, cancellation) async {
          transportCalls++;
          return SourceTransportResponse(
            statusCode: 200,
            headers: const {},
            body: const Stream.empty(),
          );
        },
      );

      final response = sandbox.request(
        Uri.parse('https://example.com'),
        {},
        cancellation: cancellation,
      );
      await dnsStarted.future;
      cancellation.cancel('Source disposed');

      await expectLater(
        response,
        throwsA(
          isA<SourceRequestPolicyException>()
              .having((error) => error.code, 'code', 'cancelled'),
        ),
      );
      dnsResult.complete([publicAddress]);
      await Future<void>.delayed(Duration.zero);
      expect(transportCalls, 0);
    });

    test('pre-cancelled request does not resolve or invoke transport',
        () async {
      var resolverCalls = 0;
      var transportCalls = 0;
      final cancellation = SourceRequestCancellation()..cancel('disposed');
      final sandbox = SourceRequestSandbox(
        policy: SourceRequestPolicy(resolve: (host) async {
          resolverCalls++;
          return [publicAddress];
        }),
        transport: (request, cancellation) async {
          transportCalls++;
          return SourceTransportResponse(
            statusCode: 200,
            headers: const {},
            body: const Stream.empty(),
          );
        },
      );

      await expectLater(
        sandbox.request(
          Uri.parse('https://example.com'),
          {},
          cancellation: cancellation,
        ),
        throwsA(isA<SourceRequestPolicyException>()),
      );
      expect(resolverCalls, 0);
      expect(transportCalls, 0);
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

    test('rejects aggregate in-flight bytes and releases budget', () async {
      final firstBody = StreamController<List<int>>();
      var calls = 0;
      var secondListened = false;
      final sandbox = SourceRequestSandbox(
        policy: policyWith({
          'example.com': ['93.184.216.34'],
        }, maximumResponseBytes: 5),
        maximumInFlightBytes: 5,
        transport: (request, cancellation) async {
          calls++;
          return SourceTransportResponse(
            statusCode: 200,
            headers: const {},
            body: calls == 1
                ? firstBody.stream
                : calls == 2
                    ? Stream<List<int>>.multi((controller) {
                        secondListened = true;
                        controller.add([4, 5, 6]);
                      })
                    : Stream.value([1, 2, 3, 4, 5]),
          );
        },
      );

      final first = sandbox.request(Uri.parse('https://example.com/one'), {});
      firstBody.add([1, 2, 3]);
      await Future<void>.delayed(Duration.zero);
      final second = sandbox.request(Uri.parse('https://example.com/two'), {});

      await expectLater(
        second.timeout(const Duration(seconds: 1)),
        throwsA(
          isA<SourceRequestPolicyException>().having(
            (error) => error.code,
            'code',
            'response_budget_exceeded',
          ),
        ),
      );
      expect(secondListened, isTrue);
      await firstBody.close();
      final firstResponse = await first;
      firstResponse.release();

      final afterRelease =
          await sandbox.request(Uri.parse('https://example.com/three'), {});
      expect(afterRelease.bytes, [1, 2, 3, 4, 5]);
      afterRelease.release();
    });

    test('rejects excess concurrent response bodies and releases the slot',
        () async {
      final firstBody = StreamController<List<int>>();
      var calls = 0;
      final sandbox = SourceRequestSandbox(
        policy: policyWith({
          'example.com': ['93.184.216.34'],
        }),
        maximumConcurrentResponseBodies: 1,
        transport: (request, cancellation) async {
          calls++;
          return SourceTransportResponse(
            statusCode: 200,
            headers: const {},
            body: calls == 1 ? firstBody.stream : const Stream.empty(),
          );
        },
      );

      final first = sandbox.request(Uri.parse('https://example.com/one'), {});
      await Future<void>.delayed(Duration.zero);
      await expectLater(
        sandbox.request(Uri.parse('https://example.com/two'), {}),
        throwsA(
          isA<SourceRequestPolicyException>().having(
            (error) => error.code,
            'code',
            'too_many_response_bodies',
          ),
        ),
      );
      await firstBody.close();
      await first;

      expect(
        await sandbox.request(Uri.parse('https://example.com/three'), {}),
        isA<SourceRequestResponse>(),
      );
    });

    test('acquires request admission before DNS and transfers it to response',
        () async {
      var resolverCalls = 0;
      final sandbox = SourceRequestSandbox(
        policy: SourceRequestPolicy(
            resolve: (host) async {
              resolverCalls++;
              return [publicAddress];
            },
            maximumResponseBytes: 8),
        maximumConcurrentRequests: 1,
        transport: (request, cancellation) async => SourceTransportResponse(
          statusCode: 200,
          headers: const {},
          body: Stream.value([1, 2, 3]),
        ),
      );

      final first =
          await sandbox.request(Uri.parse('https://example.com/one'), {});
      expect(resolverCalls, 1);
      await expectLater(
        sandbox.request(Uri.parse('https://example.com/two'), {}),
        throwsA(
          isA<SourceRequestPolicyException>()
              .having((error) => error.code, 'code', 'too_many_requests'),
        ),
      );
      expect(resolverCalls, 1);

      first.release();
      first.release();
      final second =
          await sandbox.request(Uri.parse('https://example.com/two'), {});
      expect(resolverCalls, 2);
      second.release();
    });

    test('holds actual response bytes until release', () async {
      var calls = 0;
      final sandbox = SourceRequestSandbox(
        policy: policyWith({
          'example.com': ['93.184.216.34'],
        }, maximumResponseBytes: 5),
        maximumConcurrentRequests: 3,
        maximumInFlightBytes: 5,
        transport: (request, cancellation) async {
          calls++;
          return SourceTransportResponse(
            statusCode: 200,
            headers: const {},
            body: Stream.value(calls == 1 ? [1, 2, 3] : [4, 5, 6]),
          );
        },
      );

      final first =
          await sandbox.request(Uri.parse('https://example.com/one'), {});
      await expectLater(
        sandbox.request(Uri.parse('https://example.com/two'), {}),
        throwsA(
          isA<SourceRequestPolicyException>().having(
            (error) => error.code,
            'code',
            'response_budget_exceeded',
          ),
        ),
      );

      first.release();
      final afterRelease =
          await sandbox.request(Uri.parse('https://example.com/three'), {});
      expect(afterRelease.bytes, [4, 5, 6]);
      afterRelease.release();
    });

    test('request errors release admission', () async {
      var fail = true;
      final sandbox = SourceRequestSandbox(
        policy: policyWith({
          'example.com': ['93.184.216.34'],
        }),
        maximumConcurrentRequests: 1,
        transport: (request, cancellation) async {
          if (fail) throw StateError('transport failed');
          return SourceTransportResponse(
            statusCode: 200,
            headers: const {},
            body: const Stream.empty(),
          );
        },
      );

      await expectLater(
        sandbox.request(Uri.parse('https://example.com/fail'), {}),
        throwsStateError,
      );
      fail = false;
      final response =
          await sandbox.request(Uri.parse('https://example.com/ok'), {});
      response.release();
    });

    test('cancellation after body completion releases bytes and admission',
        () async {
      final cancellation = SourceRequestCancellation();
      var calls = 0;
      final sandbox = SourceRequestSandbox(
        policy: policyWith({
          'example.com': ['93.184.216.34'],
        }, maximumResponseBytes: 1),
        maximumConcurrentRequests: 1,
        maximumInFlightBytes: 1,
        transport: (request, sourceCancellation) async {
          calls++;
          if (calls == 1) {
            late StreamController<List<int>> controller;
            controller = StreamController<List<int>>(
                sync: true,
                onListen: () {
                  controller.add([1]);
                  controller.close();
                  cancellation.cancel('disposed');
                });
            return SourceTransportResponse(
              statusCode: 200,
              headers: const {},
              body: controller.stream,
            );
          }
          return SourceTransportResponse(
            statusCode: 200,
            headers: const {},
            body: Stream.value([2]),
          );
        },
      );

      await expectLater(
        sandbox.request(
          Uri.parse('https://example.com/one'),
          {},
          cancellation: cancellation,
        ),
        throwsA(isA<SourceRequestPolicyException>()),
      );
      final next =
          await sandbox.request(Uri.parse('https://example.com/two'), {});
      expect(next.bytes, [2]);
      next.release();
    });

    test('callback gate holds permits and bytes until callback finishes',
        () async {
      final callbackGate = Completer<void>();
      var calls = 0;
      final sandbox = SourceRequestSandbox(
        policy: policyWith({
          'example.com': ['93.184.216.34'],
        }, maximumResponseBytes: 1),
        maximumConcurrentRequests: 2,
        maximumInFlightBytes: 2,
        transport: (request, cancellation) async {
          calls++;
          return SourceTransportResponse(
            statusCode: 200,
            headers: const {},
            body: Stream.value([calls]),
          );
        },
      );
      final first =
          await sandbox.request(Uri.parse('https://example.com/one'), {});
      final second =
          await sandbox.request(Uri.parse('https://example.com/two'), {});
      final firstDelivery = withSourceResponseLease(
        first,
        (_) => callbackGate.future,
      );
      final secondDelivery = withSourceResponseLease(
        second,
        (_) => callbackGate.future,
      );

      await expectLater(
        sandbox.request(Uri.parse('https://example.com/three'), {}),
        throwsA(
          isA<SourceRequestPolicyException>()
              .having((error) => error.code, 'code', 'too_many_requests'),
        ),
      );
      callbackGate.complete();
      await Future.wait([firstDelivery, secondDelivery]);

      final third =
          await sandbox.request(Uri.parse('https://example.com/three'), {});
      third.release();
    });

    test('cancellation after response handoff releases its lease', () async {
      final cancellation = SourceRequestCancellation();
      final sandbox = SourceRequestSandbox(
        policy: policyWith({
          'example.com': ['93.184.216.34'],
        }, maximumResponseBytes: 1),
        maximumConcurrentRequests: 1,
        maximumInFlightBytes: 1,
        transport: (request, sourceCancellation) async =>
            SourceTransportResponse(
          statusCode: 200,
          headers: const {},
          body: Stream.value([1]),
        ),
      );

      await sandbox.request(
        Uri.parse('https://example.com/one'),
        {},
        cancellation: cancellation,
      );
      cancellation.cancel('disposed');
      await Future<void>.delayed(Duration.zero);

      final next =
          await sandbox.request(Uri.parse('https://example.com/two'), {});
      next.release();
    });

    test('redirect setup failures close response exactly once', () async {
      for (final testCase in <({String name, String location, dynamic body})>[
        (name: 'malformed location', location: 'http://[', body: 'body'),
        (
          name: 'FormData',
          location: '/next',
          body: FormData.fromMap({'a': 'b'}),
        ),
        (
          name: 'stream',
          location: '/next',
          body: Stream.value([1]),
        ),
      ]) {
        var closes = 0;
        final sandbox = SourceRequestSandbox(
          policy: policyWith({
            'example.com': ['93.184.216.34'],
          }),
          transport: (request, cancellation) async => SourceTransportResponse(
            statusCode: 307,
            headers: {
              'location': [testCase.location]
            },
            body: const Stream.empty(),
            close: () => closes++,
          ),
        );

        await expectLater(
          sandbox.request(
            Uri.parse('https://example.com/start'),
            {'method': 'POST', 'body': testCase.body},
          ),
          throwsA(anything),
          reason: testCase.name,
        );
        expect(closes, 1, reason: testCase.name);
      }
    });

    test('ambiguous redirect closes response exactly once', () async {
      var closes = 0;
      final sandbox = SourceRequestSandbox(
        policy: policyWith({
          'example.com': ['93.184.216.34'],
        }),
        transport: (request, cancellation) async => SourceTransportResponse(
          statusCode: 302,
          headers: {
            'location': ['/one', '/two']
          },
          body: const Stream.empty(),
          close: () => closes++,
        ),
      );

      await expectLater(
        sandbox.request(Uri.parse('https://example.com/start'), {}),
        throwsA(isA<SourceRequestPolicyException>()),
      );
      expect(closes, 1);
    });

    test('redirect without Location closes response exactly once', () async {
      var closes = 0;
      final sandbox = SourceRequestSandbox(
        policy: policyWith({
          'example.com': ['93.184.216.34'],
        }),
        transport: (request, cancellation) async => SourceTransportResponse(
          statusCode: 302,
          headers: const {},
          body: Stream.value([1]),
          close: () => closes++,
        ),
      );

      final response =
          await sandbox.request(Uri.parse('https://example.com/start'), {});
      response.release();

      expect(closes, 1);
    });
  });
}
