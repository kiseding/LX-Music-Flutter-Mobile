import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/artwork_image.dart';
import '../../player/domain/music_item.dart';
import '../../player/presentation/player_provider.dart';
import 'leaderboard_provider.dart';

/// 通过 ID 和名称显示的排行榜详情页（用于路由）
class LeaderboardDetailScreenById extends ConsumerWidget {
  final String id;
  final String name;
  const LeaderboardDetailScreenById(
      {super.key, required this.id, required this.name});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final songsAsync = ref.watch(leaderboardSongsProvider(id));

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
      ),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text(name,
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppColors.onScaffold(context))),
        ),
        body: songsAsync.when(
          loading: () => Center(
              child: CircularProgressIndicator(
                  color: AppColors.accentOf(context))),
          error: (e, _) => Center(
              child: Text('加载失败: $e',
                  style: TextStyle(color: AppColors.mutedText(context)))),
          data: (songs) {
            if (songs.isEmpty) {
              return Center(
                  child: Text('暂无歌曲数据',
                      style: TextStyle(color: AppColors.mutedText(context))));
            }
            return ListView.builder(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              itemCount: songs.length,
              itemBuilder: (context, index) =>
                  _buildSongItem(context, ref, songs[index], index),
            );
          },
        ),
      ),
    );
  }

  Widget _buildSongItem(
      BuildContext context, WidgetRef ref, MusicItem song, int index) {
    final playerService = ref.read(playerServiceProvider);
    final currentMusic = ref.watch(currentMusicProvider);
    final isPlaying = currentMusic?.id == song.id;

    return Container(
      margin: EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          final songsAsync = ref.read(leaderboardSongsProvider(id));
          final songs = songsAsync.value ?? [];
          playerService.setQueue(songs, startIndex: index);
        },
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              SizedBox(
                width: 32,
                child: Text(
                  '${index + 1}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: index < 3
                        ? AppColors.accentOf(context)
                        : AppColors.mutedText(context),
                    fontSize: 14,
                    fontWeight: index < 3 ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.cardBorder(context)),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: song.artwork != null && song.artwork!.isNotEmpty
                      ? ArtworkImage(song.artwork!,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Icon(Icons.music_note,
                              color: AppColors.mutedText(context), size: 20))
                      : Icon(Icons.music_note,
                          color: AppColors.mutedText(context), size: 20),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(song.name,
                        style: TextStyle(
                            color: isPlaying
                                ? AppColors.accentOf(context)
                                : AppColors.onScaffold(context),
                            fontSize: 14,
                            fontWeight: FontWeight.w500),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(song.singer,
                        style: TextStyle(
                            color: AppColors.mutedText(context), fontSize: 12),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
