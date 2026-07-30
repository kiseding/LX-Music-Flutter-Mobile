import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/music_source_service.dart';
import '../../../core/storage/storage_service.dart';
import '../../player/domain/music_item.dart';
import '../../custom_source/presentation/custom_source_provider.dart';

final musicSourceServiceProvider = Provider<MusicSourceService>((ref) {
  final customSourceService = ref.watch(customSourceServiceProvider);
  return MusicSourceService(customSourceService);
});

// 音源平台模型
class SearchSourceItem {
  final String id;
  final String name;

  SearchSourceItem({required this.id, required this.name});
}

// 桌面版固定的搜索平台列表
final allSearchSourcesProvider = Provider<List<SearchSourceItem>>((ref) {
  return [
    SearchSourceItem(id: 'all', name: '全网'),
    SearchSourceItem(id: 'tx', name: 'QQ'),
    SearchSourceItem(id: 'kw', name: '酷我'),
    SearchSourceItem(id: 'wy', name: '网易'),
  ];
});

final searchQueryProvider = StateProvider<String>((ref) => '');
// 默认腾讯；设置页可改 defaultSearchPlatform 并同步到此
final selectedSourceIdProvider = StateProvider<String>((ref) => 'tx');

// 搜索状态类
class SearchState {
  final List<MusicItem> items;
  final int page;
  final int generation;
  final bool isLoading;
  final bool hasMore;
  final String? error;
  final String query;
  final String sourceId;

  SearchState({
    this.items = const [],
    this.page = 1,
    this.generation = 0,
    this.isLoading = false,
    this.hasMore = true,
    this.error,
    this.query = '',
    this.sourceId = '',
  });

  SearchState copyWith({
    List<MusicItem>? items,
    int? page,
    int? generation,
    bool? isLoading,
    bool? hasMore,
    String? error,
    String? query,
    String? sourceId,
  }) {
    return SearchState(
      items: items ?? this.items,
      page: page ?? this.page,
      generation: generation ?? this.generation,
      isLoading: isLoading ?? this.isLoading,
      hasMore: hasMore ?? this.hasMore,
      error: error,
      query: query ?? this.query,
      sourceId: sourceId ?? this.sourceId,
    );
  }
}

typedef SearchLoader = Future<List<MusicItem>> Function(
  String query,
  String sourceId,
  int page,
);

class SearchNotifier extends StateNotifier<SearchState> {
  SearchNotifier(this._load, this._readSelectedSource) : super(SearchState());

  final SearchLoader _load;
  final String Function() _readSelectedSource;
  int _generation = 0;

  Future<void> search(String rawQuery) async {
    final query = rawQuery.trim();
    final generation = ++_generation;
    if (query.isEmpty) {
      state = SearchState(generation: generation);
      return;
    }
    final sourceId = _readSelectedSource();
    state = SearchState(
      generation: generation,
      isLoading: true,
      query: query,
      sourceId: sourceId,
    );
    await _loadPage(
      generation: generation,
      query: query,
      sourceId: sourceId,
      page: 1,
      append: false,
    );
  }

  Future<void> loadMore() async {
    if (state.isLoading || !state.hasMore || state.query.isEmpty) return;
    final generation = state.generation;
    final query = state.query;
    final sourceId = state.sourceId;
    final page = state.page + 1;
    state = state.copyWith(isLoading: true, error: null);
    await _loadPage(
      generation: generation,
      query: query,
      sourceId: sourceId,
      page: page,
      append: true,
    );
  }

  Future<void> _loadPage({
    required int generation,
    required String query,
    required String sourceId,
    required int page,
    required bool append,
  }) async {
    try {
      final results = await _load(query, sourceId, page);
      if (!_owns(generation, query, sourceId)) return;
      state = state.copyWith(
        items: append ? [...state.items, ...results] : results,
        page: page,
        isLoading: false,
        hasMore: results.length >= 20,
        error: null,
      );
    } catch (error) {
      if (!_owns(generation, query, sourceId)) return;
      state = state.copyWith(isLoading: false, error: error.toString());
    }
  }

  bool _owns(int generation, String query, String sourceId) =>
      mounted &&
      generation == _generation &&
      state.generation == generation &&
      state.query == query &&
      state.sourceId == sourceId;

  void reset() {
    final generation = ++_generation;
    state = SearchState(generation: generation);
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }
}

final searchStateProvider =
    StateNotifierProvider<SearchNotifier, SearchState>((ref) {
  final service = ref.watch(musicSourceServiceProvider);
  return SearchNotifier(
    (query, sourceId, page) => service.search(
      query,
      customSourceId: sourceId,
      page: page,
      type: 'music',
    ),
    () => ref.read(selectedSourceIdProvider),
  );
});

// 搜索历史记录（持久化）
final searchHistoryProvider =
    StateNotifierProvider<SearchHistoryNotifier, List<String>>((ref) {
  return SearchHistoryNotifier();
});

class SearchHistoryNotifier extends StateNotifier<List<String>> {
  SearchHistoryNotifier({StorageLoader? storage})
      : _storage = storage ?? (() => StorageService.instance),
        super([]) {
    _load();
  }

  final StorageLoader _storage;
  int _generation = 0;

  Future<void> _load() async {
    final generation = _generation;
    try {
      final storage = await _storage();
      final value = storage.getStringList('search_history');
      if (generation == _generation) state = value;
    } catch (_) {}
  }

  Future<void> add(String keyword) async {
    if (keyword.trim().isEmpty) return;
    ++_generation;
    final previous = state;
    final updated = [keyword, ...state.where((s) => s != keyword)];
    if (updated.length > 20) updated.removeRange(20, updated.length);
    state = updated;
    try {
      await (await _storage()).setStringList('search_history', updated);
    } catch (_) {
      if (identical(state, updated) || state == updated) state = previous;
      rethrow;
    }
  }

  Future<void> remove(String keyword) async {
    ++_generation;
    final previous = state;
    final updated = state.where((s) => s != keyword).toList();
    state = updated;
    try {
      await (await _storage()).setStringList('search_history', updated);
    } catch (_) {
      if (identical(state, updated) || state == updated) state = previous;
      rethrow;
    }
  }

  Future<void> clear() async {
    ++_generation;
    final previous = state;
    const updated = <String>[];
    state = updated;
    try {
      await (await _storage()).setStringList('search_history', updated);
    } catch (_) {
      if (state.isEmpty) state = previous;
      rethrow;
    }
  }

  Future<void> replaceAll(List<String> values) async {
    final normalized = <String>[];
    for (final value in values) {
      final keyword = value.trim();
      if (keyword.isEmpty || normalized.contains(keyword)) continue;
      normalized.add(keyword);
      if (normalized.length == 20) break;
    }
    ++_generation;
    final previous = state;
    state = normalized;
    try {
      await (await _storage()).setStringList('search_history', normalized);
    } catch (_) {
      if (identical(state, normalized) || state == normalized) state = previous;
      rethrow;
    }
  }

  void applyCommitted(List<String> value) {
    ++_generation;
    state = value;
  }
}

// 热搜词（从酷我获取）
final hotSearchProvider = FutureProvider<List<String>>((ref) async {
  final musicSourceService = ref.watch(musicSourceServiceProvider);
  final builtIn = musicSourceService.builtInSources;
  final kwSource = builtIn.get('kw');
  if (kwSource == null) return _defaultHotSearch;
  try {
    final dio = kwSource.createDioForService();
    final response =
        await dio.get('https://search.kuwo.cn/r.s', queryParameters: {
      'client': 'kt',
      'rn': '20',
      'pn': '0',
      'type': 'bang',
      'data': 'content',
      'show_copyright_off': '0',
      'isbang': '1',
      'bangid': '93',
    });
    final data = response.data;
    if (data is Map) {
      final list = data['musiclist'] as List?;
      if (list != null) {
        return list
            .take(20)
            .map((item) => (item as Map)['SONGNAME'] as String? ?? '')
            .where((s) => s.isNotEmpty)
            .toList();
      }
    }
  } catch (_) {}
  return _defaultHotSearch;
});

const _defaultHotSearch = [
  '周杰伦',
  '薛之谦',
  '陈奕迅',
  '林俊杰',
  '邓紫棋',
  '毛不易',
  '华晨宇',
  '李荣浩',
  '周深',
  '张杰'
];
