import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/features/sync/domain/sync_service.dart';

void main() {
  test('connect rejects HTTP instead of silently rewriting it', () async {
    final service = SyncService(dio: Dio());
    addTearDown(service.dispose);

    await expectLater(
      service.connect('http://sync.example.com'),
      throwsA(isA<ArgumentError>()),
    );
    expect(service.serverUrl, isNull);
  });

  test('connect uses normalized HTTPS URL for health check', () async {
    final dio = Dio();
    String? requestedUrl;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requestedUrl = options.uri.toString();
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
            ),
          );
        },
      ),
    );
    final service = SyncService(dio: dio);
    addTearDown(service.dispose);

    final connected =
        await service.connect('  https://sync.example.com/base///  ');

    expect(connected, isTrue);
    expect(service.serverUrl, 'https://sync.example.com/base');
    expect(requestedUrl, 'https://sync.example.com/base/api/health');
  });
}
