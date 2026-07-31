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
  @override
  Widget build(BuildContext context) {
    final playlists = ref.watch(playlistsProvider);
    final playlistService = ref.watch(playlistServiceProvider);
    final favorites = playlistService.favorites;
    final recent = playlistService.recent;
    final playerService = ref.watch(playerServiceProvider);
    final filteredPlaylists = _filterAndSort(playlists);
    final songSearch = _searchQuery.isEmpty
        ? null
        : ref.watch(playlistSongSearchProvider(_searchQuery));
    final songHits = songSearch?.valueOrNull ?? const <PlaylistSongMatch>[];

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
                    if (songSearch?.isLoading ?? false)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Center(child: CircularProgressIndicator()),
                      ),
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
    Playlist playlist, {
    String? focusSongId,
  }) {
    context.pushNamed(
      'playlistDetail',
      pathParameters: {'playlistId': playlist.id},
      queryParameters: {if (focusSongId != null) 'focusSongId': focusSongId},
    );
  }

  Future<void> _playPlaylist(
    dynamic playerService,
    Playlist playlist, {
    int startIndex = 0,
  }) async {
    try {
      if (playlist.songCount <= 0) return;
      await playerService.playPagedPlaylist(
        songCount: playlist.songCount,
        startIndex: startIndex,
        loadPage: (offset, limit) => ref
            .read(playlistServiceProvider)
            .getSongsPage(playlist.id, offset: offset, limit: limit),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('加载歌曲失败: $error')));
    }
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
        onTap: () => _openPlaylist(context, playlist, focusSongId: song.id),
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
          onPressed: () async {
            await _playPlaylist(playerService, playlist, startIndex: index);
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
          if (favorites != null) _openPlaylist(context, favorites);
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
              Semantics(
                container: true,
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: onAccent.withAlpha(40),
                    shape: BoxShape.circle,
                  ),
                  child: IconButton(
                    tooltip: '播放全部',
                    padding: EdgeInsets.zero,
                    onPressed: () async {
                      if (favorites != null && favorites.songCount > 0) {
                        await _playPlaylist(playerService, favorites);
                      }
                    },
                    icon: Icon(
                      Icons.play_arrow_rounded,
                      color: onAccent,
                      size: 30,
                    ),
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
          if (recent != null) _openPlaylist(context, recent);
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
              Semantics(
                container: true,
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: onBlue.withAlpha(40),
                    shape: BoxShape.circle,
                  ),
                  child: IconButton(
                    tooltip: '播放全部',
                    padding: EdgeInsets.zero,
                    onPressed: () async {
                      if (recent != null && recent.songCount > 0) {
                        await _playPlaylist(playerService, recent);
                      }
                    },
                    icon: Icon(
                      Icons.play_arrow_rounded,
                      color: onBlue,
                      size: 30,
                    ),
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
        onTap: () => _openPlaylist(context, playlist),
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
            onPressed: () async {
              if (nameController.text.isNotEmpty) {
                try {
                  await ref.read(createPlaylistProvider)(
                    nameController.text,
                    description: descController.text.isEmpty
                        ? null
                        : descController.text,
                  );
                  if (context.mounted) Navigator.pop(context);
                } catch (error) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text('创建失败: $error')));
                }
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
            onPressed: () async {
              if (nameController.text.isNotEmpty) {
                try {
                  await ref
                      .read(playlistServiceProvider)
                      .updatePlaylist(
                        id: playlist.id,
                        name: nameController.text,
                        description: descController.text.isEmpty
                            ? null
                            : descController.text,
                      );
                  if (ctx.mounted) Navigator.pop(ctx);
                } catch (error) {
                  if (!ctx.mounted) return;
                  ScaffoldMessenger.of(
                    ctx,
                  ).showSnackBar(SnackBar(content: Text('保存失败: $error')));
                }
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
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              backgroundColor: AppColors.dialogBg(context),
              insetPadding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 24,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
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
                                Text(
                                  '导入歌单',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                SizedBox(height: 2),
                                Text(
                                  '粘贴分享链接或输入歌单 ID',
                                  style: TextStyle(fontSize: 12),
                                ),
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
                            Text(
                              '来源平台',
                              style: TextStyle(
                                color: AppColors.secondaryText(ctx),
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 8),
                            SegmentedButton<String>(
                              segments: const [
                                ButtonSegment(
                                  value: 'tx',
                                  label: Text('QQ'),
                                  icon: Icon(Icons.music_note_rounded),
                                ),
                                ButtonSegment(
                                  value: 'kw',
                                  label: Text('酷我'),
                                  icon: Icon(Icons.graphic_eq_rounded),
                                ),
                                ButtonSegment(
                                  value: 'wy',
                                  label: Text('网易'),
                                  icon: Icon(Icons.album_rounded),
                                ),
                              ],
                              selected: {platform},
                              onSelectionChanged: busy
                                  ? null
                                  : (value) =>
                                        setLocal(() => platform = value.first),
                            ),
                            const SizedBox(height: 20),
                            Text(
                              '歌单链接或 ID',
                              style: TextStyle(
                                color: AppColors.secondaryText(ctx),
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              controller: inputCtrl,
                              enabled: !busy,
                              minLines: 2,
                              maxLines: 3,
                              style: TextStyle(
                                color: AppColors.onScaffold(ctx),
                              ),
                              decoration: const InputDecoration(
                                hintText:
                                    '例如：https://y.qq.com/n/ryqq/playlist/123\n或直接输入数字 ID',
                                alignLabelWithHint: true,
                                prefixIcon: Icon(Icons.link_rounded),
                              ).applyDefaults(Theme.of(ctx).inputDecorationTheme),
                            ),
                            if (error != null) ...[
                              const SizedBox(height: 12),
                              DecoratedBox(
                                decoration: BoxDecoration(
                                  color: AppColors.error.withValues(alpha: .12),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Text(
                                    error!,
                                    style: const TextStyle(
                                      color: AppColors.error,
                                      fontSize: 12,
                                    ),
                                  ),
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
                          top: BorderSide(color: AppColors.cardBorder(ctx)),
                        ),
                        color: AppColors.dialogBg(ctx),
                      ),
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(50),
                        ),
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
                                        input: input,
                                        platformHint: platform,
                                      );
                                  if (!ctx.mounted) return;
                                  final ok = await showDialog<bool>(
                                    context: ctx,
                                    builder: (c2) => AlertDialog(
                                      backgroundColor: AppColors.dialogBg(
                                        context,
                                      ),
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
                                              color: AppColors.mutedText(
                                                context,
                                              ),
                                            ),
                                          ),
                                        ),
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(c2, true),
                                          child: Text(
                                            '导入',
                                            style: TextStyle(
                                              color: AppColors.accentOf(
                                                context,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                  if (ok == true) {
                                    await ref
                                        .read(playlistServiceProvider)
                                        .createPlaylist(
                                          name: imported.name,
                                          description: '导入自${imported.source}',
                                          songs: imported.songs,
                                        );
                                    if (ctx.mounted) Navigator.pop(ctx);
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            '已导入「${imported.name}」${imported.songs.length} 首',
                                          ),
                                        ),
                                      );
                                    }
                                  } else {
                                    if (!ctx.mounted) return;
                                    setLocal(() => busy = false);
                                  }
                                } catch (e) {
                                  if (!ctx.mounted) return;
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
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
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
    final media = MediaQuery.of(context);
    final maxH = media.size.height * 0.56;
    final maxW = media.size.width.clamp(280.0, 420.0);

    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogCtx) {
        final on = AppColors.onScaffold(context);
        final muted = AppColors.mutedText(context);
        Widget action({
          required IconData icon,
          required String label,
          required VoidCallback onTap,
          Color? color,
          bool destructive = false,
        }) {
          final c = color ?? (destructive ? AppColors.error : on);
          return Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Icon(icon, color: c, size: 22),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        label,
                        style: TextStyle(
                          color: c,
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 28,
            vertical: 24,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxW, maxHeight: maxH),
            child: Material(
              color: AppColors.dialogBg(context),
              elevation: 8,
              shadowColor: Colors.black38,
              borderRadius: BorderRadius.circular(20),
              clipBehavior: Clip.antiAlias,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 18, 10, 10),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            playlist.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: on,
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          onPressed: () => Navigator.pop(dialogCtx),
                          icon: Icon(Icons.close_rounded, color: muted),
                        ),
                      ],
                    ),
                  ),
                  Divider(height: 1, color: AppColors.cardBorder(context)),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (playlist.id != 'recent')
                            action(
                              icon: Icons.edit_outlined,
                              label: '编辑歌单',
                              onTap: () {
                                Navigator.pop(dialogCtx);
                                _showEditDialog(context, ref, playlist);
                              },
                            ),
                          if (playlist.id != 'favorites' &&
                              playlist.songCount > 0)
                            action(
                              icon: Icons.favorite_border_rounded,
                              label: '全部添加到我喜欢的音乐',
                              onTap: () async {
                                final int added;
                                try {
                                  added = await ref
                                      .read(playlistServiceProvider)
                                      .addAllSongsToFavorites(playlist.id);
                                } catch (error) {
                                  if (!context.mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('添加失败: $error')),
                                  );
                                  return;
                                }
                                if (!dialogCtx.mounted) return;
                                Navigator.pop(dialogCtx);
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      added == 0
                                          ? '所有歌曲已在我喜欢的音乐中'
                                          : '已添加 $added 首到我喜欢的音乐',
                                    ),
                                  ),
                                );
                              },
                            ),
                          if (playlist.id != 'favorites' &&
                              playlist.id != 'recent')
                            action(
                              icon: Icons.delete_outline_rounded,
                              label: '删除歌单',
                              destructive: true,
                              onTap: () async {
                                try {
                                  await ref
                                      .read(playlistServiceProvider)
                                      .deletePlaylist(playlist.id);
                                } catch (error) {
                                  if (!context.mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('删除失败: $error')),
                                  );
                                  return;
                                }
                                if (!dialogCtx.mounted) return;
                                Navigator.pop(dialogCtx);
                              },
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
