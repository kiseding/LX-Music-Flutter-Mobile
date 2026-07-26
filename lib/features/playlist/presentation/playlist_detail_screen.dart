import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_colors.dart';
import '../domain/playlist.dart';
import '../../player/domain/music_item.dart';
import 'playlist_provider.dart';
import '../../player/presentation/player_provider.dart';

class PlaylistDetailScreen extends ConsumerStatefulWidget {
  const PlaylistDetailScreen({super.key});

  @override
  ConsumerState<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends ConsumerState<PlaylistDetailScreen> {
  bool _isEditing = false;
  final List<MusicItem> _reorderedSongs = [];
  final ScrollController _scrollController = ScrollController();
  String? _lastFocusedId;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Playlist? _resolvePlaylist() {
    final current = ref.watch(currentPlaylistProvider);
    if (current == null) return null;
    // 始终从 service 取最新，避免打开后列表为空/过期
    return ref.watch(playlistServiceProvider).getPlaylist(current.id) ?? current;
  }

  void _tryScrollToFocus(Playlist playlist) {
    final focusId = ref.read(playlistFocusSongIdProvider);
    if (focusId == null || focusId == _lastFocusedId) return;
    final idx = playlist.songs.indexWhere((s) => s.id == focusId);
    if (idx < 0) return;
    _lastFocusedId = focusId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final offset = (idx * 72.0).clamp(0.0, _scrollController.position.maxScrollExtent);
      _scrollController.animateTo(offset, duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(playlistVersionProvider);
    final playlist = _resolvePlaylist();
    final playerService = ref.watch(playerServiceProvider);
    final focusId = ref.watch(playlistFocusSongIdProvider);

    if (playlist == null) {
      return Container(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            backgroundColor: Theme.of(context).scaffoldBackgroundColor,
            surfaceTintColor: Colors.transparent,
            title: Text('歌单', style: TextStyle(color: AppColors.onScaffold(context))),
          ),
          body: Center(child: Text('歌单不存在', style: TextStyle(color: AppColors.mutedText(context)))),
        ),
      );
    }

    if (_reorderedSongs.isEmpty && playlist.songs.isNotEmpty) {
      _reorderedSongs
        ..clear()
        ..addAll(playlist.songs);
    }
    _tryScrollToFocus(playlist);

    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: 0,
          leading: IconButton(
            icon: Icon(_isEditing ? Icons.close : Icons.arrow_back, color: AppColors.onScaffold(context)),
            onPressed: () {
              if (_isEditing) {
                setState(() {
                  _isEditing = false;
                  _reorderedSongs
                    ..clear()
                    ..addAll(playlist.songs);
                });
              } else {
                ref.read(playlistFocusSongIdProvider.notifier).state = null;
                Navigator.pop(context);
              }
            },
          ),
          title: Text(
            _isEditing
                ? '编辑歌单'
                : '${playlist.name}（${playlist.songCount}首）',
            style: TextStyle(color: AppColors.onScaffold(context), fontSize: 18),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            if (!_isEditing && playlist.songs.isNotEmpty)
              IconButton(
                tooltip: '播放全部',
                onPressed: () => playerService.setQueue(playlist.songs, startIndex: 0),
                icon: Icon(Icons.play_circle_fill, color: AppColors.accentOf(context), size: 28),
              ),
            if (_isEditing)
              TextButton(
                onPressed: () {
                  ref.read(playlistServiceProvider).updatePlaylist(id: playlist.id, songs: _reorderedSongs);
                  ref.read(playlistVersionProvider.notifier).state++;
                  setState(() => _isEditing = false);
                },
                child: Text('保存', style: TextStyle(color: AppColors.accentOf(context))),
              )
            else
              PopupMenuButton<String>(
                popUpAnimationStyle: AnimationStyle.noAnimation,
                icon: Icon(Icons.more_vert, color: AppColors.onScaffold(context)),
                color: AppColors.dialogBg(context),
                onSelected: (value) {
                  switch (value) {
                    case 'play_all':
                      if (playlist.songs.isNotEmpty) {
                        playerService.setQueue(playlist.songs, startIndex: 0);
                      }
                    case 'edit':
                      _showEditDialog(context, ref, playlist);
                    case 'sort_name':
                      ref.read(playlistServiceProvider).sortSongsByName(playlist.id);
                      ref.read(playlistVersionProvider.notifier).state++;
                      setState(() {
                        _reorderedSongs
                          ..clear()
                          ..addAll(ref.read(playlistServiceProvider).getPlaylist(playlist.id)?.songs ?? []);
                      });
                    case 'sort_artist':
                      ref.read(playlistServiceProvider).sortSongsByArtist(playlist.id);
                      ref.read(playlistVersionProvider.notifier).state++;
                      setState(() {
                        _reorderedSongs
                          ..clear()
                          ..addAll(ref.read(playlistServiceProvider).getPlaylist(playlist.id)?.songs ?? []);
                      });
                    case 'sort_duration':
                      ref.read(playlistServiceProvider).sortSongsByDuration(playlist.id);
                      ref.read(playlistVersionProvider.notifier).state++;
                      setState(() {
                        _reorderedSongs
                          ..clear()
                          ..addAll(ref.read(playlistServiceProvider).getPlaylist(playlist.id)?.songs ?? []);
                      });
                    case 'reorder':
                      setState(() {
                        _isEditing = true;
                        _reorderedSongs
                          ..clear()
                          ..addAll(playlist.songs);
                      });
                    case 'delete':
                      _showDeleteDialog(context, ref, playlist);
                  }
                },
                itemBuilder: (context) {
                  final on = AppColors.onScaffold(context);
                  return [
                    PopupMenuItem(value: 'play_all', child: Text('播放全部', style: TextStyle(color: on))),
                    if (playlist.id != 'recent')
                      PopupMenuItem(value: 'edit', child: Text('编辑信息', style: TextStyle(color: on))),
                    PopupMenuItem(value: 'reorder', child: Text('手动排序', style: TextStyle(color: on))),
                    PopupMenuItem(value: 'sort_name', child: Text('按歌名排序', style: TextStyle(color: on))),
                    PopupMenuItem(value: 'sort_artist', child: Text('按歌手排序', style: TextStyle(color: on))),
                    PopupMenuItem(value: 'sort_duration', child: Text('按时长排序', style: TextStyle(color: on))),
                    if (playlist.id != 'favorites' && playlist.id != 'recent')
                      PopupMenuItem(value: 'delete', child: Text('删除歌单', style: TextStyle(color: on))),
                  ];
                },
              ),
          ],
        ),
        body: playlist.songs.isEmpty
            ? Center(child: Text('暂无歌曲', style: TextStyle(color: AppColors.mutedText(context))))
            : _isEditing
                ? _buildEditableList(playlist)
                : _buildNormalList(playerService, playlist, focusId),
      ),
    );
  }

  Widget _buildEditableList(Playlist playlist) {
    return ReorderableListView.builder(
      itemCount: _reorderedSongs.length,
      onReorder: (oldIndex, newIndex) {
        setState(() {
          if (newIndex > oldIndex) newIndex -= 1;
          final item = _reorderedSongs.removeAt(oldIndex);
          _reorderedSongs.insert(newIndex, item);
        });
      },
      itemBuilder: (context, index) {
        final song = _reorderedSongs[index];
        return ListTile(
          key: ValueKey('${song.id}_$index'),
          leading: Icon(Icons.drag_handle, color: AppColors.mutedText(context)),
          title: Text(song.name, style: TextStyle(color: AppColors.onScaffold(context))),
          subtitle: Text(song.singer, style: TextStyle(color: AppColors.mutedText(context), fontSize: 12)),
        );
      },
    );
  }

  Widget _buildNormalList(dynamic playerService, Playlist playlist, String? focusId) {
    return ListView.builder(
      controller: _scrollController,
      itemCount: playlist.songs.length,
      itemBuilder: (context, index) {
        final song = playlist.songs[index];
        final focused = focusId != null && song.id == focusId;
        return Container(
          color: focused ? AppColors.accentOf(context).withAlpha(28) : null,
          child: ListTile(
            onTap: () => playerService.setQueue(playlist.songs, startIndex: index),
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 48,
                height: 48,
                child: song.artwork != null && song.artwork!.isNotEmpty
                    ? Image.network(
                        song.artwork!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Icon(Icons.music_note, color: AppColors.mutedText(context)),
                      )
                    : Icon(Icons.music_note, color: AppColors.mutedText(context)),
              ),
            ),
            title: Text(
              song.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: AppColors.onScaffold(context), fontWeight: focused ? FontWeight.w700 : FontWeight.w500),
            ),
            subtitle: Text(
              song.singer,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: AppColors.mutedText(context), fontSize: 12),
            ),
            trailing: IconButton(
              icon: Icon(Icons.more_vert, color: AppColors.mutedText(context), size: 20),
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
                            playerService.setQueue(playlist.songs, startIndex: index);
                          },
                        ),
                        ListTile(
                          leading: const Icon(Icons.delete_outline),
                          title: const Text('从歌单移除'),
                          onTap: () {
                            ref.read(playlistServiceProvider).removeSongFromPlaylist(playlist.id, song.id);
                            ref.read(playlistVersionProvider.notifier).state++;
                            Navigator.pop(ctx);
                            setState(() {});
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
    );
  }

  void _showEditDialog(BuildContext context, WidgetRef ref, Playlist playlist) {
    final nameController = TextEditingController(text: playlist.name);
    final descController = TextEditingController(text: playlist.description ?? '');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.dialogBg(context),
        title: Text('编辑歌单', style: TextStyle(color: AppColors.onScaffold(context))),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              style: TextStyle(color: AppColors.onScaffold(context)),
              decoration: InputDecoration(hintText: '歌单名称', hintStyle: TextStyle(color: AppColors.mutedText(context))),
            ),
            TextField(
              controller: descController,
              style: TextStyle(color: AppColors.onScaffold(context)),
              decoration: InputDecoration(hintText: '描述', hintStyle: TextStyle(color: AppColors.mutedText(context))),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('取消', style: TextStyle(color: AppColors.mutedText(context)))),
          TextButton(
            onPressed: () {
              ref.read(playlistServiceProvider).updatePlaylist(
                    id: playlist.id,
                    name: nameController.text,
                    description: descController.text,
                  );
              ref.read(playlistVersionProvider.notifier).state++;
              Navigator.pop(ctx);
              setState(() {});
            },
            child: Text('保存', style: TextStyle(color: AppColors.accentOf(context))),
          ),
        ],
      ),
    );
  }

  void _showDeleteDialog(BuildContext context, WidgetRef ref, Playlist playlist) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.dialogBg(context),
        title: Text('删除歌单', style: TextStyle(color: AppColors.onScaffold(context))),
        content: Text('确定删除「${playlist.name}」？', style: TextStyle(color: AppColors.secondaryText(context))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('取消', style: TextStyle(color: AppColors.mutedText(context)))),
          TextButton(
            onPressed: () {
              ref.read(playlistServiceProvider).deletePlaylist(playlist.id);
              ref.read(playlistVersionProvider.notifier).state++;
              Navigator.pop(ctx);
              Navigator.pop(context);
            },
            child: const Text('删除', style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );
  }
}
