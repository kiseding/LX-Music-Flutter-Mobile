import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lx_music_flutter/core/storage/storage_service.dart';
import 'package:lx_music_flutter/features/custom_source/domain/custom_source.dart';
import 'package:lx_music_flutter/features/custom_source/domain/custom_source_engine.dart';
import 'package:lx_music_flutter/features/custom_source/domain/custom_source_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('初始安装不自动添加自定义源', () async {
    SharedPreferences.setMockInitialValues({});
    final service = CustomSourceService();
    await service.init();
    expect(service.sources, isEmpty);
    service.dispose();
  });

  test('initialization retains persisted custom sources', () async {
    final now = DateTime.now().toIso8601String();
    SharedPreferences.setMockInitialValues({
      'custom_sources':
          '''
[{"id":"legacy-source","name":"Saved Source","description":"","version":"1.0.0","author":"Author","script":"EVENT_NAMES","createdAt":"$now","updatedAt":"$now","isEnabled":true}]
''',
    });
    final service = CustomSourceService(
      storage: StorageService.forTesting(await SharedPreferences.getInstance()),
    );
    await service.init();
    expect(service.sources.single.id, 'legacy-source');
    service.dispose();
  });

  test(
    'unsafe synchronous growth loop is disabled during initialization',
    () async {
      final now = DateTime.now().toIso8601String();
      const dangerous =
          "new RegExp('x'); function f(){return 'x'}; f['toString'](); "
          "for(let i=0,n=this['items']['length'];i<n;i++){"
          "this['items']['push'](1);n=this['items']['length'];}";
      SharedPreferences.setMockInitialValues({
        'custom_sources': jsonEncode([
          {
            'id': 'unsafe',
            'name': 'Unsafe',
            'description': '',
            'version': '1',
            'author': 'A',
            'script': dangerous,
            'createdAt': now,
            'updatedAt': now,
            'isEnabled': true,
          },
        ]),
      });
      final service = CustomSourceService(
        storage: StorageService.forTesting(
          await SharedPreferences.getInstance(),
        ),
      );

      await service.init();

      expect(service.sources.single.isEnabled, isFalse);
      expect(service.enabledSources, isEmpty);
      service.dispose();
    },
  );

  test('unsafe obfuscator growth loop cannot be enabled', () async {
    SharedPreferences.setMockInitialValues({});
    final service = CustomSourceService(
      storage: StorageService.forTesting(await SharedPreferences.getInstance()),
    );
    await service.init();
    final now = DateTime.now();
    const dangerous =
        "new RegExp('x'); function f(){return 'x'}; f['toString'](); "
        "for(let i=0,n=this['items']['length'];i<n;i++){"
        "this['items']['push'](1);n=this['items']['length'];}";
    await service.addSource(
      CustomSource(
        id: 'unsafe',
        name: 'Unsafe',
        description: '',
        version: '1',
        author: 'A',
        script: dangerous,
        createdAt: now,
        updatedAt: now,
        isEnabled: false,
      ),
    );

    expect(CustomSourceService.hasUnsafeSynchronousLoop(dangerous), isTrue);
    expect(await service.toggleSource('unsafe'), isFalse);
    expect(service.sources.single.isEnabled, isFalse);
    service.dispose();
  });

  test('bounded loops and ordinary minified scripts remain allowed', () {
    const bounded =
        "for(let i=0,n=items.length;i<n;i++){items.push(i)};lx.send('inited',{});";
    expect(CustomSourceService.hasUnsafeSynchronousLoop(bounded), isFalse);
  });

  test('obvious synchronous loops and unguarded recursion are rejected', () {
    expect(
      CustomSourceService.hasUnsafeSynchronousLoop('while (true) {}'),
      isTrue,
    );
    expect(CustomSourceService.hasUnsafeSynchronousLoop('for (;;) {}'), isTrue);
    expect(
      CustomSourceService.hasUnsafeSynchronousLoop('do {} while (true)'),
      isTrue,
    );
    expect(
      CustomSourceService.hasUnsafeSynchronousLoop('function f(){f();}'),
      isTrue,
    );
    expect(
      CustomSourceService.hasUnsafeSynchronousLoop('const f = () => f();'),
      isTrue,
    );
    expect(
      CustomSourceService.hasUnsafeSynchronousLoop(
        'function f(n){if(n>0)return f(n-1);return 0;}',
      ),
      isFalse,
    );
    expect(
      CustomSourceService.hasUnsafeSynchronousLoop(
        'const text = "while (true) {}"; // for (;;) {}',
      ),
      isFalse,
    );
  });

  test(
    'engine rejects unsafe script before creating a JavaScript runtime',
    () async {
      final now = DateTime.now();
      const dangerous =
          "new RegExp('x'); function f(){return 'x'}; f['toString'](); "
          "for(let i=0,n=this['items']['length'];i<n;i++){"
          "this['items']['push'](1);n=this['items']['length'];}";
      final engine = CustomSourceEngine();
      final source = CustomSource(
        id: 'unsafe',
        name: 'Unsafe',
        description: '',
        version: '1',
        author: 'A',
        script: dangerous,
        createdAt: now,
        updatedAt: now,
      );

      expect(await engine.loadSource(source), isFalse);
      engine.dispose();
    },
  );

  test('enabled unsafe JSON import is persisted as disabled', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final service = CustomSourceService(
      storage: StorageService.forTesting(prefs),
    );
    await service.init();
    final now = DateTime.now();
    const dangerous =
        "new RegExp('x'); function f(){return 'x'}; f['toString'](); "
        "for(let i=0,n=this['items']['length'];i<n;i++){"
        "this['items']['push'](1);n=this['items']['length'];}";
    final source = CustomSource(
      id: 'unsafe-import',
      name: 'Unsafe Import',
      description: '',
      version: '1',
      author: 'A',
      script: dangerous,
      createdAt: now,
      updatedAt: now,
      isEnabled: true,
    );

    expect(await service.importSource(jsonEncode(source.toJson())), isTrue);

    expect(service.sources.single.isEnabled, isFalse);
    final persisted = jsonDecode(prefs.getString('custom_sources')!) as List;
    expect((persisted.single as Map<String, dynamic>)['isEnabled'], isFalse);
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

    expect(
      await service.importLxMusicScript('/* @name Test */\nsearch'),
      isFalse,
    );

    expect(service.sources, isEmpty);
    service.dispose();
  });

  test('failed durable delete keeps the in-memory source', () async {
    final now = DateTime.now().toIso8601String();
    SharedPreferences.setMockInitialValues({
      'custom_sources':
          '''
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

  test(
    'delayed failed mutation cannot overwrite a later successful mutation',
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

      final failed = service.importLxMusicScript('/* @name A */\nsearch');
      final succeeded = service.importLxMusicScript('/* @name B */\nsearch');
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
    },
  );

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
      source.copyWith(updatedAt: now.add(const Duration(seconds: 1))),
    );

    expect(sourceWrites, 1);
    service.dispose();
  });

  test(
    'every public source mutation performs at most one durable save',
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
      await expectOneSave(
        () => service.updateSource(source.copyWith(version: '2')),
      );
      await expectOneSave(() => service.toggleSource(source.id));
      await expectOneSave(() async {
        expect(
          await service.importSource(
            jsonEncode(source.copyWith(id: 'two').toJson()),
          ),
          isTrue,
        );
      });
      await expectOneSave(() async {
        expect(
          await service.importLxMusicScript('/* @name Script */\nsearch'),
          isTrue,
        );
      });
      await expectOneSave(() => service.deleteSource(source.id));

      service.dispose();
    },
  );
}
