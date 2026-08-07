import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/custom_source.dart';
import '../domain/custom_source_service.dart';

final customSourceServiceProvider = Provider<CustomSourceService>((ref) {
  final service = CustomSourceService();
  // 在应用启动时初始化一次
  service.init();
  ref.onDispose(service.dispose);
  return service;
});

final customSourcesProvider =
    StateNotifierProvider<CustomSourcesNotifier, List<CustomSource>>((ref) {
  final service = ref.watch(customSourceServiceProvider);
  return CustomSourcesNotifier(service);
});

class CustomSourcesNotifier extends StateNotifier<List<CustomSource>> {
  final CustomSourceService _service;
  int _generation = 0;

  CustomSourcesNotifier(this._service) : super([]) {
    _loadSources();
  }

  Future<void> _loadSources() async {
    final generation = ++_generation;
    await _service.init();
    if (generation != _generation) return;
    state = _service.sources;
  }

  Future<void> addSource(CustomSource source) async {
    final generation = ++_generation;
    await _service.addSource(source);
    if (generation != _generation) return;
    state = _service.sources;
  }

  Future<void> updateSource(CustomSource source) async {
    final generation = ++_generation;
    await _service.updateSource(source);
    if (generation != _generation) return;
    state = _service.sources;
  }

  Future<void> deleteSource(String id) async {
    final generation = ++_generation;
    await _service.deleteSource(id);
    if (generation != _generation) return;
    state = _service.sources;
  }

  Future<bool> toggleSource(String id) async {
    final generation = ++_generation;
    final result = await _service.toggleSource(id);
    if (generation != _generation) return false;
    state = _service.sources;
    return result;
  }

  Future<bool> importSource(String jsonStr) async {
    final generation = ++_generation;
    final result = await _service.importSource(jsonStr);
    if (generation == _generation) state = _service.sources;
    return result;
  }

  Future<bool> importLxMusicScript(String script) async {
    final generation = ++_generation;
    final result = await _service.importLxMusicScript(script);
    if (generation == _generation) state = _service.sources;
    return result;
  }

  Future<bool> importSourceFromUrl(String url) async {
    final generation = ++_generation;
    final result = await _service.importSourceFromUrl(url);
    if (generation == _generation) state = _service.sources;
    return result;
  }

  String exportSource(String id) {
    return _service.exportSource(id);
  }

  String exportAllSources() {
    return _service.exportAllSources();
  }

  Stream<Map<String, dynamic>> getEventStream(String sourceId) {
    return _service.getEventStream(sourceId);
  }
}

final importCustomSourceFromUrlProvider =
    Provider<Future<bool> Function(String)>((ref) {
  return ref.read(customSourcesProvider.notifier).importSourceFromUrl;
});

final customSourceEventStreamProvider =
    Provider.family<Stream<Map<String, dynamic>>, String>((ref, sourceId) {
  return ref.read(customSourcesProvider.notifier).getEventStream(sourceId);
});
