import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import '../../../core/io/bounded_input.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/storage/storage_service.dart';
import 'settings_provider.dart';
import '../../equalizer/presentation/equalizer_provider.dart';
import '../../download/presentation/download_provider.dart';
import '../../search/presentation/search_provider.dart';
import '../../playlist/data/playlist_repository.dart';
import '../../playlist/presentation/playlist_provider.dart';
import '../domain/playlist_backup.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final audioQuality = ref.watch(audioQualityProvider);

    final isDark = themeMode == ThemeMode.dark ||
        (themeMode == ThemeMode.system &&
            MediaQuery.platformBrightnessOf(context) == Brightness.dark);

    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: 0,
          elevation: 0,
          title: Text(
            '设置',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
        body: ListView(
          children: [
            _buildSection(context, '外观', [
              _buildSwitchTile(
                context,
                ref,
                '深色模式',
                '使用深色主题',
                isDark && themeMode != ThemeMode.system,
                (value) {
                  // 关闭「跟随系统」后，按开关设置深/浅色
                  ref
                      .read(themeModeProvider.notifier)
                      .setThemeMode(value ? ThemeMode.dark : ThemeMode.light);
                },
              ),
              _buildSwitchTile(
                context,
                ref,
                '跟随系统',
                '自动切换亮色/深色主题',
                themeMode == ThemeMode.system,
                (value) {
                  if (value) {
                    ref
                        .read(themeModeProvider.notifier)
                        .setThemeMode(ThemeMode.system);
                  } else {
                    // 退出跟随时，保持当前实际明暗
                    final darkNow = MediaQuery.platformBrightnessOf(context) ==
                        Brightness.dark;
                    ref.read(themeModeProvider.notifier).setThemeMode(
                          darkNow ? ThemeMode.dark : ThemeMode.light,
                        );
                  }
                },
              ),
            ]),
            _buildSection(context, '播放', [
              _buildNavTile(
                context,
                ref,
                '音质选择',
                _getQualityName(audioQuality),
                () => _showAudioQualityDialog(context, ref),
              ),
              _buildNavTile(
                context,
                ref,
                '默认搜索平台',
                _platformName(ref.watch(defaultSearchPlatformProvider)),
                () => _showDefaultPlatformDialog(context, ref),
              ),
              _buildNavTile(
                context,
                ref,
                '均衡器',
                ref.watch(equalizerProvider).preset.label,
                () => context.push('/equalizer'),
              ),
            ]),
            _buildSection(context, '下载', [
              _buildNavTile(
                context,
                ref,
                '下载管理',
                '查看和管理下载任务',
                () => context.push('/download'),
              ),
              _buildSwitchTile(
                context,
                ref,
                '仅 WiFi 下载',
                '仅在 WiFi 环境下下载歌曲',
                ref.watch(wifiOnlyDownloadProvider),
                (value) {
                  ref
                      .read(wifiOnlyDownloadProvider.notifier)
                      .setWifiOnly(value);
                },
              ),
              _buildNavTile(
                context,
                ref,
                '下载音质',
                _getQualityName(ref.watch(downloadQualityProvider)),
                () => _showDownloadQualityDialog(context, ref),
              ),
            ]),
            _buildSection(context, '高级功能', [
              _buildNavTile(
                context,
                ref,
                '自定义源',
                '管理自定义音乐源',
                () => context.push('/custom-source'),
              ),
            ]),
            _buildSection(context, '同步', [
              _buildNavTile(
                context,
                ref,
                '云端账号 / 歌单',
                'Workers 登录、同步云端歌单',
                () => context.push('/sync'),
              ),
            ]),
            _buildSection(context, '数据', [
              _buildNavTile(
                context,
                ref,
                '备份数据',
                '导出歌单、设置等数据到文件',
                () => _backupData(context, ref),
              ),
              _buildNavTile(
                context,
                ref,
                '恢复数据',
                '从备份文件恢复数据',
                () => _restoreData(context, ref),
              ),
              _buildNavTile(
                context,
                ref,
                '清除缓存',
                '清除下载缓存和临时文件',
                () => _clearCache(context),
              ),
            ]),
            _buildSection(context, '关于', [
              const _SettingRow(
                icon: Icons.info_outline,
                name: '版本',
                value: '1.0.0',
              ),
              _buildNavTile(context, ref, '开源许可', '', () {
                final theme = Theme.of(context);
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (ctx) => Theme(
                      data: theme,
                      child: LicensePage(
                        applicationName: 'LX Music',
                        applicationVersion: '1.0.0',
                      ),
                    ),
                  ),
                );
              }),
            ]),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _buildSection(
    BuildContext context,
    String title,
    List<Widget> children,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(16, 20, 16, 8),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
              color: AppColors.mutedText(context),
            ),
          ),
        ),
        Container(
          margin: EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: AppColors.fill(context),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.cardBorder(context)),
          ),
          child: Column(
            children: [
              for (var i = 0; i < children.length; i++) ...[
                children[i],
                if (i < children.length - 1)
                  Divider(
                    height: 1,
                    thickness: 0.5,
                    color: AppColors.cardBorder(context),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSwitchTile(
    BuildContext context,
    WidgetRef ref,
    String title,
    String subtitle,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: AppColors.onScaffold(context),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.mutedText(context),
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _buildNavTile(
    BuildContext context,
    WidgetRef ref,
    String title,
    String subtitle,
    VoidCallback onTap,
  ) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: AppColors.onScaffold(context),
                    ),
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.mutedText(context),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              color: AppColors.mutedText(context),
              size: 18,
            ),
          ],
        ),
      ),
    );
  }

  String _getQualityName(AudioQualityOption quality) {
    switch (quality) {
      case AudioQualityOption.low:
        return '标准 (128kbps)';
      case AudioQualityOption.high:
        return '超高品质 (320kbps)';
      case AudioQualityOption.lossless:
        return '无损 (FLAC)';
      case AudioQualityOption.lossless24:
        return '臻品母带 (FLAC 24bit)';
      case AudioQualityOption.hires:
        return 'Hi-Res';
    }
  }

  String _platformName(String id) {
    switch (id) {
      case 'tx':
        return '腾讯 (QQ 音乐)';
      case 'kw':
        return '酷我';
      case 'wy':
        return '网易云';
      default:
        return id;
    }
  }

  void _showDefaultPlatformDialog(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.dialogBg(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          '默认搜索平台',
          style: TextStyle(color: AppColors.onScaffold(context)),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: ['tx', 'kw', 'wy'].map((id) {
            final current = ref.watch(defaultSearchPlatformProvider);
            return ListTile(
              title: Text(
                _platformName(id),
                style: TextStyle(
                  color: current == id
                      ? AppColors.accentOf(context)
                      : AppColors.onScaffold(context),
                ),
              ),
              trailing: current == id
                  ? Icon(Icons.check, color: AppColors.accentOf(context))
                  : null,
              onTap: () {
                ref
                    .read(defaultSearchPlatformProvider.notifier)
                    .setPlatform(id);
                ref.read(selectedSourceIdProvider.notifier).state = id;
                Navigator.pop(context);
              },
            );
          }).toList(),
        ),
      ),
    );
  }

  void _showAudioQualityDialog(BuildContext context, WidgetRef ref) {
    _showQualityDialog(context, ref, '选择音质', false);
  }

  void _showDownloadQualityDialog(BuildContext context, WidgetRef ref) {
    _showQualityDialog(context, ref, '选择下载音质', true);
  }

  void _showQualityDialog(
    BuildContext context,
    WidgetRef ref,
    String title,
    bool isDownload,
  ) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.dialogBg(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          title,
          style: TextStyle(color: AppColors.onScaffold(context)),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: AudioQualityOption.values.map((quality) {
            final currentQuality = ref.watch(
              isDownload ? downloadQualityProvider : audioQualityProvider,
            );
            return ListTile(
              title: Text(
                _getQualityName(quality),
                style: TextStyle(
                  color: currentQuality == quality
                      ? AppColors.accentOf(context)
                      : AppColors.onScaffold(context),
                ),
              ),
              trailing: currentQuality == quality
                  ? Icon(Icons.check, color: AppColors.accentOf(context))
                  : null,
              onTap: () {
                if (isDownload) {
                  ref
                      .read(downloadQualityProvider.notifier)
                      .setQuality(quality);
                } else {
                  ref.read(audioQualityProvider.notifier).setQuality(quality);
                }
                Navigator.pop(context);
              },
            );
          }).toList(),
        ),
      ),
    );
  }

  Future<void> _backupData(BuildContext context, WidgetRef ref) async {
    try {
      final storage = await StorageService.instance;
      final playlists =
          await ref.read(playlistServiceProvider).getAllPlaylists();
      final playlistSnapshot = const PlaylistSnapshotCodec().encode(
        PlaylistSnapshot(schemaVersion: 1, playlists: playlists),
      );
      final backup = <String, dynamic>{
        'version': 1,
        'timestamp': DateTime.now().toIso8601String(),
        'playlists': jsonDecode(playlistSnapshot),
        'search_history': storage.getStringList('search_history'),
        'theme_mode': storage.getInt('theme_mode'),
        'audio_quality': storage.getInt('audio_quality'),
        'download_quality': storage.getInt('download_quality'),
        'wifi_only_download': storage.getBool('wifi_only_download'),
      };

      final jsonStr = const JsonEncoder.withIndent('  ').convert(backup);
      final dir = await getApplicationDocumentsDirectory();
      final file = File(
        '${dir.path}/lx_music_backup_${DateTime.now().millisecondsSinceEpoch}.json',
      );
      await file.writeAsString(jsonStr);

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('备份已保存到 ${file.path}'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('备份失败: $e'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  Future<void> _restoreData(BuildContext context, WidgetRef ref) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (result == null || result.files.isEmpty) return;

      final file = File(result.files.first.path!);
      final bytes = await readFileBytesBounded(
        file,
        maximumBytes: BackupLimits.maximumFileBytes,
      );
      final data = decodeBackup(utf8.decode(bytes, allowMalformed: false));
      await BackupRestoreCoordinator(
        storage: await StorageService.instance,
        playlists: ref.read(playlistServiceProvider),
        publishCommitted: (data) {
          ref
              .read(searchHistoryProvider.notifier)
              .applyCommitted(data.searchHistory);
          ref.read(themeModeProvider.notifier).applyCommitted(data.themeMode);
          ref
              .read(audioQualityProvider.notifier)
              .applyCommitted(data.audioQuality);
          ref
              .read(downloadQualityProvider.notifier)
              .applyCommitted(data.downloadQuality);
          ref
              .read(wifiOnlyDownloadProvider.notifier)
              .applyCommitted(data.wifiOnlyDownload);
        },
      ).restore(data);

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('数据恢复成功'),
            duration: Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('恢复失败: $e'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  Future<void> _clearCache(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.dialogBg(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          '清除缓存',
          style: TextStyle(color: AppColors.onScaffold(context)),
        ),
        content: Text(
          '确定要清除所有缓存数据吗？下载的文件不会被删除。',
          style: TextStyle(color: AppColors.secondaryText(context)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(
              '取消',
              style: TextStyle(color: AppColors.mutedText(context)),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              '确定',
              style: TextStyle(color: AppColors.accentOf(context)),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true && context.mounted) {
      try {
        final cacheDir = await getTemporaryDirectory();
        if (cacheDir.existsSync()) {
          cacheDir.deleteSync(recursive: true);
          cacheDir.createSync();
        }
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('缓存已清除'),
              duration: Duration(seconds: 2),
            ),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('清除失败: $e'), duration: Duration(seconds: 2)),
          );
        }
      }
    }
  }
}

class _SettingRow extends StatelessWidget {
  final IconData icon;
  final String name;
  final String value;

  const _SettingRow({
    required this.icon,
    required this.name,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppColors.mutedText(context)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              name,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: AppColors.onScaffold(context),
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(fontSize: 12, color: AppColors.mutedText(context)),
          ),
        ],
      ),
    );
  }
}
