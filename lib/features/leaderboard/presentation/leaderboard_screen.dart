import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/music_source/platform/music_platform.dart';
import '../../player/domain/music_item.dart';
import '../../player/presentation/player_provider.dart';
import 'leaderboard_provider.dart';

class LeaderboardScreen extends ConsumerWidget {
  const LeaderboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categoriesAsync = ref.watch(leaderboardCategoriesProvider);

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
      ),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text('排行榜', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: AppColors.onScaffold(context))),
        ),
        body: categoriesAsync.when(
          loading: () => Center(child: CircularProgressIndicator(color: AppColors.accentOf(context))),
          error: (e, _) => Center(child: Text('加载失败: $e', style: TextStyle(color: AppColors.mutedText(context)))),
          data: (categories) {
            if (categories.isEmpty) {
              return Center(child: Text('暂无排行榜数据', style: TextStyle(color: AppColors.mutedText(context))));
            }
            return ListView.builder(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              itemCount: categories.length,
              itemBuilder: (context, index) {
                final category = categories[index];
                return _buildCategoryCard(context, ref, category);
              },
            );
          },
        ),
      ),
    );
  }

  Widget _buildCategoryCard(BuildContext context, WidgetRef ref, LeaderboardCategory category) {
    return Container(
      margin: EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppColors.fill(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.cardBorder(context)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => LeaderboardDetailScreen(category: category)),
        ),
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [AppColors.accentOf(context).withAlpha(80), AppColors.accentOf(context).withAlpha(30)]),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.trending_up, color: AppColors.accentOf(context), size: 24),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(category.name, style: TextStyle(color: AppColors.onScaffold(context), fontSize: 16, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text('${category.platform?.toUpperCase() ?? ""} 排行榜', style: TextStyle(color: AppColors.mutedText(context), fontSize: 12)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: AppColors.mutedText(context)),
            ],
          ),
        ),
      ),
    );
  }
}

class LeaderboardDetailScreen extends ConsumerWidget {
  final LeaderboardCategory category;
  const LeaderboardDetailScreen({super.key, required this.category});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final songsAsync = ref.watch(leaderboardSongsProvider(category.id));

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
      ),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text(category.name, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.onScaffold(context))),
        ),
        body: songsAsync.when(
          loading: () => Center(child: CircularProgressIndicator(color: AppColors.accentOf(context))),
          error: (e, _) => Center(child: Text('加载失败: $e', style: TextStyle(color: AppColors.mutedText(context)))),
          data: (songs) {
            if (songs.isEmpty) {
              return Center(child: Text('暂无歌曲数据', style: TextStyle(color: AppColors.mutedText(context))));
            }
            return ListView.builder(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              itemCount: songs.length,
              itemBuilder: (context, index) => _buildSongItem(context, ref, songs[index], index, category.id),
            );
          },
        ),
      ),
    );
  }

  Widget _buildSongItem(BuildContext context, WidgetRef ref, MusicItem song, int index, String leaderboardId) {
    final playerService = ref.read(playerServiceProvider);
    final currentMusic = ref.watch(currentMusicProvider);
    final isPlaying = currentMusic?.id == song.id;

    return Container(
      margin: EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          final songsAsync = ref.read(leaderboardSongsProvider(leaderboardId));
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
                    color: index < 3 ? AppColors.accentOf(context) : AppColors.mutedText(context),
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
                      ? Image.network(song.artwork!, fit: BoxFit.cover, errorBuilder: (_, __, ___) => Icon(Icons.music_note, color: AppColors.mutedText(context), size: 20))
                      : Icon(Icons.music_note, color: AppColors.mutedText(context), size: 20),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(song.name, style: TextStyle(color: isPlaying ? AppColors.accentOf(context) : AppColors.onScaffold(context), fontSize: 14, fontWeight: FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(song.singer, style: TextStyle(color: AppColors.mutedText(context), fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
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

/// 通过 ID 和名称显示的排行榜详情页（用于路由）
class LeaderboardDetailScreenById extends ConsumerWidget {
  final String id;
  final String name;
  const LeaderboardDetailScreenById({super.key, required this.id, required this.name});

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
          title: Text(name, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.onScaffold(context))),
        ),
        body: songsAsync.when(
          loading: () => Center(child: CircularProgressIndicator(color: AppColors.accentOf(context))),
          error: (e, _) => Center(child: Text('加载失败: $e', style: TextStyle(color: AppColors.mutedText(context)))),
          data: (songs) {
            if (songs.isEmpty) {
              return Center(child: Text('暂无歌曲数据', style: TextStyle(color: AppColors.mutedText(context))));
            }
            return ListView.builder(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              itemCount: songs.length,
              itemBuilder: (context, index) => _buildSongItem(context, ref, songs[index], index),
            );
          },
        ),
      ),
    );
  }

  Widget _buildSongItem(BuildContext context, WidgetRef ref, MusicItem song, int index) {
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
                    color: index < 3 ? AppColors.accentOf(context) : AppColors.mutedText(context),
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
                      ? Image.network(song.artwork!, fit: BoxFit.cover, errorBuilder: (_, __, ___) => Icon(Icons.music_note, color: AppColors.mutedText(context), size: 20))
                      : Icon(Icons.music_note, color: AppColors.mutedText(context), size: 20),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(song.name, style: TextStyle(color: isPlaying ? AppColors.accentOf(context) : AppColors.onScaffold(context), fontSize: 14, fontWeight: FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(song.singer, style: TextStyle(color: AppColors.mutedText(context), fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
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
