import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_colors.dart';
import '../../player/presentation/player_provider.dart';
import '../domain/download_task.dart';
import 'download_provider.dart';

class DownloadScreen extends ConsumerStatefulWidget {
  const DownloadScreen({super.key});

  @override
  ConsumerState<DownloadScreen> createState() => _DownloadScreenState();
}

class _DownloadScreenState extends ConsumerState<DownloadScreen> {
  Timer? _refreshTimer;
  int _tabIndex = 0; // 0: 进行中, 1: 已完成, 2: 全部

  @override
  void initState() {
    super.initState();
    _refreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final tasks = ref.read(downloadTasksProvider);
      if (tasks.any((t) =>
          t.status == DownloadStatus.downloading ||
          t.status == DownloadStatus.pending)) {
        ref.read(downloadVersionProvider.notifier).state++;
      }
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  List<DownloadTask> _filterTasks(List<DownloadTask> tasks) {
    switch (_tabIndex) {
      case 0:
        return tasks
            .where((t) => t.status != DownloadStatus.completed)
            .toList();
      case 1:
        return tasks
            .where((t) => t.status == DownloadStatus.completed)
            .toList();
      default:
        return tasks;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tasks = ref.watch(downloadTasksProvider);
    final filtered = _filterTasks(tasks);

    final completedCount =
        tasks.where((t) => t.status == DownloadStatus.completed).length;
    final totalCount = tasks.length;
    final activeTasks =
        tasks.where((t) => t.status == DownloadStatus.downloading);
    final totalSpeed = activeTasks.fold<int>(0, (sum, t) => sum + t.speed);
    final totalDownloaded = tasks
        .where((t) => t.status == DownloadStatus.completed)
        .fold<int>(0, (sum, t) => sum + t.fileSize);
    final overallProgress = totalCount > 0 ? completedCount / totalCount : 0.0;

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
      ),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text('下载管理',
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: AppColors.onScaffold(context))),
          actions: [
            PopupMenuButton<String>(
              popUpAnimationStyle: AnimationStyle.noAnimation,
              icon: Icon(Icons.more_vert,
                  color: AppColors.secondaryText(context)),
              color: AppColors.card(context),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              onSelected: (value) {
                if (value == 'pause_all') _pauseAll(ref);
                if (value == 'clear_completed') _clearCompleted(context, ref);
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                    value: 'pause_all',
                    child: Text('暂停全部',
                        style:
                            TextStyle(color: AppColors.onScaffold(context)))),
                PopupMenuItem(
                    value: 'clear_completed',
                    child: Text('清理已完成',
                        style: TextStyle(color: AppColors.error))),
              ],
            ),
          ],
        ),
        body: tasks.isEmpty
            ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.download_done,
                        size: 64, color: AppColors.mutedText(context)),
                    const SizedBox(height: 16),
                    Text('暂无下载任务',
                        style: TextStyle(
                            color: AppColors.mutedText(context), fontSize: 16)),
                  ],
                ),
              )
            : Column(
                children: [
                  // 汇总进度卡片
                  _buildProgressCard(completedCount, totalCount,
                      overallProgress, totalSpeed, totalDownloaded),
                  const SizedBox(height: 12),
                  // Tab 栏
                  _buildTabs(completedCount, totalCount),
                  const SizedBox(height: 4),
                  // 列表
                  Expanded(
                    child: filtered.isEmpty
                        ? Center(
                            child: Text('暂无任务',
                                style: TextStyle(
                                    color: AppColors.mutedText(context),
                                    fontSize: 14)))
                        : ListView.builder(
                            padding: EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            itemCount: filtered.length,
                            itemBuilder: (context, index) =>
                                _buildTaskItem(context, ref, filtered[index]),
                          ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildProgressCard(
      int completed, int total, double progress, int speed, int downloaded) {
    return Container(
      margin: EdgeInsets.symmetric(horizontal: 16),
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.fill(context),
        border: Border.all(color: AppColors.cardBorder(context)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题行
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('$completed / $total 已完成',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppColors.onScaffold(context))),
              Text('${(progress * 100).toStringAsFixed(0)}%',
                  style: TextStyle(
                      fontSize: 11, color: AppColors.mutedText(context))),
            ],
          ),
          const SizedBox(height: 12),
          // 速度/时间/大小
          Row(
            children: [
              _buildStatItem(_formatSpeed(speed), '下载速度'),
              const SizedBox(width: 24),
              _buildStatItem(_formatSize(downloaded), '已下载'),
              const SizedBox(width: 24),
              _buildStatItem('$completed 首', '已完成'),
            ],
          ),
          const SizedBox(height: 12),
          // 进度条
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: progress,
              backgroundColor: AppColors.fill2(context),
              valueColor:
                  AlwaysStoppedAnimation<Color>(AppColors.accentOf(context)),
              minHeight: 6,
            ),
          ),
          const SizedBox(height: 12),
          // 操作按钮
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 34,
                  child: TextButton.icon(
                    onPressed: () => _pauseAll(ref),
                    style: TextButton.styleFrom(
                      backgroundColor: AppColors.fill2(context),
                      foregroundColor: AppColors.secondaryText(context),
                      side: BorderSide(color: AppColors.cardBorder(context)),
                      shape: const StadiumBorder(),
                      padding: EdgeInsets.zero,
                    ),
                    icon: Icon(Icons.pause,
                        size: 14, color: AppColors.secondaryText(context)),
                    label: Text('暂停全部',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: AppColors.secondaryText(context))),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SizedBox(
                  height: 34,
                  child: TextButton(
                    onPressed: () => _clearCompleted(context, ref),
                    style: TextButton.styleFrom(
                      backgroundColor: AppColors.error.withAlpha(13),
                      foregroundColor: AppColors.error,
                      side: BorderSide(color: AppColors.error.withAlpha(51)),
                      shape: const StadiumBorder(),
                      padding: EdgeInsets.zero,
                    ),
                    child: Text('清理已完成',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: AppColors.error)),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem(String value, String label) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value,
            style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppColors.onScaffold(context),
                fontFeatures: [FontFeature.tabularFigures()])),
        const SizedBox(height: 2),
        Text(label,
            style: TextStyle(
                fontSize: 10,
                color: AppColors.mutedText(context),
                letterSpacing: 0.06)),
      ],
    );
  }

  Widget _buildTabs(int completedCount, int totalCount) {
    final activeCount = totalCount - completedCount;
    final tabs = ['进行中 ($activeCount)', '已完成 ($completedCount)', '全部'];
    return Container(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 10),
      decoration: BoxDecoration(
        border:
            Border(bottom: BorderSide(color: AppColors.cardBorder(context))),
      ),
      child: Row(
        children: List.generate(tabs.length, (i) {
          final isActive = _tabIndex == i;
          return Expanded(
            child: Semantics(
              button: true,
              selected: isActive,
              child: InkWell(
                onTap: () => setState(() => _tabIndex = i),
                borderRadius: BorderRadius.circular(999),
                child: Container(
                  height: 34,
                  decoration: BoxDecoration(
                    color: isActive
                        ? AppColors.accentOf(context).withAlpha(51)
                        : Colors.transparent,
                    border: isActive
                        ? Border.all(
                            color: AppColors.accentOf(context).withAlpha(77))
                        : null,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    tabs[i],
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                      color: isActive
                          ? AppColors.accentOf(context)
                          : AppColors.secondaryText(context),
                    ),
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildTaskItem(
      BuildContext context, WidgetRef ref, DownloadTask task) {
    final isDownloading = task.status == DownloadStatus.downloading;
    final isFailed = task.status == DownloadStatus.failed;

    return InkWell(
      onTap: task.status == DownloadStatus.completed
          ? () => _playDownloaded(ref, task)
          : null,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: isDownloading ? AppColors.fill(context) : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            // 缩略图
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: _getThumbColor(task),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.cardBorder(context)),
              ),
              child: Icon(Icons.music_note,
                  color: Colors.white.withAlpha(150), size: 20),
            ),
            const SizedBox(width: 12),
            // 信息
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    task.name,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: isFailed
                          ? AppColors.error
                          : AppColors.onScaffold(context),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _buildMetaText(task),
                    style: TextStyle(
                      fontSize: 11,
                      color: isFailed
                          ? AppColors.error
                          : AppColors.mutedText(context),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  // 下载进度条
                  if (isDownloading ||
                      task.status == DownloadStatus.paused) ...[
                    const SizedBox(height: 5),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(1),
                      child: LinearProgressIndicator(
                        value: task.progress,
                        backgroundColor: AppColors.border,
                        valueColor: const AlwaysStoppedAnimation<Color>(
                            AppColors.amber),
                        minHeight: 2,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            // 右侧状态
            _buildStatusWidget(context, ref, task),
          ],
        ),
      ),
    );
  }

  String _buildMetaText(DownloadTask task) {
    final quality = task.quality?.toUpperCase() ?? '';
    switch (task.status) {
      case DownloadStatus.completed:
        final parts = [task.singer];
        if (quality.isNotEmpty) parts.add(quality);
        if (task.fileSize > 0) parts.add(_formatSize(task.fileSize));
        return parts.join(' · ');
      case DownloadStatus.downloading:
        final parts = [task.singer];
        if (quality.isNotEmpty) parts.add(quality);
        parts.add('下载中 ${(task.progress * 100).toStringAsFixed(0)}%');
        return parts.join(' · ');
      case DownloadStatus.paused:
        return '${task.singer} · 已暂停 ${(task.progress * 100).toStringAsFixed(0)}%';
      case DownloadStatus.pending:
        final parts = [task.singer];
        if (quality.isNotEmpty) parts.add(quality);
        parts.add('等待中');
        return parts.join(' · ');
      case DownloadStatus.failed:
        return task.errorMsg ?? '链接失效，下载失败';
    }
  }

  Widget _buildStatusWidget(
      BuildContext context, WidgetRef ref, DownloadTask task) {
    final action = ref.read(downloadActionProvider);
    switch (task.status) {
      case DownloadStatus.completed:
        return Icon(Icons.check_circle, color: AppColors.success, size: 18);
      case DownloadStatus.downloading:
        return SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            value: task.progress,
            strokeWidth: 2,
            color: AppColors.amber,
          ),
        );
      case DownloadStatus.paused:
        return IconButton(
          icon: Icon(Icons.play_circle_filled,
              color: AppColors.success, size: 20),
          onPressed: () => action('resume', task.id),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
        );
      case DownloadStatus.pending:
        return Icon(Icons.circle_outlined,
            color: AppColors.mutedText(context), size: 18);
      case DownloadStatus.failed:
        return TextButton(
          onPressed: () => action('retry', task.id),
          style: TextButton.styleFrom(
            padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            side: BorderSide(color: AppColors.accentOf(context).withAlpha(77)),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
            foregroundColor: AppColors.accentOf(context),
          ),
          child: Text('重试',
              style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: AppColors.accentOf(context))),
        );
    }
  }

  Color _getThumbColor(DownloadTask task) {
    // 根据任务名 hash 生成不同颜色
    final hash = task.name.hashCode.abs();
    final colors = [
      const Color(0xFF6B3FA0),
      const Color(0xFF1A8A8A),
      const Color(0xFF9B3060),
      const Color(0xFF2355C0),
      const Color(0xFFB06030),
      const Color(0xFF1A7A4A),
      const Color(0xFF3B2F8A),
      const Color(0xFFA03070),
    ];
    return colors[hash % colors.length];
  }

  void _playDownloaded(WidgetRef ref, DownloadTask task) {
    if (task.savePath == null) return;
    final tasks = ref.read(downloadTasksProvider);
    final completedTasks = tasks
        .where(
            (t) => t.status == DownloadStatus.completed && t.savePath != null)
        .toList();
    final items = completedTasks.map((t) {
      final uri = t.savePath!.startsWith('file://')
          ? t.savePath!
          : 'file://${t.savePath!}';
      return t.toMusicItem().copyWith(url: uri);
    }).toList();

    final currentIndex = completedTasks.indexWhere((t) => t.id == task.id);
    ref.read(playerServiceProvider).setQueue(items,
        startIndex: currentIndex >= 0 ? currentIndex : 0,
        manualPlayName: currentIndex >= 0 ? items[currentIndex].name : null);
  }

  void _pauseAll(WidgetRef ref) {
    final action = ref.read(downloadActionProvider);
    final tasks = ref.read(downloadTasksProvider);
    for (final task in tasks) {
      if (task.status == DownloadStatus.downloading ||
          task.status == DownloadStatus.pending) {
        action('pause', task.id);
      }
    }
  }

  void _clearCompleted(BuildContext context, WidgetRef ref) {
    final tasks = ref.read(downloadTasksProvider);
    final completed =
        tasks.where((t) => t.status == DownloadStatus.completed).toList();
    if (completed.isEmpty) return;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.dialogBg(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('清理已完成',
            style: TextStyle(color: AppColors.onScaffold(context))),
        content: Text('确定要清理 ${completed.length} 个已完成的下载记录吗？',
            style: TextStyle(color: AppColors.mutedText(context))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('取消',
                  style: TextStyle(color: AppColors.mutedText(context)))),
          TextButton(
            onPressed: () {
              final action = ref.read(downloadActionProvider);
              for (final task in completed) {
                action('delete', task.id);
              }
              Navigator.pop(ctx);
            },
            child: Text('清理', style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );
  }

  String _formatSpeed(int bytesPerSecond) {
    if (bytesPerSecond <= 0) return '0 B/s';
    if (bytesPerSecond < 1024) return '$bytesPerSecond B/s';
    if (bytesPerSecond < 1024 * 1024) {
      return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
    }
    return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }

  String _formatSize(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
