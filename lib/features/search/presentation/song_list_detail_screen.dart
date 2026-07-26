import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_colors.dart';
import '../../player/domain/music_item.dart';
import '../../player/presentation/player_provider.dart';
import '../../search/presentation/search_provider.dart';

class SongListDetailScreen extends ConsumerStatefulWidget {
  final MusicItem songList;
  const SongListDetailScreen({super.key, required this.songList});

  @override
  ConsumerState<SongListDetailScreen> createState() => _SongListDetailScreenState();
}

class _SongListDetailScreenState extends ConsumerState<SongListDetailScreen> {
  final List<MusicItem> _songs = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadDetail();
  }

  Future<void> _loadDetail() async {
    try {
      final musicSourceService = ref.read(musicSourceServiceProvider);
      final platform = widget.songList.platform.isNotEmpty ? widget.songList.platform : widget.songList.source;
      final songs = await musicSourceService.getSongListDetail(platform, widget.songList.id);
      if (mounted) {
        setState(() { _songs.addAll(songs); _isLoading = false; });
      }
    } catch (e) {
      if (mounted) {
        setState(() { _error = e.toString(); _isLoading = false; });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text(widget.songList.name, style: TextStyle(color: AppColors.onScaffold(context), fontSize: 18)),
          leading: IconButton(
            icon: Icon(Icons.arrow_back, color: AppColors.onScaffold(context)),
            onPressed: () => Navigator.pop(context),
          ),
          actions: [
            if (_songs.isNotEmpty)
              TextButton.icon(
                onPressed: () {
                  final playerService = ref.read(playerServiceProvider);
                  playerService.setQueue(_songs, startIndex: 0);
                },
                icon: Icon(Icons.play_arrow, color: AppColors.amber, size: 20),
                label: const Text('播放全部', style: TextStyle(color: AppColors.amber, fontSize: 13)),
              ),
          ],
        ),
        body: _isLoading
            ? const Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation<Color>(AppColors.amber))))
            : _error != null
                ? Center(child: Text('加载失败: $_error', style: TextStyle(color: AppColors.error)))
                : _songs.isEmpty
                    ? Center(child: Text('歌单为空', style: TextStyle(color: AppColors.mutedText(context))))
                    : ListView.builder(
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        itemCount: _songs.length,
                        itemBuilder: (context, index) {
                          final song = _songs[index];
                          final currentMusic = ref.watch(currentMusicProvider);
                          final isPlaying = currentMusic?.id == song.id;

                          return Container(
                            margin: EdgeInsets.only(bottom: 8),
                            decoration: BoxDecoration(
                              color: AppColors.fill(context),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: AppColors.cardBorder(context)),
                            ),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(12),
                              onTap: () {
                                final playerService = ref.read(playerServiceProvider);
                                playerService.setQueue(_songs, startIndex: index);
                              },
                              child: Padding(
                                padding: EdgeInsets.all(12),
                                child: Row(
                                  children: [
                                    SizedBox(
                                      width: 28,
                                      child: Text(
                                        '${index + 1}',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          color: isPlaying ? AppColors.amber : AppColors.textMuted,
                                          fontSize: 13,
                                          fontWeight: isPlaying ? FontWeight.bold : FontWeight.normal,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(4),
                                      child: song.artwork != null && song.artwork!.isNotEmpty
                                          ? Image.network(song.artwork!, width: 40, height: 40, fit: BoxFit.cover, errorBuilder: (_, __, ___) => _placeholder())
                                          : _placeholder(),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(song.name, style: TextStyle(color: isPlaying ? AppColors.amber : AppColors.textPrimary, fontSize: 14), maxLines: 1, overflow: TextOverflow.ellipsis),
                                          const SizedBox(height: 4),
                                          Text('${song.singer} · ${song.album}', style: TextStyle(color: AppColors.mutedText(context), fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
      ),
    );
  }

  Widget _placeholder() {
    return Container(
      width: 40,
      height: 40,
      color: AppColors.cardAlt(context),
      child: Icon(Icons.music_note, color: AppColors.mutedText(context), size: 20),
    );
  }
}
