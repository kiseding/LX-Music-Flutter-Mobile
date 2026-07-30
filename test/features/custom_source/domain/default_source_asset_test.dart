import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lx_music_flutter/core/storage/storage_service.dart';
import 'package:lx_music_flutter/features/custom_source/domain/custom_source.dart';
import 'package:lx_music_flutter/features/custom_source/domain/custom_source_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('不再自动种入内置 Huibq 音源', () async {
    SharedPreferences.setMockInitialValues({});
    final service = CustomSourceService();
    await service.init();
    expect(
        service.sources
            .where((s) => s.id == CustomSourceService.defaultSourceId),
        isEmpty);
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
    expect(
        service.sources.any((s) => s.id == CustomSourceService.defaultSourceId),
        isFalse);
    service.dispose();
  });

  test('failed durable import does not report or retain success', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final storage = StorageService.forTesting(
      prefs,
      writeOverride: (operation, key, value) async => key != 'custom_sources',
    );
    final service = CustomSourceService(storage: storage);
    await service.init();

    expect(await service.importLxMusicScript('// @name Test\nsearch'), isFalse);

    expect(service.sources, isEmpty);
    service.dispose();
  });

  test('failed durable delete keeps the in-memory source', () async {
    final now = DateTime.now().toIso8601String();
    SharedPreferences.setMockInitialValues({
      'custom_sources': '''
[{"id":"user-source","name":"User","description":"","version":"1.0.0","author":"Me","script":"search","createdAt":"$now","updatedAt":"$now","isEnabled":true}]
''',
    });
    final prefs = await SharedPreferences.getInstance();
    var failWrites = false;
    final storage = StorageService.forTesting(
      prefs,
      writeOverride: (operation, key, value) async => !failWrites,
    );
    final service = CustomSourceService(storage: storage);
    await service.init();
    failWrites = true;

    await expectLater(
      service.deleteSource('user-source'),
      throwsA(isA<StorageWriteException>()),
    );

    expect(service.sources.single.id, 'user-source');
    service.dispose();
  });

  test('delayed failed mutation cannot overwrite a later successful mutation',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final firstWrite = Completer<bool>();
    final writes = <String>[];
    final storage = StorageService.forTesting(
      prefs,
      writeOverride: (operation, key, value) async {
        if (key != 'custom_sources') return true;
        final raw = value! as String;
        writes.add(raw);
        if (writes.length == 1) return firstWrite.future;
        await prefs.setString(key, raw);
        return true;
      },
    );
    final service = CustomSourceService(storage: storage);
    await service.init();

    final failed = service.importLxMusicScript('// @name A\nsearch');
    final succeeded = service.importLxMusicScript('// @name B\nsearch');
    await Future<void>.delayed(Duration.zero);
    expect(writes, hasLength(1));

    firstWrite.complete(false);
    expect(await failed, isFalse);
    expect(await succeeded, isTrue);

    final durable = (jsonDecode(prefs.getString('custom_sources')!) as List)
        .cast<Map<String, dynamic>>();
    expect(service.sources.map((source) => source.name), ['B']);
    expect(durable.map((source) => source['name']), ['B']);
    expect(writes, hasLength(2));
    service.dispose();
  });

  test('deduplicating add performs one durable source write', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    var sourceWrites = 0;
    final storage = StorageService.forTesting(
      prefs,
      writeOverride: (operation, key, value) async {
        if (key == 'custom_sources') sourceWrites++;
        return true;
      },
    );
    final service = CustomSourceService(storage: storage);
    await service.init();
    final now = DateTime.now();
    final source = CustomSource(
      id: 'same',
      name: 'Same',
      description: '',
      version: '1',
      author: 'Author',
      script: 'search',
      createdAt: now,
      updatedAt: now,
    );

    await service.addSource(source);
    sourceWrites = 0;
    await service.addSource(
        source.copyWith(updatedAt: now.add(const Duration(seconds: 1))));

    expect(sourceWrites, 1);
    service.dispose();
  });

  test('every public source mutation performs at most one durable save',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    var sourceWrites = 0;
    final storage = StorageService.forTesting(
      prefs,
      writeOverride: (operation, key, value) async {
        if (key == 'custom_sources') sourceWrites++;
        return true;
      },
    );
    final service = CustomSourceService(storage: storage);
    await service.init();
    final now = DateTime.now();
    final source = CustomSource(
      id: 'one',
      name: 'One',
      description: '',
      version: '1',
      author: 'Author',
      script: 'search',
      createdAt: now,
      updatedAt: now,
    );

    Future<void> expectOneSave(Future<void> Function() mutation) async {
      final before = sourceWrites;
      await mutation();
      expect(sourceWrites - before, 1);
    }

    await expectOneSave(() => service.addSource(source));
    await expectOneSave(() => service.updateSource(source.copyWith(version: '2')));
    await expectOneSave(() => service.toggleSource(source.id));
    await expectOneSave(() async {
      expect(await service.importSource(jsonEncode(source.copyWith(id: 'two').toJson())), isTrue);
    });
    await expectOneSave(() async {
      expect(await service.importLxMusicScript('// @name Script\nsearch'), isTrue);
    });
    await expectOneSave(() => service.deleteSource(source.id));

    service.dispose();
  });
}
