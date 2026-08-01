import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../player/presentation/player_provider.dart';
import '../domain/smart_playlist.dart';
import 'smart_playlist_edit_screen.dart';
import 'smart_playlist_provider.dart';

class SmartPlaylistListScreen extends ConsumerWidget {
  const SmartPlaylistListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(smartPlaylistControllerProvider);
    final playProvider = ref.read(playerServiceProvider);

    return Scaffold(
      backgroundColor: AppColors.scaffold(context),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text('智能歌单',
            style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: AppColors.onScaffold(context))),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () async {
              final name = await _promptName(context);
              if (name == null || name.trim().isEmpty) return;
              final smart = await ref
                  .read(smartPlaylistControllerProvider.notifier)
                  .create(name.trim());
              if (!context.mounted) return;
              _edit(context, ref, smart);
            },
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: list.isEmpty
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.auto_awesome,
                        size: 56, color: AppColors.mutedText(context)),
                    const SizedBox(height: 12),
                    Text('还没有智能歌单',
                        style: TextStyle(
                            color: AppColors.mutedText(context),
                            fontSize: 14)),
                    const SizedBox(height: 4),
                    Text('点击右上角 + 创建',
                        style: TextStyle(
                            color: AppColors.mutedText(context),
                            fontSize: 12)),
                  ],
                ),
              )
            : ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: list.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final smart = list[index];
                  final results = ref.watch(smartPlaylistResultsProvider(smart.id));
                  return InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () {
                      if (results.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('当前没有命中的歌曲')),
                        );
                        return;
                      }
                      playProvider.playPlaylist(results, index: 0);
                    },
                    onLongPress: () =>
                        _edit(context, ref, smart),
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppColors.card(context),
                        borderRadius: BorderRadius.circular(16),
                        border:
                            Border.all(color: AppColors.cardBorder(context)),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: AppColors.accentOf(context)
                                  .withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(Icons.auto_awesome,
                                size: 22,
                                color: AppColors.accentOf(context)),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(smart.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                        color: AppColors.onScaffold(context))),
                                const SizedBox(height: 2),
                                Text(
                                  smart.hasRules
                                      ? '${_ruleCount(smart)} 条规则 · 命中 ${results.length} 首'
                                      : '未设置规则 · 命中全部 ${results.length} 首',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: AppColors.mutedText(context)),
                                ),
                              ],
                            ),
                          ),
                           IconButton(
                             tooltip: '编辑规则',
                             icon: Icon(
                               Icons.tune,
                               size: 20,
                               color: AppColors.secondaryText(context),
                             ),
                             onPressed: () => _edit(context, ref, smart),
                           ),
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }

  int _ruleCount(SmartPlaylist smart) =>
      smart.groups.fold(0, (s, g) => s + g.rules.length);

  Future<String?> _promptName(BuildContext context) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.dialogBg(context),
        title: const Text('新建智能歌单'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '歌单名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('创建'),
          ),
        ],
      ),
    );
  }

  void _edit(BuildContext context, WidgetRef ref, SmartPlaylist smart) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SmartPlaylistEditScreen(smart: smart),
      ),
    );
  }
}
