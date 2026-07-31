import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/pagination/page_range.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/artwork_image.dart';
import '../../../core/widgets/page_navigation_bar.dart';
import '../domain/playlist.dart';
import 'playlist_occurrence.dart';
import 'playlist_provider.dart';
import '../../player/domain/music_item.dart';
import '../../player/presentation/player_provider.dart';

class PlaylistDetailScreen extends ConsumerStatefulWidget {
  const PlaylistDetailScreen({
    super.key,
    required this.playlistId,
    this.focusSongId,
  });

  final String playlistId;
  final String? focusSongId;

  @override
  ConsumerState<PlaylistDetailScreen> createState() =>
      _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends ConsumerState<PlaylistDetailScreen> {
  bool _isEditing = false;
  final List<PlaylistSongOccurrence> _reorderedSongs = [];
  String? _reorderedPlaylistId;
  final ScrollController _scrollController = ScrollController();
  String? _lastFocusedId;
  String? _loadingFocusedId;
  int _pageIndex = 0;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Playlist? _resolvePlaylist() {
    ref.watch(playlistRevisionProvider);
    return ref.watch(playlistServiceProvider).getPlaylist(widget.playlistId);
  }

  void _syncReorderedSongs(Playlist playlist, {bool force = false}) {
    if (!force &&
        _isEditing &&
        _reorderedPlaylistId == playlist.id &&
        _reorderedSongs.isNotEmpty) {
      return;
    }
    _reorderedPlaylistId = playlist.id;
    _reorderedSongs
      ..clear()
      ..addAll(buildPlaylistOccurrences(playlist.id, playlist.songs));
  }

  void _tryScrollToFocus(Playlist playlist) {
    final focusId = widget.focusSongId;
    if (focusId == null || focusId == _lastFocusedId) return;
    final idx = playlist.songs.indexWhere((s) => s.id == focusId);
    if (idx < 0) {
      if (playlist.songCount > 0 && _loadingFocusedId != focusId) {
        _loadingFocusedId = focusId;
        _loadFocusPage(playlist, focusId);
      }
      return;
    }
    _lastFocusedId = focusId;
    _pageIndex = PageRange.pageForItem(index: idx);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final offset = ((idx % PageRange.defaultPageSize) * 72.0).clamp(
        0.0,
        _scrollController.position.maxScrollExtent,
      );
      _scrollController.animateTo(
        offset,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    });
  }

  Future<void> _loadFocusPage(Playlist playlist, String focusId) async {
    try {
      final songs = await ref
          .read(playlistServiceProvider)
          .getAllSongs(playlist.id);
      final index = songs.indexWhere((song) => song.id == focusId);
      if (!mounted || index < 0) return;
      setState(() => _pageIndex = PageRange.pageForItem(index: index));
      _lastFocusedId = focusId;
    } finally {
      if (mounted) _loadingFocusedId = null;
    }
  }

  PageRange _pageRangeFor(int itemCount) {
    return PageRange(itemCount: itemCount, pageIndex: _pageIndex);
  }

  void _setPage(int pageIndex, int itemCount) {
    setState(() {
      _pageIndex = PageRange(
        itemCount: itemCount,
        pageIndex: pageIndex,
      ).pageIndex;
    });
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
  }

  Widget _buildPageNavigation(PageRange range) {
    return PageNavigationBar(
      pageIndex: range.pageIndex,
      pageCount: range.pageCount,
      onPageChanged: (pageIndex) => _setPage(pageIndex, range.itemCount),
    );
  }

  @override
  Widget build(BuildContext context) {
    final playlist = _resolvePlaylist();
    final playerService = ref.watch(playerServiceProvider);
    final focusId = widget.focusSongId;

    if (playlist == null) {
      return Container(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            backgroundColor: Theme.of(context).scaffoldBackgroundColor,
            surfaceTintColor: Colors.transparent,
            title: Text(
              '歌单',
              style: TextStyle(color: AppColors.onScaffold(context)),
            ),
          ),
          body: Center(
            child: Text(
              '歌单不存在',
              style: TextStyle(color: AppColors.mutedText(context)),
            ),
          ),
        ),
      );
    }

    if (_reorderedPlaylistId != playlist.id) {
      _syncReorderedSongs(playlist, force: true);
    }
    _tryScrollToFocus(playlist);
    final range = _pageRangeFor(playlist.songCount);
    final songsPage = !_isEditing && playlist.songCount > 0
        ? ref.watch(
            playlistSongsPageProvider(
              PlaylistSongsPageRequest(
                playlistId: playlist.id,
                pageIndex: range.pageIndex,
              ),
            ),
          )
        : null;

    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: 0,
          leading: IconButton(
            icon: Icon(
              _isEditing ? Icons.close : Icons.arrow_back,
              color: AppColors.onScaffold(context),
            ),
            onPressed: () {
              if (_isEditing) {
                setState(() {
                  _isEditing = false;
                  _syncReorderedSongs(playlist, force: true);
                });
              } else {
                Navigator.pop(context);
              }
            },
          ),
          title: Text(
            _isEditing ? '编辑歌单' : '${playlist.name}（${playlist.songCount}首）',
            style: TextStyle(
              color: AppColors.onScaffold(context),
              fontSize: 18,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            if (!_isEditing && playlist.songCount > 0)
              IconButton(
                tooltip: '播放全部',
                onPressed: () => _playSong(playerService, playlist, 0),
                icon: Icon(
                  Icons.play_circle_fill,
                  color: AppColors.accentOf(context),
                  size: 28,
                ),
              ),
            if (_isEditing)
              TextButton(
                onPressed: () async {
                  try {
                    await ref
                        .read(playlistServiceProvider)
                        .updatePlaylist(
                          id: playlist.id,
                          songs: _reorderedSongs
                              .map((entry) => entry.song)
                              .toList(),
                        );
                    if (mounted) setState(() => _isEditing = false);
                  } catch (error) {
                    _showMutationError('保存失败', error);
                  }
                },
                child: Text(
                  '保存',
                  style: TextStyle(color: AppColors.accentOf(context)),
                ),
              )
            else
              PopupMenuButton<String>(
                popUpAnimationStyle: AnimationStyle.noAnimation,
                icon: Icon(
                  Icons.more_vert,
                  color: AppColors.onScaffold(context),
                ),
                color: AppColors.dialogBg(context),
                onSelected: (value) async {
                  try {
                    switch (value) {
                      case 'play_all':
                        if (playlist.songCount > 0) {
                          await _playSong(playerService, playlist, 0);
                        }
                      case 'edit':
                        _showEditDialog(context, ref, playlist);
                      case 'sort_name':
                        await ref
                            .read(playlistServiceProvider)
                            .sortSongsByName(playlist.id);
                        if (!mounted) return;
                        setState(() {
                          final latest = ref
                              .read(playlistServiceProvider)
                              .getPlaylist(playlist.id);
                          if (latest != null) {
                            _syncReorderedSongs(latest, force: true);
                          }
                        });
                      case 'sort_artist':
                        await ref
                            .read(playlistServiceProvider)
                            .sortSongsByArtist(playlist.id);
                        if (!mounted) return;
                        setState(() {
                          final latest = ref
                              .read(playlistServiceProvider)
                              .getPlaylist(playlist.id);
                          if (latest != null) {
                            _syncReorderedSongs(latest, force: true);
                          }
                        });
                      case 'sort_duration':
                        await ref
                            .read(playlistServiceProvider)
                            .sortSongsByDuration(playlist.id);
                        if (!mounted) return;
                        setState(() {
                          final latest = ref
                              .read(playlistServiceProvider)
                              .getPlaylist(playlist.id);
                          if (latest != null) {
                            _syncReorderedSongs(latest, force: true);
                          }
                        });
                      case 'reorder':
                        final songs = await ref
                            .read(playlistServiceProvider)
                            .getAllSongs(playlist.id);
                        if (!mounted) return;
                        setState(() {
                          _isEditing = true;
                          _syncReorderedSongs(
                            playlist.copyWith(songs: songs),
                            force: true,
                          );
                        });
                      case 'delete':
                        _showDeleteDialog(context, ref, playlist);
                    }
                  } catch (error) {
                    _showMutationError('操作失败', error);
                  }
                },
                itemBuilder: (context) {
                  final on = AppColors.onScaffold(context);
                  return [
                    PopupMenuItem(
                      value: 'play_all',
                      child: Text('播放全部', style: TextStyle(color: on)),
                    ),
                    if (playlist.id != 'recent')
                      PopupMenuItem(
                        value: 'edit',
                        child: Text('编辑信息', style: TextStyle(color: on)),
                      ),
                    PopupMenuItem(
                      value: 'reorder',
                      child: Text('手动排序', style: TextStyle(color: on)),
                    ),
                    PopupMenuItem(
                      value: 'sort_name',
                      child: Text('按歌名排序', style: TextStyle(color: on)),
                    ),
                    PopupMenuItem(
                      value: 'sort_artist',
                      child: Text('按歌手排序', style: TextStyle(color: on)),
                    ),
                    PopupMenuItem(
                      value: 'sort_duration',
                      child: Text('按时长排序', style: TextStyle(color: on)),
                    ),
                    if (playlist.id != 'favorites' && playlist.id != 'recent')
                      PopupMenuItem(
                        value: 'delete',
                        child: Text('删除歌单', style: TextStyle(color: on)),
                      ),
                  ];
                },
              ),
          ],
        ),
        body: playlist.songCount == 0
            ? Center(
                child: Text(
                  '暂无歌曲',
                  style: TextStyle(color: AppColors.mutedText(context)),
                ),
              )
            : _isEditing
            ? _buildEditableList(playlist)
            : songsPage!.when(
                data: (page) => _buildNormalList(
                  playerService,
                  playlist,
                  page.songs,
                  range,
                  focusId,
                ),
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, _) => Center(child: Text('加载歌曲失败: $error')),
              ),
      ),
    );
  }

  Widget _buildEditableList(Playlist playlist) {
    final range = _pageRangeFor(_reorderedSongs.length);
    final songs = pageSlice(_reorderedSongs, range);
    return Column(
      children: [
        Expanded(
          child: ReorderableListView.builder(
            itemCount: songs.length,
            onReorder: (oldIndex, newIndex) {
              setState(() {
                if (newIndex > oldIndex) newIndex -= 1;
                final item = _reorderedSongs.removeAt(range.start + oldIndex);
                _reorderedSongs.insert(range.start + newIndex, item);
              });
            },
            itemBuilder: (context, index) {
              final entry = songs[index];
              final song = entry.song;
              return ListTile(
                key: ValueKey(entry.key),
                leading: Icon(
                  Icons.drag_handle,
                  color: AppColors.mutedText(context),
                ),
                title: Text(
                  song.name,
                  style: TextStyle(color: AppColors.onScaffold(context)),
                ),
                subtitle: Text(
                  song.singer,
                  style: TextStyle(
                    color: AppColors.mutedText(context),
                    fontSize: 12,
                  ),
                ),
              );
            },
          ),
        ),
        _buildPageNavigation(range),
      ],
    );
  }

  Widget _buildNormalList(
    dynamic playerService,
    Playlist playlist,
    List<MusicItem> songs,
    PageRange range,
    String? focusId,
  ) {
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
            itemCount: songs.length,
            itemBuilder: (context, index) {
              final song = songs[index];
              final songIndex = range.start + index;
              final focused = focusId != null && song.id == focusId;
              return Container(
                color: focused
                    ? AppColors.accentOf(context).withAlpha(28)
                    : null,
                child: ListTile(
                  onTap: () => _playSong(playerService, playlist, songIndex),
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: song.artwork != null && song.artwork!.isNotEmpty
                          ? ArtworkImage(
                              song.artwork!,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Icon(
                                Icons.music_note,
                                color: AppColors.mutedText(context),
                              ),
                            )
                          : Icon(
                              Icons.music_note,
                              color: AppColors.mutedText(context),
                            ),
                    ),
                  ),
                  title: Text(
                    song.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.onScaffold(context),
                      fontWeight: focused ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                  subtitle: Text(
                    song.singer,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.mutedText(context),
                      fontSize: 12,
                    ),
                  ),
                  trailing: IconButton(
                    icon: Icon(
                      Icons.more_vert,
                      color: AppColors.mutedText(context),
                      size: 20,
                    ),
                    onPressed: () {
                      showModalBottomSheet(
                        context: context,
                        backgroundColor: AppColors.dialogBg(context),
                        builder: (ctx) => SafeArea(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ListTile(
                                leading: const Icon(Icons.play_arrow),
                                title: const Text('播放'),
                                onTap: () {
                                  Navigator.pop(ctx);
                                  _playSong(playerService, playlist, songIndex);
                                },
                              ),
                              ListTile(
                                leading: const Icon(Icons.delete_outline),
                                title: const Text('从歌单移除'),
                                onTap: () async {
                                  try {
                                    await ref
                                        .read(playlistServiceProvider)
                                        .removeSongFromPlaylist(
                                          playlist.id,
                                          song.id,
                                        );
                                  } catch (error) {
                                    if (mounted) {
                                      _showMutationError('移除失败', error);
                                    }
                                    return;
                                  }
                                  if (!ctx.mounted) return;
                                  Navigator.pop(ctx);
                                },
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              );
            },
          ),
        ),
        _buildPageNavigation(range),
      ],
    );
  }

  Future<void> _playSong(
    dynamic playerService,
    Playlist playlist,
    int index,
  ) async {
    try {
      if (playlist.songCount <= 0) return;
      await playerService.playPagedPlaylist(
        songCount: playlist.songCount,
        startIndex: index,
        loadPage: (offset, limit) async {
          final page = await ref
              .read(playlistServiceProvider)
              .getSongsPage(playlist.id, offset: offset, limit: limit);
          return page.songs;
        },
      );
    } catch (error) {
      _showMutationError('加载歌曲失败', error);
    }
  }

  void _showEditDialog(BuildContext context, WidgetRef ref, Playlist playlist) {
    final nameController = TextEditingController(text: playlist.name);
    final descController = TextEditingController(
      text: playlist.description ?? '',
    );
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.dialogBg(context),
        title: Text(
          '编辑歌单',
          style: TextStyle(color: AppColors.onScaffold(context)),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              style: TextStyle(color: AppColors.onScaffold(context)),
              decoration: InputDecoration(
                hintText: '歌单名称',
                hintStyle: TextStyle(color: AppColors.mutedText(context)),
              ),
            ),
            TextField(
              controller: descController,
              style: TextStyle(color: AppColors.onScaffold(context)),
              decoration: InputDecoration(
                hintText: '描述',
                hintStyle: TextStyle(color: AppColors.mutedText(context)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              '取消',
              style: TextStyle(color: AppColors.mutedText(context)),
            ),
          ),
          TextButton(
            onPressed: () async {
              try {
                await ref
                    .read(playlistServiceProvider)
                    .updatePlaylist(
                      id: playlist.id,
                      name: nameController.text,
                      description: descController.text,
                    );
              } catch (error) {
                if (mounted) _showMutationError('保存失败', error);
                return;
              }
              if (!ctx.mounted) return;
              Navigator.pop(ctx);
            },
            child: Text(
              '保存',
              style: TextStyle(color: AppColors.accentOf(context)),
            ),
          ),
        ],
      ),
    );
  }

  void _showDeleteDialog(
    BuildContext context,
    WidgetRef ref,
    Playlist playlist,
  ) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.dialogBg(context),
        title: Text(
          '删除歌单',
          style: TextStyle(color: AppColors.onScaffold(context)),
        ),
        content: Text(
          '确定删除「${playlist.name}」？',
          style: TextStyle(color: AppColors.secondaryText(context)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              '取消',
              style: TextStyle(color: AppColors.mutedText(context)),
            ),
          ),
          TextButton(
            onPressed: () async {
              try {
                await ref
                    .read(playlistServiceProvider)
                    .deletePlaylist(playlist.id);
              } catch (error) {
                if (mounted) _showMutationError('删除失败', error);
                return;
              }
              if (!ctx.mounted || !context.mounted) return;
              Navigator.pop(ctx);
              Navigator.pop(context);
            },
            child: const Text('删除', style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );
  }

  void _showMutationError(String action, Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$action: $error')));
  }
}
