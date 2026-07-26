import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lx_music_flutter/features/custom_source/domain/custom_source.dart';
import 'package:lx_music_flutter/features/custom_source/domain/custom_source_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const huibqScript = r'''
/*!
 * @name Huibq_lxmusic源
 * @description test
 * @version v1.2.0
 * @author Huibq
 */
lx.on(lx.EVENT_NAMES.request, async () => null);
lx.send(lx.EVENT_NAMES.inited, { status: true, sources: {} });
''';

  CustomSource manualHuibq({String? id, String name = 'Huibq_lxmusic源'}) {
    final now = DateTime.now();
    return CustomSource(
      id: id ?? '1700000000000',
      name: name,
      description: 'manual',
      version: '1.0.0',
      author: 'Huibq',
      script: huibqScript,
      createdAt: now,
      updatedAt: now,
      isEnabled: false,
    );
  }

  test('init 不会自动种 Huibq', () async {
    SharedPreferences.setMockInitialValues({});
    final service = CustomSourceService();
    await Future.wait([service.init(), service.init()]);
    expect(service.sources, isEmpty);
    service.dispose();
  });

  test('importLxMusicScript 再次导入同脚本不产生第二个 Huibq', () async {
    SharedPreferences.setMockInitialValues({});
    final service = CustomSourceService();
    await service.init();
    expect(await service.importLxMusicScript(huibqScript), isTrue);
    expect(await service.importLxMusicScript(huibqScript), isTrue);
    expect(service.sources.where(_isHuibqLike).length, 1);
    service.dispose();
  });

  test('addSource 重复 Huibq 会被去重', () async {
    SharedPreferences.setMockInitialValues({});
    final service = CustomSourceService();
    await service.init();
    await service.addSource(manualHuibq(id: 'a1'));
    await service.addSource(manualHuibq(id: 'a2'));
    expect(service.sources.where(_isHuibqLike).length, 1);
    service.dispose();
  });
}

bool _isHuibqLike(CustomSource s) {
  final n = s.name.toLowerCase();
  final a = s.author.toLowerCase();
  return s.id == CustomSourceService.defaultSourceId ||
      n.contains('huibq') ||
      a.contains('huibq') ||
      n.contains('lxmusic');
}
