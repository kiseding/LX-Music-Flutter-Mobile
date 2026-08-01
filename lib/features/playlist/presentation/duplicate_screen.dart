import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../player/domain/music_item.dart';
import '../../player/presentation/player_provider.dart';
import '../domain/duplicate_detector.dart';
import 'playlist_provider.dart';

class DuplicateScreen extends ConsumerStatefulWidget {
  const DuplicateScreen({super.key});

  @override
  ConsumerState<DuplicateScreen> createState() => _DuplicateScreenState();
}

class _DuplicateScreenState extends ConsumerState<DuplicateScreen> {
  bool _removing = false;

  @override
  Widget build(BuildContext context) {
    final playlistService = ref.watch(playlistServiceProvider);
    final songsById = <String, MusicItem>{
      for (final playlist in playlistService.playlists)
        for (final song in playlist.songs) song.id: song,
    };
    final allSongs = songsById.values.toList(growable: false);
    final favorites = playlistService.favorites?.songs ?? const [];

    final detector = DuplicateDetector(
      songs: allSongs,
      favoriteIds: favorites.map((s) => s.id).toSet(),
    );
    final groups = detector.detect();

    return Scaffold(
      backgroundColor: AppColors.scaffold(context),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text('重复歌曲',
            style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: AppColors.onScaffold(context))),
      ),
      body: SafeArea(
        top: false,
        child: groups.isEmpty
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.task_alt,
                        size: 56, color: AppColors.mutedText(context)),
                    const SizedBox(height: 12),
                    Text('没有发现重复歌曲',
                        style: TextStyle(
                            color: AppColors.mutedText(context),
                            fontSize: 14)),
                  ],
                ),
              )
            : ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: groups.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (context, index) =>
                    _buildGroup(context, groups[index]),
              ),
      ),
    );
  }

  Widget _buildGroup(BuildContext context, DuplicateGroup group) {
    final playProvider = ref.read(playerServiceProvider);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.card(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.cardBorder(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(group.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppColors.onScaffold(context))),
                    Text('${group.artist} · ${group.count} 个版本',
                        style: TextStyle(
                            fontSize: 12,
                            color: AppColors.mutedText(context))),
                  ],
                ),
              ),
              IconButton(
                tooltip: '播放',
                icon: Icon(Icons.play_arrow,
                    size: 22, color: AppColors.accentOf(context)),
                onPressed: () =>
                    playProvider.playPlaylist(group.songs, index: 0),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final song in group.songs)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                song.id == group.bestSong.id
                    ? Icons.star
                    : Icons.music_note,
                size: 18,
                color: song.id == group.bestSong.id
                    ? AppColors.accentOf(context)
                    : AppColors.mutedText(context),
              ),
              title: Text(
                _songLabel(song),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 13,
                    color: AppColors.onScaffold(context)),
              ),
              trailing: song.id == group.bestSong.id
                  ? Text('推荐保留',
                      style: TextStyle(
                          fontSize: 11,
                          color: AppColors.accentOf(context)))
                  : null,
            ),
          if (group.redundantSongs.isNotEmpty)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _removing
                    ? null
                    : () => _removeRedundant(group),
                icon: const Icon(Icons.delete_outline, size: 16),
                label: Text(_removing ? '处理中…' : '从所有歌单移除其余版本'),
              ),
            ),
        ],
      ),
    );
  }

  String _songLabel(MusicItem song) {
    final platform = song.platform.toUpperCase();
    return '${song.name} · $platform'
        '${(song.lyricsUrl?.isNotEmpty ?? false) ? ' · 有歌词' : ''}';
  }

  Future<void> _removeRedundant(DuplicateGroup group) async {
    setState(() => _removing = true);
    try {
      final service = ref.read(playlistServiceProvider);
      var removed = 0;
      for (final redundant in group.redundantSongs) {
        for (final playlist in service.playlists) {
          if (playlist.id == 'recent') continue;
          if (playlist.songs.any((s) => s.id == redundant.id)) {
            final ok =
                await service.removeSongFromPlaylist(playlist.id, redundant.id);
            if (ok) removed++;
          }
        }
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已移除 $removed 处重复项')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('移除失败: $e')));
    } finally {
      if (mounted) setState(() => _removing = false);
    }
  }
}
