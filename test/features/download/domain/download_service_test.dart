import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/features/download/domain/download_service.dart';
import 'package:lx_music_flutter/features/download/domain/download_task.dart';
import 'package:lx_music_flutter/features/player/domain/music_item.dart';

class _MemoryStorage implements DownloadTaskStorage {
  List<Map<String, dynamic>> saved = [];
  List<Map<String, dynamic>> quarantine = [];
  int writes = 0;

  @override
  List<dynamic> load() => saved;

  @override
  Future<void> save(List<Map<String, dynamic>> tasks) async {
    writes++;
    saved = tasks;
  }

  @override
  List<Map<String, dynamic>> loadQuarantine() => quarantine;

  @override
  Future<void> saveQuarantine(List<Map<String, dynamic>> records) async {
    quarantine = records;
  }
}

class _GatedDownloader {
  final started = <String>[];
  final _gates = <String, Completer<void>>{};

  int get active => _gates.values.where((gate) => !gate.isCompleted).length;

  Future<void> call(
    DownloadTask task,
    CancelToken _,
    void Function(int, int) progress,
  ) {
    started.add(task.id);
    progress(50, 100);
    return (_gates[task.id] ??= Completer<void>()).future;
  }

  void complete(String id) => _gates[id]!.complete();

  void completeAll() {
    for (final gate in _gates.values) {
      if (!gate.isCompleted) gate.complete();
    }
  }
}

class _AttemptGatedDownloader {
  final attempts = <_DownloadAttempt>[];

  Future<void> call(
    DownloadTask task,
    CancelToken _,
    void Function(int, int) progress,
  ) {
    final attempt = _DownloadAttempt(task, progress);
    attempts.add(attempt);
    return attempt.gate.future;
  }
}

class _DownloadAttempt {
  _DownloadAttempt(this.task, this.progress);

  final DownloadTask task;
  final void Function(int, int) progress;
  final gate = Completer<void>();
}

class _FailFirstStorage extends _MemoryStorage {
  bool _fail = true;

  @override
  Future<void> save(List<Map<String, dynamic>> tasks) async {
    if (_fail) {
      _fail = false;
      throw StateError('first write fails');
    }
    await super.save(tasks);
  }
}

MusicItem _song(String id) => MusicItem(
      id: id,
      name: 'Song $id',
      singer: 'Singer',
      platform: 'tx',
      source: 'tx',
    );

void main() {
  test('never starts more than maxConcurrent downloads', () async {
    final downloader = _GatedDownloader();
    final service = DownloadService(
      maxConcurrent: 2,
      downloader: downloader.call,
      storage: _MemoryStorage(),
      taskIdFactory: () => 'id-${DateTime.now().microsecondsSinceEpoch}',
    );
    addTearDown(() async {
      downloader.completeAll();
      await service.dispose();
    });

    await service.addTasks([_song('a'), _song('b'), _song('c')]);
    expect(downloader.active, 2);
    expect(downloader.started, hasLength(2));
    downloader.complete(downloader.started.first);
    await Future<void>.delayed(Duration.zero);
    expect(downloader.started, hasLength(3));
  });

  test('uses injected IDs and does not schedule a task twice', () async {
    final downloader = _GatedDownloader();
    final service = DownloadService(
      downloader: downloader.call,
      storage: _MemoryStorage(),
      taskIdFactory: () => 'fixed-id',
    );
    addTearDown(() async {
      downloader.completeAll();
      await service.dispose();
    });

    await service.addTasks([_song('a'), _song('a')]);
    expect(service.tasks.single.id, 'fixed-id');
    expect(downloader.started, ['fixed-id']);
  });

  test(
    'computes live bytes per second and resets it on terminal states',
    () async {
      var now = DateTime.utc(2026);
      late void Function(int, int) report;
      final gate = Completer<void>();
      final service = DownloadService(
        downloader: (_, __, progress) {
          report = progress;
          return gate.future;
        },
        storage: _MemoryStorage(),
        taskIdFactory: () => 'speed-id',
        clock: () => now,
      );
      addTearDown(() async {
        if (!gate.isCompleted) gate.complete();
        await service.dispose();
      });

      await service.addTask(_song('a'));
      report(1000, 4000);
      now = now.add(const Duration(milliseconds: 500));
      report(2000, 4000);
      expect(service.tasks.single.speed, 2000);

      service.pauseTask('speed-id');
      expect(service.tasks.single.speed, 0);
      gate.complete();
      await service.idle;
    },
  );

  test('completed and failed downloads reset live speed', () async {
    for (final fails in [false, true]) {
      var now = DateTime.utc(2026);
      late void Function(int, int) report;
      final gate = Completer<void>();
      final service = DownloadService(
        downloader: (_, __, progress) {
          report = progress;
          return gate.future;
        },
        storage: _MemoryStorage(),
        taskIdFactory: () => fails ? 'failed-id' : 'completed-id',
        clock: () => now,
      );

      await service.addTask(_song(fails ? 'failed' : 'completed'));
      report(1000, 4000);
      now = now.add(const Duration(seconds: 1));
      report(2000, 4000);
      expect(service.tasks.single.speed, 1000);

      if (fails) {
        gate.completeError(StateError('download failed'));
      } else {
        gate.complete();
      }
      await service.idle;
      expect(
        service.tasks.single.status,
        fails ? DownloadStatus.failed : DownloadStatus.completed,
      );
      expect(service.tasks.single.speed, 0);
      await service.dispose();
    }
  });

  test(
    'wifi-only policy pauses on loss and restarts when Wi-Fi returns',
    () async {
      final network = StreamController<DownloadNetwork>.broadcast();
      final downloader = _GatedDownloader();
      final service = DownloadService(
        wifiOnly: true,
        currentNetwork: () async => DownloadNetwork.wifi,
        connectivity: network.stream,
        downloader: downloader.call,
        storage: _MemoryStorage(),
        taskIdFactory: () => 'wifi-id',
      );
      addTearDown(() async {
        downloader.completeAll();
        await network.close();
        await service.dispose();
      });

      await service.addTask(_song('a'));
      await Future<void>.delayed(Duration.zero);
      expect(downloader.started, ['wifi-id']);
      network.add(DownloadNetwork.mobile);
      await Future<void>.delayed(Duration.zero);
      expect(service.tasks.single.status, DownloadStatus.pending);
      downloader.complete('wifi-id');
      await service.idle;
      network.add(DownloadNetwork.wifi);
      await service.idle;
      expect(downloader.started, hasLength(2));
    },
  );

  test('wifi loss keeps the executor reservation until it returns', () async {
    final network = StreamController<DownloadNetwork>.broadcast();
    final downloader = _AttemptGatedDownloader();
    final service = DownloadService(
      wifiOnly: true,
      currentNetwork: () async => DownloadNetwork.wifi,
      connectivity: network.stream,
      maxConcurrent: 1,
      downloader: downloader.call,
      storage: _MemoryStorage(),
      taskIdFactory: () => 'wifi-id',
    );
    addTearDown(() async {
      for (final attempt in downloader.attempts) {
        if (!attempt.gate.isCompleted) attempt.gate.complete();
      }
      await service.dispose();
      await network.close();
    });

    await service.addTask(_song('a'));
    await Future<void>.delayed(Duration.zero);
    network.add(DownloadNetwork.mobile);
    await Future<void>.delayed(Duration.zero);
    expect(service.tasks.single.status, DownloadStatus.pending);
    expect(service.activeTaskIds, {'wifi-id'});

    network.add(DownloadNetwork.wifi);
    await Future<void>.delayed(Duration.zero);
    expect(downloader.attempts, hasLength(1));

    downloader.attempts.single.gate.complete();
    await Future<void>.delayed(Duration.zero);
    expect(downloader.attempts, hasLength(2));
  });

  test(
    'delayed Wi-Fi answer after mobile event cannot reserve a slot',
    () async {
      final answer = Completer<DownloadNetwork>();
      final network = StreamController<DownloadNetwork>.broadcast();
      final downloader = _GatedDownloader();
      final service = DownloadService(
        wifiOnly: true,
        currentNetwork: () => answer.future,
        connectivity: network.stream,
        downloader: downloader.call,
        storage: _MemoryStorage(),
        taskIdFactory: () => 'epoch-id',
      );
      addTearDown(() async {
        if (!answer.isCompleted) answer.complete(DownloadNetwork.mobile);
        downloader.completeAll();
        await network.close();
        await service.dispose();
      });

      await service.addTask(_song('a'));
      network.add(DownloadNetwork.mobile);
      await Future<void>.delayed(Duration.zero);
      answer.complete(DownloadNetwork.wifi);
      await Future<void>.delayed(Duration.zero);

      expect(downloader.started, isEmpty);
      expect(service.activeTaskIds, isEmpty);
    },
  );

  test('stale callbacks cannot mutate a retry attempt', () async {
    final downloader = _AttemptGatedDownloader();
    final service = DownloadService(
      maxConcurrent: 1,
      downloader: downloader.call,
      storage: _MemoryStorage(),
      taskIdFactory: () => 'retry-id',
    );
    addTearDown(() async {
      for (final attempt in downloader.attempts) {
        if (!attempt.gate.isCompleted) attempt.gate.complete();
      }
      await service.dispose();
    });

    await service.addTask(_song('a'));
    final original = downloader.attempts.single;
    service.retryTask('retry-id');
    original.progress(90, 100);
    expect(service.tasks.single.progress, 0);

    original.gate.completeError(StateError('old attempt failed'));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(downloader.attempts, hasLength(2));
    expect(
      downloader.attempts.last.task.attemptRevision,
      service.tasks.single.attemptRevision,
    );
    expect(service.tasks.single.status, DownloadStatus.downloading);
    expect(
      DownloadService.completedPathName(
        'retry-id',
        original.task.attemptRevision,
        '.mp3',
      ),
      isNot(
        DownloadService.completedPathName(
          'retry-id',
          service.tasks.single.attemptRevision,
          '.mp3',
        ),
      ),
    );
  });

  test('a failed persistence write does not poison later snapshots', () async {
    final storage = _FailFirstStorage();
    final service = DownloadService(
      downloader: (_, __, ___) async {},
      storage: storage,
      taskIdFactory: () => 'persist-${storage.writes}',
    );
    addTearDown(service.dispose);

    await expectLater(service.addTask(_song('a')), throwsStateError);
    await service.addTask(_song('b'));
    await service.persistenceIdle;
    expect(storage.saved, hasLength(2));
  });

  test('dispose drains attempts before closing the task stream', () async {
    final downloader = _AttemptGatedDownloader();
    final service = DownloadService(
      downloader: downloader.call,
      storage: _MemoryStorage(),
      taskIdFactory: () => 'dispose-id',
    );
    final events = <List<DownloadTask>>[];
    final subscription = service.tasksStream.listen(events.add);
    addTearDown(subscription.cancel);

    await service.addTask(_song('a'));
    var disposed = false;
    final disposal = service.dispose().then((_) => disposed = true);
    await Future<void>.delayed(Duration.zero);
    expect(disposed, isFalse);

    downloader.attempts.single.progress(80, 100);
    downloader.attempts.single.gate.complete();
    await disposal;
    final eventCount = events.length;
    downloader.attempts.single.progress(100, 100);
    await Future<void>.delayed(Duration.zero);
    expect(events, hasLength(eventCount));
  });

  test(
    'serializes persistence, throttles progress, and flushes terminal states',
    () async {
      final storage = _MemoryStorage();
      final downloader = _GatedDownloader();
      final service = DownloadService(
        downloader: downloader.call,
        storage: storage,
        taskIdFactory: () => 'persist-id',
        progressPersistenceInterval: const Duration(days: 1),
      );
      addTearDown(() async {
        downloader.completeAll();
        await service.dispose();
      });

      await service.addTask(_song('a'));
      await service.persistenceIdle;
      final beforeComplete = storage.writes;
      downloader.complete('persist-id');
      await service.idle;
      await service.persistenceIdle;
      expect(storage.writes, greaterThan(beforeComplete));
      expect(storage.saved.single['status'], DownloadStatus.completed.index);
    },
  );

  test(
    'restart demotes interrupted work without claiming it is resumable',
    () async {
      final storage = _MemoryStorage()
        ..saved = [
          DownloadTask(
            id: 'old',
            musicId: 'a',
            name: 'Song',
            singer: 'Singer',
            createdAt: DateTime(2026),
            status: DownloadStatus.downloading,
            progress: .7,
          ).toJson(),
        ];
      final root = await Directory.systemTemp.createTemp('downloads_');
      addTearDown(() => root.delete(recursive: true));
      final service = DownloadService(
        storage: storage,
        downloader: (_, __, ___) async {},
        wifiOnly: true,
        currentNetwork: () async => DownloadNetwork.mobile,
        downloadDirectory: () async => root,
      );
      addTearDown(service.dispose);

      await service.init();
      expect(service.tasks.single.status, DownloadStatus.pending);
      expect(service.tasks.single.progress, 0);
      expect(service.tasks.single.savePath, isNull);
    },
  );

  test('startup quarantines one bad record and loads valid siblings', () async {
    final valid = DownloadTask(
      id: 'valid',
      musicId: 'm1',
      name: 'Song',
      singer: 'Singer',
      createdAt: DateTime.utc(2026),
      status: DownloadStatus.paused,
    ).toJson();
    final storage = _MemoryStorage()
      ..saved = [
        valid,
        {'id': 7},
      ];
    final root = await Directory.systemTemp.createTemp('downloads_');
    addTearDown(() => root.delete(recursive: true));
    final service = DownloadService(
      storage: storage,
      downloader: (_, __, ___) async {},
      downloadDirectory: () async => root,
    );
    addTearDown(service.dispose);

    await service.init();

    expect(service.tasks.map((task) => task.id), ['valid']);
    expect(storage.quarantine, hasLength(1));
    expect(storage.saved, hasLength(1));
  });

  test(
    'outside-root completed path is quarantined and never deleted',
    () async {
      final root = await Directory.systemTemp.createTemp('downloads_');
      final outside = await Directory.systemTemp.createTemp('outside_');
      final victim = File('${outside.path}/victim.mp3')
        ..writeAsBytesSync([1, 2, 3]);
      final storage = _MemoryStorage()
        ..saved = [
          DownloadTask(
            id: 'escaped',
            musicId: 'm1',
            name: 'Song',
            singer: 'Singer',
            createdAt: DateTime.utc(2026),
            status: DownloadStatus.completed,
            savePath: victim.path,
            fileSize: 3,
          ).toJson(),
        ];
      final service = DownloadService(
        storage: storage,
        downloader: (_, __, ___) async {},
        downloadDirectory: () async => root,
      );
      addTearDown(() async {
        await service.dispose();
        await root.delete(recursive: true);
        await outside.delete(recursive: true);
      });

      await service.init();
      await service.clearCache();

      expect(service.tasks, isEmpty);
      expect(storage.quarantine, hasLength(1));
      expect(victim.existsSync(), isTrue);
    },
  );

  test(
    'startup recovers promoted file and removes strict orphan and part',
    () async {
      final root = await Directory.systemTemp.createTemp('downloads_');
      final recoverable = File('${root.path}/task-2.mp3')
        ..writeAsBytesSync(List<int>.filled(2048, 1));
      final orphan = File('${root.path}/orphan-1.flac')..writeAsBytesSync([1]);
      final part = File('${root.path}/task-2.part')..writeAsBytesSync([1]);
      final unrelated = File('${root.path}/notes.txt')
        ..writeAsStringSync('keep');
      final storage = _MemoryStorage()
        ..saved = [
          DownloadTask(
            id: 'task',
            musicId: 'm1',
            name: 'Song',
            singer: 'Singer',
            createdAt: DateTime.utc(2026),
            status: DownloadStatus.downloading,
            attemptRevision: 2,
          ).toJson(),
        ];
      final service = DownloadService(
        storage: storage,
        downloader: (_, __, ___) async {},
        downloadDirectory: () async => root,
      );
      addTearDown(() async {
        await service.dispose();
        await root.delete(recursive: true);
      });

      await service.init();

      expect(service.tasks.single.status, DownloadStatus.completed);
      expect(service.tasks.single.savePath, recoverable.path);
      expect(orphan.existsSync(), isFalse);
      expect(part.existsSync(), isFalse);
      expect(unrelated.existsSync(), isTrue);
    },
  );

  test(
    'startup quarantines multi-final candidates including empty and deletes all owned',
    () async {
      final root = await Directory.systemTemp.createTemp('downloads_');
      final nonEmpty = File('${root.path}/task-2.mp3')
        ..writeAsBytesSync(List<int>.filled(2048, 1));
      final empty = File('${root.path}/task-2.flac')
        ..writeAsBytesSync(const []);
      final unrelated = File('${root.path}/notes.txt')
        ..writeAsStringSync('keep');
      final storage = _MemoryStorage()
        ..saved = [
          DownloadTask(
            id: 'task',
            musicId: 'm1',
            name: 'Song',
            singer: 'Singer',
            createdAt: DateTime.utc(2026),
            status: DownloadStatus.downloading,
            attemptRevision: 2,
          ).toJson(),
        ];
      final service = DownloadService(
        storage: storage,
        downloader: (_, __, ___) async {},
        downloadDirectory: () async => root,
      );
      addTearDown(() async {
        await service.dispose();
        await root.delete(recursive: true);
      });

      await service.init();

      expect(service.tasks, isEmpty);
      expect(storage.quarantine, hasLength(1));
      expect(nonEmpty.existsSync(), isFalse);
      expect(empty.existsSync(), isFalse);
      expect(unrelated.existsSync(), isTrue);
    },
  );

  test(
    'startup quarantines multi empty finals and deletes all owned',
    () async {
      final root = await Directory.systemTemp.createTemp('downloads_');
      final emptyMp3 = File('${root.path}/task-2.mp3')
        ..writeAsBytesSync(const []);
      final emptyFlac = File('${root.path}/task-2.flac')
        ..writeAsBytesSync(const []);
      final unrelated = File('${root.path}/notes.txt')
        ..writeAsStringSync('keep');
      final storage = _MemoryStorage()
        ..saved = [
          DownloadTask(
            id: 'task',
            musicId: 'm1',
            name: 'Song',
            singer: 'Singer',
            createdAt: DateTime.utc(2026),
            status: DownloadStatus.downloading,
            attemptRevision: 2,
          ).toJson(),
        ];
      final service = DownloadService(
        storage: storage,
        downloader: (_, __, ___) async {},
        downloadDirectory: () async => root,
      );
      addTearDown(() async {
        await service.dispose();
        await root.delete(recursive: true);
      });

      await service.init();

      expect(service.tasks, isEmpty);
      expect(storage.quarantine, hasLength(1));
      expect(emptyMp3.existsSync(), isFalse);
      expect(emptyFlac.existsSync(), isFalse);
      expect(unrelated.existsSync(), isTrue);
    },
  );
}
