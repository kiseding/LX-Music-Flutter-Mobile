import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/artwork_image.dart';
import '../domain/playlist.dart';
import '../domain/playlist_import_service.dart';
import '../../player/domain/music_item.dart';
import 'playlist_provider.dart';
import '../../player/presentation/player_provider.dart';

enum PlaylistSortMode { recent, name, songCount }

class PlaylistScreen extends ConsumerStatefulWidget {
  const PlaylistScreen({super.key});

  @override
  ConsumerState<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends ConsumerState<PlaylistScreen> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  PlaylistSortMode _sortMode = PlaylistSortMode.recent;

  String get _searchQuery => _searchController.text;

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  List<Playlist> _filterAndSort(List<Playlist> playlists) {
    // 系统歌单：我喜欢 / 最近播放 单独展示，不进普通列表
    var filtered = playlists
        .where((p) => p.id != 'favorites' && p.id != 'recent')
        .toList();

    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      filtered = filtered.where((p) {
        if (p.name.toLowerCase().contains(q)) return true;
        if ((p.description ?? '').toLowerCase().contains(q)) return true;
        return false;
      }).toList();
    }

    switch (_sortMode) {
      case PlaylistSortMode.name:
        filtered.sort((a, b) => a.name.compareTo(b.name));
      case PlaylistSortMode.songCount:
        filtered.sort((a, b) => b.songCount.compareTo(a.songCount));
      case PlaylistSortMode.recent:
        break;
    }

    return filtered;
  }

  /// 在库中按歌曲搜索：返回 (playlist, song, index)
  List<({Playlist playlist, MusicItem song, int index})> _searchSongsInLibrary(
    List<Playlist> playlists,
  ) {
    if (_searchQuery.isEmpty) return const [];
    final q = _searchQuery.toLowerCase();
    final out = <({Playlist playlist, MusicItem song, int index})>[];
    for (final p in playlists) {
      for (var i = 0; i < p.songs.length; i++) {
        final s = p.songs[i];
        if (s.name.toLowerCase().contains(q) ||
            s.singer.toLowerCase().contains(q) ||
            s.album.toLowerCase().contains(q)) {
          out.add((playlist: p, song: s, index: i));
        }
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final playlists = ref.watch(playlistsProvider);
    final playlistService = ref.watch(playlistServiceProvider);
    final favorites = playlistService.favorites;
    final recent = playlistService.recent;
    final playerService = ref.watch(playerServiceProvider);
    final filteredPlaylists = _filterAndSort(playlists);
    final songHits = _searchSongsInLibrary(playlists);

    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        // 主壳已固定预留底部导航和迷你播放器；键盘直接覆盖它们，避免重复预留空白。
        resizeToAvoidBottomInset: false,
        appBar: AppBar(
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: 0,
          elevation: 0,
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: scheme.primary.withAlpha(40),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.music_note, color: scheme.primary, size: 20),
              ),
              const SizedBox(width: 12),
              Text(
                '我的歌单',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: scheme.onSurface,
                ),
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: '导入歌单',
              icon: Icon(
                Icons.playlist_add,
                color: AppColors.onScaffold(context),
                size: 24,
              ),
              onPressed: () => _showImportDialog(context, ref),
            ),
            IconButton(
              tooltip: '新建歌单',
              icon: Icon(
                Icons.add,
                color: AppColors.onScaffold(context),
                size: 24,
              ),
              onPressed: () => _showCreateDialog(context, ref),
            ),
          ],
        ),
        // 搜索框固定在列表外，避免 ListView 子项重建导致输入法收起
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: TextField(
                controller: _searchController,
                focusNode: _searchFocus,
                style: TextStyle(
                  color: AppColors.onScaffold(context),
                  fontSize: 14,
                ),
                // 延迟过滤，避免每个字符整页 rebuild 抢焦点
                onChanged: (_) {
                  Future.microtask(() {
                    if (mounted) setState(() {});
                  });
                },
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: '在库中搜索歌曲/歌单',
                  hintStyle: TextStyle(
                    color: AppColors.mutedText(context),
                    fontSize: 14,
                  ),
                  prefixIcon: Icon(
                    Icons.search,
                    color: AppColors.mutedText(context),
                    size: 20,
                  ),
                  filled: true,
                  fillColor: AppColors.miniBar(context),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                ),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                children: [
                  if (_searchQuery.isEmpty) ...[
                    _buildFavoritesCard(context, ref, favorites, playerService),
                    const SizedBox(height: 12),
                    _buildRecentCard(context, ref, recent, playerService),
                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '歌单 (${filteredPlaylists.length})',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: scheme.onSurface,
                          ),
                        ),
                        IconButton(
                          icon: Icon(
                            Icons.sort,
                            color: scheme.onSurface.withAlpha(120),
                            size: 20,
                          ),
                          onPressed: () => _showSortMenu(context),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    ...filteredPlaylists.map(
                      (playlist) => _buildPlaylistItem(context, ref, playlist),
                    ),
                  ] else ...[
                    if (songHits.isNotEmpty) ...[
                      Text(
                        '歌曲 (${songHits.length})',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ...songHits.map(
                        (hit) => _buildSongHitItem(
                          context,
                          ref,
                          hit.playlist,
                          hit.song,
                          hit.index,
                          playerService,
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (filteredPlaylists.isNotEmpty) ...[
                      Text(
                        '歌单 (${filteredPlaylists.length})',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ...filteredPlaylists.map(
                        (playlist) =>
                            _buildPlaylistItem(context, ref, playlist),
                      ),
                    ],
                    if (songHits.isEmpty && filteredPlaylists.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 32),
                        child: Center(
                          child: Text(
                            '未找到匹配的歌曲或歌单',
                            style: TextStyle(
                              color: scheme.onSurface.withAlpha(120),
                            ),
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openPlaylist(
    BuildContext context,
    WidgetRef ref,
    Playlist playlist, {
    String? focusSongId,
  }) {
    // 用最新 playlistService 数据，避免 stale 引用
    final latest =
        ref.read(playlistServiceProvider).getPlaylist(playlist.id) ?? playlist;
    ref.read(currentPlaylistProvider.notifier).state = latest;
    ref.read(playlistFocusSongIdProvider.notifier).state = focusSongId;
    context.push('/playlist/detail');
  }

  Widget _buildSongHitItem(
    BuildContext context,
    WidgetRef ref,
    Playlist playlist,
    MusicItem song,
    int index,
    dynamic playerService,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppColors.card(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.cardBorder(context)),
      ),
      child: ListTile(
        onTap: () =>
            _openPlaylist(context, ref, playlist, focusSongId: song.id),
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 44,
            height: 44,
            child: song.artwork != null && song.artwork!.isNotEmpty
                ? ArtworkImage(
                    song.artwork!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Icon(
                      Icons.music_note,
                      color: AppColors.mutedText(context),
                    ),
                  )
                : Icon(Icons.music_note, color: AppColors.mutedText(context)),
          ),
        ),
        title: Text(
          song.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: AppColors.onScaffold(context), fontSize: 14),
        ),
        subtitle: Text(
          '${song.singer} · ${playlist.name}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: AppColors.mutedText(context), fontSize: 12),
        ),
        trailing: IconButton(
          icon: Icon(
            Icons.play_arrow_rounded,
            color: AppColors.accentOf(context),
          ),
          onPressed: () {
            final latest =
                ref.read(playlistServiceProvider).getPlaylist(playlist.id) ??
                    playlist;
            if (latest.songs.isEmpty) return;
            final idx = latest.songs.indexWhere((s) => s.id == song.id);
            playerService.setQueue(
              latest.songs,
              startIndex: idx >= 0 ? idx : index,
            );
          },
        ),
      ),
    );
  }

  Widget _buildFavoritesCard(
    BuildContext context,
    WidgetRef ref,
    Playlist? favorites,
    dynamic playerService,
  ) {
    final songCount = favorites?.songCount ?? 0;
    final accent = AppColors.accentOf(context);
    // 主题的 onPrimary 在深色下是黑色（黄底黑字），但渐变卡片视觉上应统一为白字。
    const onAccent = Colors.white;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          if (favorites != null) _openPlaylist(context, ref, favorites);
        },
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [accent.withAlpha(220), accent.withAlpha(120)],
            ),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: onAccent.withAlpha(40),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.favorite_rounded, color: onAccent, size: 28),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '我喜欢的音乐',
                      style: TextStyle(
                        color: onAccent,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$songCount 首歌曲',
                      style: TextStyle(
                        color: onAccent.withAlpha(200),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              GestureDetector(
                onTap: () {
                  if (favorites != null && favorites.songs.isNotEmpty) {
                    playerService.playPlaylist(favorites.songs);
                  }
                },
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: onAccent.withAlpha(40),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.play_arrow_rounded,
                    color: onAccent,
                    size: 30,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRecentCard(
    BuildContext context,
    WidgetRef ref,
    Playlist? recent,
    dynamic playerService,
  ) {
    final songCount = recent?.songCount ?? 0;
    // 蓝色渐变（与“我喜欢的音乐”结构一致，仅替换为蓝色）
    const blue = Colors.blue;
    final onBlue = Colors.white;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          if (recent != null) _openPlaylist(context, ref, recent);
        },
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [blue.withAlpha(220), blue.withAlpha(120)],
            ),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: onBlue.withAlpha(40),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.history_rounded, color: onBlue, size: 28),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '最近播放',
                      style: TextStyle(
                        color: onBlue,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$songCount 首歌曲',
                      style: TextStyle(
                        color: onBlue.withAlpha(200),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              GestureDetector(
                onTap: () {
                  if (recent != null && recent.songs.isNotEmpty) {
                    playerService.playPlaylist(recent.songs);
                  }
                },
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: onBlue.withAlpha(40),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.play_arrow_rounded,
                    color: onBlue,
                    size: 30,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPlaylistItem(
    BuildContext context,
    WidgetRef ref,
    Playlist playlist,
  ) {
    return Container(
      margin: EdgeInsets.only(bottom: 12),
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.fill(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.cardBorder(context)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openPlaylist(context, ref, playlist),
        child: Row(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                gradient: LinearGradient(
                  colors: [
                    Theme.of(context).colorScheme.primary.withAlpha(100),
                    Theme.of(context).colorScheme.primary.withAlpha(40),
                  ],
                ),
              ),
              child: Center(
                child: Text(
                  playlist.name.substring(0, 1),
                  style: TextStyle(
                    color: AppColors.onScaffold(context),
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    playlist.name,
                    style: TextStyle(
                      color: AppColors.onScaffold(context),
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${playlist.songCount} 首歌曲 · ${playlist.description ?? "私人"}',
                    style: TextStyle(
                      color: AppColors.mutedText(context),
                      fontSize: 12,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            IconButton(
              icon: Icon(
                Icons.more_vert,
                color: AppColors.mutedText(context),
                size: 20,
              ),
              onPressed: () => _showPlaylistMoreMenu(context, ref, playlist),
            ),
          ],
        ),
      ),
    );
  }

  void _showCreateDialog(BuildContext context, WidgetRef ref) {
    final nameController = TextEditingController();
    final descController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.dialogBg(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          '创建歌单',
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
                filled: true,
                fillColor: AppColors.fill2(context),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: descController,
              style: TextStyle(color: AppColors.onScaffold(context)),
              decoration: InputDecoration(
                hintText: '描述（可选）',
                hintStyle: TextStyle(color: AppColors.mutedText(context)),
                filled: true,
                fillColor: AppColors.fill2(context),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              '取消',
              style: TextStyle(color: AppColors.mutedText(context)),
            ),
          ),
          TextButton(
            onPressed: () {
              if (nameController.text.isNotEmpty) {
                ref.read(createPlaylistProvider)(
                  nameController.text,
                  description:
                      descController.text.isEmpty ? null : descController.text,
                );
                Navigator.pop(context);
              }
            },
            child: Text(
              '创建',
              style: TextStyle(color: AppColors.accentOf(context)),
            ),
          ),
        ],
      ),
    );
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
                filled: true,
                fillColor: AppColors.fill2(context),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: descController,
              style: TextStyle(color: AppColors.onScaffold(context)),
              decoration: InputDecoration(
                hintText: '描述（可选）',
                hintStyle: TextStyle(color: AppColors.mutedText(context)),
                filled: true,
                fillColor: AppColors.fill2(context),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
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
            onPressed: () {
              if (nameController.text.isNotEmpty) {
                ref.read(playlistServiceProvider).updatePlaylist(
                      id: playlist.id,
                      name: nameController.text,
                      description: descController.text.isEmpty
                          ? null
                          : descController.text,
                    );
                setState(() {});
                Navigator.pop(ctx);
              }
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

  void _showSortMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.dialogBg(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 32,
              height: 4,
              margin: EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color: AppColors.mutedText(context),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                '排序方式',
                style: TextStyle(
                  color: AppColors.onScaffold(context),
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            _sortOption(
              context,
              PlaylistSortMode.recent,
              Icons.access_time,
              '最近添加',
            ),
            _sortOption(
              context,
              PlaylistSortMode.name,
              Icons.sort_by_alpha,
              '名称排序',
            ),
            _sortOption(
              context,
              PlaylistSortMode.songCount,
              Icons.music_note,
              '歌曲数量',
            ),
          ],
        ),
      ),
    );
  }

  Widget _sortOption(
    BuildContext context,
    PlaylistSortMode mode,
    IconData icon,
    String label,
  ) {
    final isSelected = _sortMode == mode;
    return ListTile(
      leading: Icon(
        icon,
        color: isSelected
            ? AppColors.accentOf(context)
            : AppColors.onScaffold(context),
      ),
      title: Text(
        label,
        style: TextStyle(
          color: isSelected
              ? AppColors.accentOf(context)
              : AppColors.onScaffold(context),
          fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      trailing: isSelected
          ? Icon(Icons.check, color: AppColors.accentOf(context), size: 20)
          : null,
      onTap: () {
        setState(() => _sortMode = mode);
        Navigator.pop(context);
      },
    );
  }

  Future<void> _showImportDialog(BuildContext context, WidgetRef ref) async {
    final inputCtrl = TextEditingController();
    var platform = 'tx';
    var busy = false;
    String? error;

    await showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              backgroundColor: AppColors.dialogBg(context),
              insetPadding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24)),
              clipBehavior: Clip.antiAlias,
              contentPadding: EdgeInsets.zero,
              content: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 440,
                  maxHeight: MediaQuery.sizeOf(ctx).height * .82,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 20, 12, 16),
                      child: Row(
                        children: [
                          Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: Theme.of(ctx).colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Icon(
                              Icons.playlist_add_rounded,
                              color: AppColors.accentOf(ctx),
                            ),
                          ),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('导入歌单',
                                    style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.w700)),
                                SizedBox(height: 2),
                                Text('粘贴分享链接或输入歌单 ID',
                                    style: TextStyle(fontSize: 12)),
                              ],
                            ),
                          ),
                          IconButton(
                            onPressed: busy ? null : () => Navigator.pop(ctx),
                            icon: const Icon(Icons.close_rounded),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.sizeOf(ctx).height * .48,
                      ),
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text('来源平台',
                                style: TextStyle(
                                    color: AppColors.secondaryText(ctx),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600)),
                            const SizedBox(height: 8),
                            SegmentedButton<String>(
                              segments: const [
                                ButtonSegment(
                                    value: 'tx',
                                    label: Text('QQ'),
                                    icon: Icon(Icons.music_note_rounded)),
                                ButtonSegment(
                                    value: 'kw',
                                    label: Text('酷我'),
                                    icon: Icon(Icons.graphic_eq_rounded)),
                                ButtonSegment(
                                    value: 'wy',
                                    label: Text('网易'),
                                    icon: Icon(Icons.album_rounded)),
                              ],
                              selected: {platform},
                              onSelectionChanged: busy
                                  ? null
                                  : (value) =>
                                      setLocal(() => platform = value.first),
                            ),
                            const SizedBox(height: 20),
                            Text('歌单链接或 ID',
                                style: TextStyle(
                                    color: AppColors.secondaryText(ctx),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600)),
                            const SizedBox(height: 8),
                            TextField(
                              controller: inputCtrl,
                              enabled: !busy,
                              minLines: 2,
                              maxLines: 3,
                              style:
                                  TextStyle(color: AppColors.onScaffold(ctx)),
                              decoration: const InputDecoration(
                                hintText:
                                    '例如：https://y.qq.com/n/ryqq/playlist/123\n或直接输入数字 ID',
                                alignLabelWithHint: true,
                                prefixIcon: Icon(Icons.link_rounded),
                              ).applyDefaults(
                                Theme.of(ctx).inputDecorationTheme,
                              ),
                            ),
                            if (error != null) ...[
                              const SizedBox(height: 12),
                              DecoratedBox(
                                decoration: BoxDecoration(
                                    color:
                                        AppColors.error.withValues(alpha: .12),
                                    borderRadius: BorderRadius.circular(12)),
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Text(error!,
                                      style: const TextStyle(
                                          color: AppColors.error,
                                          fontSize: 12)),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                      decoration: BoxDecoration(
                          border: Border(
                              top:
                                  BorderSide(color: AppColors.cardBorder(ctx))),
                          color: AppColors.dialogBg(ctx)),
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(50)),
                        onPressed: busy
                            ? null
                            : () async {
                                final input = inputCtrl.text.trim();
                                if (input.isEmpty) {
                                  setLocal(() => error = '请输入链接或 ID');
                                  return;
                                }
                                setLocal(() {
                                  busy = true;
                                  error = null;
                                });
                                try {
                                  final imported = await PlaylistImportService()
                                      .import(
                                          input: input, platformHint: platform);
                                  if (!ctx.mounted) return;
                                  final ok = await showDialog<bool>(
                                    context: ctx,
                                    builder: (c2) => AlertDialog(
                                      backgroundColor:
                                          AppColors.dialogBg(context),
                                      title: Text(
                                        imported.name,
                                        style: TextStyle(
                                          color: AppColors.onScaffold(context),
                                        ),
                                      ),
                                      content: Text(
                                        '共 ${imported.songs.length} 首，确认导入到本地歌单？',
                                        style: TextStyle(
                                          color: AppColors.mutedText(context),
                                        ),
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(c2, false),
                                          child: Text(
                                            '取消',
                                            style: TextStyle(
                                              color:
                                                  AppColors.mutedText(context),
                                            ),
                                          ),
                                        ),
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(c2, true),
                                          child: Text(
                                            '导入',
                                            style: TextStyle(
                                              color:
                                                  AppColors.accentOf(context),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                  if (ok == true) {
                                    final created = ref
                                        .read(playlistServiceProvider)
                                        .createPlaylist(
                                          name: imported.name,
                                          description: '导入自${imported.source}',
                                        );
                                    ref
                                        .read(playlistServiceProvider)
                                        .updatePlaylist(
                                          id: created.id,
                                          songs: imported.songs,
                                        );
                                    ref
                                        .read(playlistVersionProvider.notifier)
                                        .state++;
                                    if (ctx.mounted) Navigator.pop(ctx);
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            '已导入「${imported.name}」${imported.songs.length} 首',
                                          ),
                                        ),
                                      );
                                    }
                                  } else {
                                    setLocal(() => busy = false);
                                  }
                                } catch (e) {
                                  setLocal(() {
                                    busy = false;
                                    error = e.toString().replaceFirst(
                                          'Exception: ',
                                          '',
                                        );
                                  });
                                }
                              },
                        icon: busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.auto_awesome_rounded),
                        label: Text(busy ? '正在解析歌单…' : '解析歌单'),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showPlaylistMoreMenu(
    BuildContext context,
    WidgetRef ref,
    Playlist playlist,
  ) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.dialogBg(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 32,
              height: 4,
              margin: EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color: AppColors.mutedText(context),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                playlist.name,
                style: TextStyle(
                  color: AppColors.onScaffold(context),
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Divider(color: AppColors.cardBorder(context), height: 1),
            if (playlist.id != 'recent')
              ListTile(
                leading: Icon(Icons.edit, color: AppColors.onScaffold(context)),
                title: Text(
                  '编辑歌单',
                  style: TextStyle(color: AppColors.onScaffold(context)),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _showEditDialog(context, ref, playlist);
                },
              ),
            if (playlist.id != 'favorites' && playlist.id != 'recent')
              ListTile(
                leading: Icon(Icons.delete, color: AppColors.error),
                title: const Text(
                  '删除歌单',
                  style: TextStyle(color: AppColors.error),
                ),
                onTap: () {
                  ref.read(playlistServiceProvider).deletePlaylist(playlist.id);
                  Navigator.pop(context);
                },
              ),
          ],
        ),
      ),
    );
  }
}
