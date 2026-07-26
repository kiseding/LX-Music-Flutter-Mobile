import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lx_music_flutter/features/custom_source/domain/custom_source_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('不再自动种入内置 Huibq 音源', () async {
    SharedPreferences.setMockInitialValues({});
    final service = CustomSourceService();
    await service.init();
    expect(service.sources.where((s) => s.id == CustomSourceService.defaultSourceId), isEmpty);
    expect(service.sources, isEmpty);
    service.dispose();
  });

  test('启动时清除历史 default_huibq', () async {
    final now = DateTime.now().toIso8601String();
    SharedPreferences.setMockInitialValues({
      'custom_sources': '''
[{"id":"default_huibq","name":"Huibq_lxmusic源","description":"","version":"1.0.0","author":"Huibq","script":"EVENT_NAMES","createdAt":"$now","updatedAt":"$now","isEnabled":true}]
''',
    });
    final service = CustomSourceService();
    await service.init();
    expect(service.sources.any((s) => s.id == CustomSourceService.defaultSourceId), isFalse);
    service.dispose();
  });
}
