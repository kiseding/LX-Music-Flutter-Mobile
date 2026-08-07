import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/network/ios_source_transport.dart';
import 'package:lx_music_flutter/core/network/source_pinned_transport.dart';
import 'package:lx_music_flutter/core/network/source_request_policy.dart';

void main() {
  test('always delegates validated requests to the pinned transport', () async {
    late ValidatedSourceRequest received;
    final pinned = SourcePinnedTransport(
      execute: (_, request, __) async {
        received = request;
        throw StateError('executed');
      },
    );
    final request = ValidatedSourceRequest(
      uri: Uri.parse('https://source.example/path'),
      addresses: [InternetAddress('93.184.216.34')],
      method: 'GET',
      headers: const {},
      body: null,
      timeout: const Duration(seconds: 1),
    );

    await expectLater(
      IOSSourceTransport(
        fallback: pinned,
      ).call(request, SourceRequestCancellation()),
      throwsStateError,
    );
    expect(received.addresses.single.address, '93.184.216.34');
    expect(received.uri.host, 'source.example');
  });
}
