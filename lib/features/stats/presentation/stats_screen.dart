import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../data/play_history_store.dart';
import 'play_history_provider.dart';

class StatsScreen extends ConsumerStatefulWidget {
  const StatsScreen({super.key});

  @override
  ConsumerState<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends ConsumerState<StatsScreen> {
  StatsRange _range = StatsRange.week;
  int _tab = 0;
  StreamSubscription<int>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = ref.read(playHistoryStoreProvider).stream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = ref.read(playHistoryStoreProvider);
    final summary = store.summary(_range);
    final heatmap = store.dailyPlayCounts(_range);
    final topSongs = store.topSongs(_range);
    final topArtists = store.topArtists(_range);
    final topAlbums = store.topAlbums(_range);

    return Scaffold(
      backgroundColor: AppColors.scaffold(context),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(
          '听歌统计',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: AppColors.onScaffold(context),
          ),
        ),
      ),
      body: SafeArea(
        top: false,
        child: store.entries.isEmpty
            ? _buildEmpty(context)
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _buildRangeSelector(),
                  const SizedBox(height: 14),
                  _buildSummaryCards(summary),
                  const SizedBox(height: 16),
                  _buildHeatmap(heatmap),
                  const SizedBox(height: 16),
                  _buildTopSection(context, topSongs, topArtists, topAlbums),
                  const SizedBox(height: 24),
                ],
              ),
      ),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.bar_chart, size: 56, color: AppColors.mutedText(context)),
          const SizedBox(height: 12),
          Text('暂无播放数据',
              style:
                  TextStyle(color: AppColors.mutedText(context), fontSize: 14)),
          const SizedBox(height: 4),
          Text('多听几首歌，这里会生成你的听歌报告',
              style:
                  TextStyle(color: AppColors.mutedText(context), fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildRangeSelector() {
    return Row(
      children: [
        for (final range in StatsRange.values) ...[
          if (range != StatsRange.values.first) const SizedBox(width: 8),
          Expanded(
            child: ChoiceChip(
              label: Text(range.label, style: TextStyle(fontSize: 13)),
              selected: _range == range,
              onSelected: (_) => setState(() => _range = range),
              selectedColor: Theme.of(context).colorScheme.primaryContainer,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildSummaryCards(
      ({
        int totalPlays,
        double totalSec,
        int activeDays,
        int uniqueSongs
      }) summary) {
    return Row(
      children: [
        _summaryCard('播放次数', '${summary.totalPlays}'),
        const SizedBox(width: 10),
        _summaryCard('听歌时长', _fmtDuration(summary.totalSec)),
        const SizedBox(width: 10),
        _summaryCard('活跃天数', '${summary.activeDays}'),
        const SizedBox(width: 10),
        _summaryCard('单曲数', '${summary.uniqueSongs}'),
      ],
    );
  }

  Widget _summaryCard(String label, String value) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.card(context),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.cardBorder(context)),
        ),
        child: Column(
          children: [
            Text(value,
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppColors.onScaffold(context))),
            const SizedBox(height: 2),
            Text(label,
                style: TextStyle(
                    fontSize: 10, color: AppColors.mutedText(context))),
          ],
        ),
      ),
    );
  }

  Widget _buildHeatmap(List<(DateTime, int)> days) {
    if (days.isEmpty) return const SizedBox.shrink();
    final maxCount =
        days.map((d) => d.$2).reduce((a, b) => a > b ? a : b).clamp(1, 1 << 30);
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
          Text('每日播放',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.onScaffold(context))),
          const SizedBox(height: 10),
          SizedBox(
            height: 56,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final (_, count) in days)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 1.5),
                      child: Container(
                        decoration: BoxDecoration(
                          color: count == 0
                              ? AppColors.fill(context)
                              : AppColors.accentOf(context).withValues(
                                  alpha: 0.35 + 0.65 * (count / maxCount)),
                          borderRadius: BorderRadius.vertical(
                            top: Radius.circular(3),
                          ),
                        ),
                        height: count == 0 ? 4 : 8 + 44 * (count / maxCount),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '${days.length} 天 · 峰值 $maxCount 次',
            style: TextStyle(fontSize: 10, color: AppColors.mutedText(context)),
          ),
        ],
      ),
    );
  }

  Widget _buildTopSection(
    BuildContext context,
    List<RankedItem> songs,
    List<RankedItem> artists,
    List<RankedItem> albums,
  ) {
    final items = switch (_tab) {
      0 => songs,
      1 => artists,
      _ => albums,
    };
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.card(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.cardBorder(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
            child: Row(
              children: [
                Text('TOP',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: AppColors.onScaffold(context))),
                const Spacer(),
                for (final (index, label) in const [
                  (0, '歌曲'),
                  (1, '艺术家'),
                  (2, '专辑')
                ]) ...[
                  if (index != 0) const SizedBox(width: 6),
                  ChoiceChip(
                    label: Text(label, style: const TextStyle(fontSize: 11)),
                    selected: _tab == index,
                    onSelected: (_) => setState(() => _tab = index),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ],
            ),
          ),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('暂无数据',
                  style: TextStyle(
                      fontSize: 12, color: AppColors.mutedText(context))),
            )
          else
            for (final (index, item) in items.indexed)
              ListTile(
                dense: true,
                leading: SizedBox(
                  width: 24,
                  child: Text('${index + 1}',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: index < 3
                              ? AppColors.accentOf(context)
                              : AppColors.mutedText(context))),
                ),
                title: Text(item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 13, color: AppColors.onScaffold(context))),
                subtitle: Text(
                  '${item.subtitle} · ${item.playCount}次',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11, color: AppColors.mutedText(context)),
                ),
              ),
        ],
      ),
    );
  }

  String _fmtDuration(double seconds) {
    final totalMinutes = (seconds / 60).round();
    if (totalMinutes < 60) return '$totalMinutes 分';
    final hours = totalMinutes ~/ 60;
    final minutes = totalMinutes % 60;
    return '$hours 时 $minutes 分';
  }
}
