import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../player/presentation/player_provider.dart';
import 'recommendation_provider.dart';

const Color kRecommendColor = Color(0xFFFF8F1F);

class RecommendationScreen extends ConsumerWidget {
  const RecommendationScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recommendations = ref.watch(recommendationProvider);
    final playProvider = ref.read(playerServiceProvider);

    return Scaffold(
      backgroundColor: AppColors.scaffold(context),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text('猜你喜欢',
            style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: AppColors.onScaffold(context))),
      ),
      body: SafeArea(
        top: false,
        child: recommendations.isEmpty
            ? _buildEmpty(context)
            : Column(
                children: [
                  _buildHeader(context, recommendations.length),
                  Expanded(
                    child: ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                      itemCount: recommendations.length,
                      separatorBuilder: (_, __) =>
                          const SizedBox(height: 4),
                      itemBuilder: (context, index) {
                        final rec = recommendations[index];
                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          leading: SizedBox(
                            width: 28,
                            child: Text(
                              '${index + 1}',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                                color: index < 3
                                    ? kRecommendColor
                                    : AppColors.mutedText(context),
                              ),
                            ),
                          ),
                          title: Text(
                            rec.song.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 14,
                                color: AppColors.onScaffold(context)),
                          ),
                          subtitle: Text(
                            rec.reasons.isEmpty
                                ? rec.song.singer
                                : '${rec.song.singer} · ${rec.reasons.join('、')}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 11,
                                color: AppColors.mutedText(context)),
                          ),
                          trailing: IconButton(
                            icon: Icon(Icons.play_circle_outline,
                                size: 24, color: kRecommendColor),
                            onPressed: () => playProvider.playPlaylist(
                              recommendations.map((r) => r.song).toList(),
                              index: index,
                            ),
                          ),
                          onTap: () => playProvider.playPlaylist(
                            recommendations.map((r) => r.song).toList(),
                            index: index,
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, int count) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [kRecommendColor, Color(0xFFFFB35C)],
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: Colors.white.withAlpha(40),
              borderRadius: BorderRadius.circular(12),
            ),
            child:
                const Icon(Icons.auto_awesome, color: Colors.white, size: 24),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('根据你喜欢的音乐推荐',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 3),
                Text('推荐 $count 首 · 持续更新',
                    style: TextStyle(
                        color: Colors.white.withAlpha(200), fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_awesome, size: 56, color: kRecommendColor),
          const SizedBox(height: 12),
          Text('还没有推荐',
              style: TextStyle(
                  color: AppColors.mutedText(context), fontSize: 14)),
          const SizedBox(height: 4),
          Text('“我喜欢的音乐”满 100 首后，将随机取样推荐 30 首歌曲',
              style: TextStyle(
                  color: AppColors.mutedText(context), fontSize: 12)),
        ],
      ),
    );
  }
}
