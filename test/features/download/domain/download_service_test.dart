import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/features/download/domain/download_service.dart';
import 'package:lx_music_flutter/features/download/domain/download_task.dart';
import 'package:lx_music_flutter/features/player/domain/music_item.dart';

class _MemoryStorage implements DownloadTaskStorage {
  List<Map<String, dynamic>> saved = [];
  int writes = 0;

  @override
  List<Map<String, dynamic>> load() => saved;

  @override
  Future<void> save(List<Map<String, dynamic>> tasks) async {
    writes++;
    saved = tasks;
  }
}

class _GatedDownloader {
  final started = <String>[];
  final _gates = <String, Completer<void>>{};

  int get active => _gates.values.where((gate) => !gate.isCompleted).length;

  Future<void> call(
      DownloadTask task, CancelToken _, void Function(double) progress) {
    started.add(task.id);
    progress(.5);
    return (_gates[task.id] ??= Completer<void>()).future;
  }

  void complete(String id) => _gates[id]!.complete();
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
    addTearDown(service.dispose);

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
    addTearDown(service.dispose);

    await service.addTasks([_song('a'), _song('a')]);
    expect(service.tasks.single.id, 'fixed-id');
    expect(downloader.started, ['fixed-id']);
  });

  test('wifi-only policy pauses on loss and restarts when Wi-Fi returns',
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
      await network.close();
      service.dispose();
    });

    await service.addTask(_song('a'));
    await Future<void>.delayed(Duration.zero);
    expect(downloader.started, ['wifi-id']);
    network.add(DownloadNetwork.mobile);
    await service.idle;
    expect(service.tasks.single.status, DownloadStatus.pending);
    network.add(DownloadNetwork.wifi);
    await service.idle;
    expect(downloader.started, hasLength(2));
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
    addTearDown(service.dispose);

    await service.addTask(_song('a'));
    await service.persistenceIdle;
    final beforeComplete = storage.writes;
    downloader.complete('persist-id');
    await service.idle;
    await service.persistenceIdle;
    expect(storage.writes, greaterThan(beforeComplete));
    expect(storage.saved.single['status'], DownloadStatus.completed.index);
  });

  test('restart demotes interrupted work without claiming it is resumable',
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
    final service = DownloadService(
      storage: storage,
      downloader: (_, __, ___) async {},
      wifiOnly: true,
      currentNetwork: () async => DownloadNetwork.mobile,
    );
    addTearDown(service.dispose);

    await service.init();
    expect(service.tasks.single.status, DownloadStatus.pending);
    expect(service.tasks.single.progress, 0);
    expect(service.tasks.single.savePath, isNull);
  });
}
