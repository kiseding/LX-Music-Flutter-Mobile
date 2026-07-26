import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_colors.dart';
import '../../player/presentation/player_provider.dart';
import '../../playlist/presentation/playlist_provider.dart';
import '../../playlist/presentation/playlist_picker.dart';
import '../../download/presentation/download_provider.dart';
import 'search_provider.dart';
import 'song_list_detail_screen.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    // 只在「是否有文字」变化时 setState（清除按钮显隐）。
    // 禁止在 selection/composing 变化时重建：首次聚焦会改 selection，
    // 整页 rebuild 会导致 iOS 输入法秒关。
    var hadText = _searchController.text.isNotEmpty;
    _searchController.addListener(() {
      final nowHas = _searchController.text.isNotEmpty;
      if (nowHas != hadText && mounted) {
        hadText = nowHas;
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 100) {
      _loadMore();
    }
  }

  void _loadMore() {
    final searchState = ref.read(searchStateProvider);
    if (searchState.isLoading || !searchState.hasMore) return;
    final query = _searchController.text;
    if (query.isNotEmpty) {
      ref.read(searchStateProvider.notifier).search(query, isLoadMore: true);
    }
  }

  void _onSearch(String query) {
    if (query.trim().isNotEmpty) {
      ref.read(searchQueryProvider.notifier).state = query.trim();
      ref.read(searchStateProvider.notifier).search(query.trim());
      ref.read(searchHistoryProvider.notifier).add(query.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    final searchState = ref.watch(searchStateProvider);
    final selectedSourceId = ref.watch(selectedSourceIdProvider);
    final allSources = ref.watch(allSearchSourcesProvider);
    final searchHistory = ref.watch(searchHistoryProvider);
    final accent = AppColors.accentOf(context);
    final primary = AppColors.onScaffold(context);
    final muted = AppColors.mutedText(context);
    final border = AppColors.cardBorder(context);

    final sourcesForDropdown = allSources.where((s) => s.id != 'all').toList();
    final list = sourcesForDropdown.isNotEmpty ? sourcesForDropdown : allSources;
    final current = list.cast<SearchSourceItem?>().firstWhere(
          (s) => s?.id == selectedSourceId,
          orElse: () => list.isNotEmpty ? list.first : null,
        );

    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        // 禁止随键盘改 body 高度，避免首焦布局抖动导致输入法秒关。
        resizeToAvoidBottomInset: false,
        // 底部安全区已由 MainScaffold（底栏+迷你栏）处理，避免双重留白
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              // 搜索框：与迷你栏同色底，一眼能看出输入范围
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: Container(
                  height: 44,
                  decoration: BoxDecoration(
                    color: AppColors.miniBar(context),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: border.withValues(alpha: 0.6)),
                  ),
                  child: Row(
                    children: [
                      PopupMenuButton<String>(
                        tooltip: '选择平台',
                        offset: const Offset(0, 40),
                        popUpAnimationStyle: AnimationStyle.noAnimation,
                        color: AppColors.dialogBg(context),
                        onSelected: (id) {
                          ref.read(selectedSourceIdProvider.notifier).state = id;
                          if (_searchController.text.isNotEmpty) {
                            _onSearch(_searchController.text);
                          }
                        },
                        itemBuilder: (ctx) => [
                          for (final s in list)
                            PopupMenuItem(
                              value: s.id,
                              child: Row(
                                children: [
                                  Text(
                                    s.name,
                                    style: TextStyle(
                                      color: primary,
                                      fontWeight: s.id == selectedSourceId
                                          ? FontWeight.w700
                                          : FontWeight.w500,
                                    ),
                                  ),
                                  if (s.id == selectedSourceId) ...[
                                    const Spacer(),
                                    Icon(Icons.check, color: accent, size: 18),
                                  ],
                                ],
                              ),
                            ),
                        ],
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                current?.name ?? '平台',
                                style: TextStyle(
                                  color: primary,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Icon(Icons.arrow_drop_down, color: muted, size: 20),
                            ],
                          ),
                        ),
                      ),
                      Container(width: 1, height: 20, color: border),
                      Expanded(
                        child: TextField(
                          controller: _searchController,
                          focusNode: _searchFocus,
                          style: TextStyle(color: primary, fontSize: 15, height: 1.2),
                          decoration: InputDecoration(
                            hintText: '搜索歌曲、歌单...',
                            hintStyle: TextStyle(color: muted, fontSize: 15),
                            border: InputBorder.none,
                            isDense: true,
                            filled: false,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                          ),
                          textInputAction: TextInputAction.search,
                          onSubmitted: _onSearch,
                        ),
                      ),
                      if (_searchController.text.isNotEmpty)
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: Icon(Icons.clear, size: 18, color: muted),
                          onPressed: () {
                            _searchController.clear();
                            ref.read(searchQueryProvider.notifier).state = '';
                            ref.read(searchStateProvider.notifier).reset();
                            setState(() {});
                          },
                        ),
                      TextButton(
                        onPressed: () => _onSearch(_searchController.text),
                        style: TextButton.styleFrom(
                          foregroundColor: accent,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          minimumSize: const Size(0, 36),
                        ),
                        child: const Text('搜索', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(child: _buildMainContent(searchState, searchHistory)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMainContent(SearchState searchState, List<String> searchHistory) {
    if (searchState.items.isEmpty && _searchController.text.isEmpty && !searchState.isLoading) {
      return _buildHistory(searchHistory);
    }
    if (searchState.isLoading && searchState.items.isEmpty) {
      return Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(AppColors.accentOf(context)),
          ),
        ),
      );
    }
    if (searchState.error != null && searchState.items.isEmpty) {
      return Center(child: Text('搜索出错: ${searchState.error}', style: const TextStyle(color: AppColors.error)));
    }
    return _buildResultList(searchState);
  }

  Widget _buildResultList(SearchState searchState) {
    final results = searchState.items;
    if (results.isEmpty && !searchState.isLoading) {
      return Center(child: Text('无结果', style: TextStyle(color: AppColors.mutedText(context))));
    }
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(16),
      itemCount: results.length + (searchState.hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == results.length) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: searchState.isLoading
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(AppColors.accentOf(context)),
                      ),
                    )
                  : Text('滑动加载更多', style: TextStyle(color: AppColors.mutedText(context), fontSize: 12)),
            ),
          );
        }
        final item = results[index];
        final isSonglist = !item.isPlayable;
        return ListTile(
          contentPadding: EdgeInsets.zero,
          onTap: () {
            if (isSonglist) {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => SongListDetailScreen(songList: item),
                ),
              );
            } else {
              final playable = results.where((e) => e.isPlayable).toList();
              final pIndex = playable.indexWhere((e) => e.id == item.id);
              ref.read(playerServiceProvider).setQueue(playable, startIndex: pIndex >= 0 ? pIndex : 0);
            }
          },
          onLongPress: isSonglist
              ? null
              : () => _showSongMenu(item, results.where((e) => e.isPlayable).toList()),
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 48,
              height: 48,
              child: item.artwork != null && item.artwork!.isNotEmpty
                  ? Image.network(item.artwork!, fit: BoxFit.cover, errorBuilder: (_, __, ___) => _placeholder())
                  : _placeholder(),
            ),
          ),
          title: Text(
            item.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: AppColors.onScaffold(context), fontSize: 14, fontWeight: FontWeight.w500),
          ),
          subtitle: Text(
            isSonglist ? item.singer : '${item.singer}${item.album.isNotEmpty ? ' · ${item.album}' : ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: AppColors.mutedText(context), fontSize: 12),
          ),
          trailing: isSonglist
              ? Icon(Icons.chevron_right, color: AppColors.mutedText(context))
              : IconButton(
                  icon: Icon(Icons.more_vert, color: AppColors.mutedText(context), size: 20),
                  onPressed: () => _showSongMenu(item, results.where((e) => e.isPlayable).toList()),
                ),
        );
      },
    );
  }

  Widget _placeholder() => Container(
        color: AppColors.fill2(context),
        child: Icon(Icons.music_note, color: AppColors.mutedText(context)),
      );

  Widget _buildHistory(List<String> searchHistory) {
    final hotAsync = ref.watch(hotSearchProvider);
    final primary = AppColors.onScaffold(context);
    final secondary = AppColors.secondaryText(context);
    final muted = AppColors.mutedText(context);
    final accent = AppColors.accentOf(context);

    return ListView(
      // 底部已由 MainScaffold 预留，勿再垫 100 造成空白层
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      children: [
        if (searchHistory.isNotEmpty) ...[
          Row(
            children: [
              Text('搜索历史', style: TextStyle(color: secondary, fontWeight: FontWeight.w600, fontSize: 14)),
              const Spacer(),
              TextButton(
                onPressed: () => ref.read(searchHistoryProvider.notifier).clear(),
                child: Text('清空', style: TextStyle(color: accent, fontSize: 12)),
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: searchHistory.map((h) {
              return ActionChip(
                label: Text(h, style: TextStyle(color: primary, fontSize: 13)),
                backgroundColor: AppColors.fill(context),
                side: BorderSide(color: AppColors.cardBorder(context)),
                onPressed: () {
                  _searchController.text = h;
                  _onSearch(h);
                },
              );
            }).toList(),
          ),
          const SizedBox(height: 20),
        ],
        Text('热搜榜', style: TextStyle(color: secondary, fontWeight: FontWeight.w600, fontSize: 14)),
        const SizedBox(height: 8),
        hotAsync.when(
          loading: () => Padding(
            padding: const EdgeInsets.all(16),
            child: Text('加载中...', style: TextStyle(color: muted, fontSize: 13)),
          ),
          error: (_, __) => const SizedBox.shrink(),
          data: (hots) => Column(
            children: [
              for (var i = 0; i < hots.length; i++)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: SizedBox(
                    width: 28,
                    child: Text(
                      '${i + 1}',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        // 数字跟随主题：前三强调色，其余主文字
                        color: i < 3 ? accent : primary.withValues(alpha: i < 10 ? 0.78 : 0.55),
                        fontSize: 15,
                        fontWeight: i < 3 ? FontWeight.w800 : FontWeight.w600,
                      ),
                    ),
                  ),
                  title: Text(hots[i], style: TextStyle(color: primary, fontSize: 14)),
                  onTap: () {
                    _searchController.text = hots[i];
                    _onSearch(hots[i]);
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }

  void _showSongMenu(dynamic item, List playableItems) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.dialogBg(context),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.play_arrow, color: AppColors.onScaffold(context)),
              title: Text('立即播放', style: TextStyle(color: AppColors.onScaffold(context))),
              onTap: () {
                Navigator.pop(ctx);
                final pIndex = playableItems.indexWhere((e) => e.id == item.id);
                ref.read(playerServiceProvider).setQueue(playableItems.cast(), startIndex: pIndex >= 0 ? pIndex : 0);
              },
            ),
            ListTile(
              leading: Icon(Icons.playlist_add, color: AppColors.onScaffold(context)),
              title: Text('添加到歌单', style: TextStyle(color: AppColors.onScaffold(context))),
              onTap: () {
                Navigator.pop(ctx);
                showPlaylistPicker(context: context, ref: ref, song: item);
              },
            ),
            ListTile(
              leading: Icon(Icons.favorite_border, color: AppColors.onScaffold(context)),
              title: Text('收藏', style: TextStyle(color: AppColors.onScaffold(context))),
              onTap: () {
                Navigator.pop(ctx);
                ref.read(toggleFavoriteProvider)(item);
              },
            ),
            ListTile(
              leading: Icon(Icons.download, color: AppColors.onScaffold(context)),
              title: Text('下载', style: TextStyle(color: AppColors.onScaffold(context))),
              onTap: () {
                Navigator.pop(ctx);
                ref.read(downloadSongProvider)(item);
              },
            ),
          ],
        ),
      ),
    );
  }
}
