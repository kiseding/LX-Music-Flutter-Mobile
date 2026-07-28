import 'package:flutter/foundation.dart';
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
  final bool isLoading;
  final bool hasMore;
  final String? error;

  SearchState({
    this.items = const [],
    this.page = 1,
    this.isLoading = false,
    this.hasMore = true,
    this.error,
  });

  SearchState copyWith({
    List<MusicItem>? items,
    int? page,
    bool? isLoading,
    bool? hasMore,
    String? error,
  }) {
    return SearchState(
      items: items ?? this.items,
      page: page ?? this.page,
      isLoading: isLoading ?? this.isLoading,
      hasMore: hasMore ?? this.hasMore,
      error: error,
    );
  }
}

class SearchNotifier extends StateNotifier<SearchState> {
  final MusicSourceService _service;
  final Ref _ref;

  SearchNotifier(this._service, this._ref) : super(SearchState());

  Future<void> search(String query, {bool isLoadMore = false}) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    debugPrint(' [SearchFlow] [$timestamp] SearchNotifier.search START: query=$query, isLoadMore=$isLoadMore');
    
    if (query.isEmpty) {
      state = SearchState();
      return;
    }

    // 防止重复搜索
    if (state.isLoading && !isLoadMore) {
      debugPrint(' [SearchFlow] [$timestamp] SearchNotifier.search IGNORED: Already loading');
      return;
    }
    if (isLoadMore && (!state.hasMore || state.isLoading)) return;

    final currentPage = isLoadMore ? state.page + 1 : 1;
    final sourceId = _ref.read(selectedSourceIdProvider);

    state = state.copyWith(isLoading: true, error: null);

    final stopwatch = Stopwatch()..start();
    try {
      debugPrint(' [SearchFlow] [$timestamp] Calling Service.search: source=$sourceId, type=music');
      final results = await _service.search(
        query,
        customSourceId: sourceId,
        page: currentPage,
        type: 'music',
      );
      
      stopwatch.stop();
      debugPrint(' [SearchFlow] [$timestamp] Service.search SUCCESS: found ${results.length} items, duration=${stopwatch.elapsedMilliseconds}ms');

      state = state.copyWith(
        items: isLoadMore ? [...state.items, ...results] : results,
        page: currentPage,
        isLoading: false,
        hasMore: results.isNotEmpty && results.length >= 20,
      );
    } catch (e, stack) {
      stopwatch.stop();
      debugPrint(' [SearchFlow] [$timestamp] Service.search ERROR: $e, duration=${stopwatch.elapsedMilliseconds}ms');
      debugPrint(stack.toString());
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  void reset() {
    state = SearchState();
  }
}

final searchStateProvider = StateNotifierProvider<SearchNotifier, SearchState>((ref) {
  final service = ref.watch(musicSourceServiceProvider);
  return SearchNotifier(service, ref);
});

// 搜索历史记录（持久化）
final searchHistoryProvider = StateNotifierProvider<SearchHistoryNotifier, List<String>>((ref) {
  return SearchHistoryNotifier();
});

class SearchHistoryNotifier extends StateNotifier<List<String>> {
  SearchHistoryNotifier() : super([]) {
    _load();
  }

  Future<void> _load() async {
    final storage = await StorageService.instance;
    state = storage.getStringList('search_history');
  }

  Future<void> add(String keyword) async {
    if (keyword.trim().isEmpty) return;
    final updated = [keyword, ...state.where((s) => s != keyword)];
    if (updated.length > 20) updated.removeRange(20, updated.length);
    state = updated;
    final storage = await StorageService.instance;
    await storage.setStringList('search_history', updated);
  }

  Future<void> remove(String keyword) async {
    state = state.where((s) => s != keyword).toList();
    final storage = await StorageService.instance;
    await storage.setStringList('search_history', state);
  }

  Future<void> clear() async {
    state = [];
    final storage = await StorageService.instance;
    await storage.setStringList('search_history', []);
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
    final response = await dio.get('https://search.kuwo.cn/r.s', queryParameters: {
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
        return list.take(20).map((item) => (item as Map)['SONGNAME'] as String? ?? '').where((s) => s.isNotEmpty).toList();
      }
    }
  } catch (_) {}
  return _defaultHotSearch;
});

const _defaultHotSearch = ['周杰伦', '薛之谦', '陈奕迅', '林俊杰', '邓紫棋', '毛不易', '华晨宇', '李荣浩', '周深', '张杰'];
