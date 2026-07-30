import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/features/settings/presentation/settings_provider.dart';
import 'package:lx_music_flutter/features/sync/domain/sync_service.dart';
import 'package:lx_music_flutter/features/sync/presentation/sync_provider.dart';

final class _ControlledSyncService extends SyncService {
  final connectResult = Completer<bool>();
  var disconnectCalls = 0;

  @override
  Future<bool> connect(String serverUrl, {String? token}) =>
      connectResult.future;

  @override
  Future<String?> loadSavedToken({String? serverUrl}) async => 'token';

  @override
  void disconnect() {
    disconnectCalls++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('late notifier connect cannot publish after disconnect', () async {
    final service = _ControlledSyncService();
    final container = ProviderContainer(overrides: [
      syncServiceProvider.overrideWithValue(service),
      syncServerUrlProvider.overrideWith((ref) =>
          SyncServerUrlNotifier(initialValue: 'https://sync.example')),
    ]);
    addTearDown(container.dispose);
    final notifier = container.read(syncConnectionProvider.notifier);

    final connect = notifier.connect();
    await Future<void>.delayed(Duration.zero);
    notifier.disconnect();
    service.connectResult.complete(true);

    expect(await connect, isFalse);
    expect(container.read(syncConnectionProvider), isFalse);
    expect(service.disconnectCalls, 1);
  });
}
