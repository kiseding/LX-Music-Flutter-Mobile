import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lx_music_flutter/features/custom_source/domain/custom_source_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('importLxMusicScript 解析元数据并可删除', () async {
    SharedPreferences.setMockInitialValues({});
    final service = CustomSourceService();
    // 跳过网络 seed：先标记已 seed
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('default_source_seeded', true);
    await service.init();

    final script = r'''
/*!
 * @name SeedScript
 * @description desc
 * @version v9.9.9
 * @author Tester
 */
lx.on(lx.EVENT_NAMES.request, async () => null);
lx.send(lx.EVENT_NAMES.inited, { status: true, sources: {} });
''';

    final ok = await service.importLxMusicScript(script);
    expect(ok, isTrue);
    expect(service.sources.any((s) => s.name == 'SeedScript'), isTrue);
    // 无其它启用源时，导入应自动启用
    expect(service.sources.firstWhere((s) => s.name == 'SeedScript').isEnabled, isTrue);

    final id = service.sources.firstWhere((s) => s.name == 'SeedScript').id;
    await service.deleteSource(id);
    expect(service.sources.any((s) => s.id == id), isFalse);
    service.dispose();
  });
}
