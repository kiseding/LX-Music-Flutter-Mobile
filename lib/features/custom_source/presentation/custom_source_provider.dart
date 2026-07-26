import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/custom_source.dart';
import '../domain/custom_source_service.dart';

final customSourceServiceProvider = Provider<CustomSourceService>((ref) {
  final service = CustomSourceService();
  // 在应用启动时初始化一次
  service.init();
  return service;
});

final customSourcesProvider = StateNotifierProvider<CustomSourcesNotifier, List<CustomSource>>((ref) {
  final service = ref.watch(customSourceServiceProvider);
  return CustomSourcesNotifier(service);
});

class CustomSourcesNotifier extends StateNotifier<List<CustomSource>> {
  final CustomSourceService _service;

  CustomSourcesNotifier(this._service) : super([]) {
    _loadSources();
  }

  Future<void> _loadSources() async {
    await _service.init();
    state = _service.sources;
  }

  Future<void> addSource(CustomSource source) async {
    await _service.addSource(source);
    state = _service.sources;
  }

  Future<void> updateSource(CustomSource source) async {
    await _service.updateSource(source);
    state = _service.sources;
  }

  Future<void> deleteSource(String id) async {
    await _service.deleteSource(id);
    state = _service.sources;
  }

  Future<void> toggleSource(String id) async {
    await _service.toggleSource(id);
    state = _service.sources;
  }

  Future<bool> importSource(String jsonStr) async {
    final result = await _service.importSource(jsonStr);
    state = _service.sources;
    return result;
  }

  Future<bool> importLxMusicScript(String script) async {
    final result = await _service.importLxMusicScript(script);
    state = _service.sources;
    return result;
  }

  Future<bool> importSourceFromUrl(String url) async {
    final result = await _service.importSourceFromUrl(url);
    state = _service.sources;
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
