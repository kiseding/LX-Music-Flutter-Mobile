import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/audio/playback_cache_service.dart';
import 'package:lx_music_flutter/core/storage/storage_service.dart';
import 'package:lx_music_flutter/features/download/domain/download_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StorageService failingStorage;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    failingStorage = StorageService.forTesting(
      prefs,
      writeOverride: (operation, key, value) async => false,
    );
  });

  test('playback cache adapter propagates failed durable write', () async {
    final store = PrefsPlaybackCacheIndexStore(storage: failingStorage);

    await expectLater(
      store.write('{}'),
      throwsA(isA<StorageWriteException>()),
    );
  });

  test('download adapter propagates failed durable write', () async {
    final store = StorageDownloadTaskStorage(failingStorage);

    await expectLater(
      store.save(const []),
      throwsA(isA<StorageWriteException>()),
    );
  });
}
