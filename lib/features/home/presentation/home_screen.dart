import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/pressable.dart';
import '../../../core/music_source/platform/music_platform.dart';
import '../../leaderboard/presentation/leaderboard_provider.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final List<String> _platforms = ['tx', 'kw', 'wy'];
  final Map<String, String> _platformNames = {
    'tx': 'QQ音乐',
    'kw': '酷我音乐',
    'wy': '网易云',
  };
  int _coverRetry = 0;

  @override
  void initState() {
    super.initState();
    // 禁止左右滑动切平台（左右滑留给底部四大页）
    _tabController = TabController(length: _platforms.length, vsync: this);
  }

  void _refreshLeaderboards() {
    ref.invalidate(leaderboardCategoriesProvider);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final categoriesAsync = ref.watch(leaderboardCategoriesProvider);

    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        // 底部安全区已由 MainScaffold（底栏+迷你栏）处理，避免双重留白
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              // 平台切换：无底部分隔线/白线
              Theme(
                data: Theme.of(context).copyWith(
                  dividerColor: Colors.transparent,
                  tabBarTheme: const TabBarThemeData(
                    dividerColor: Colors.transparent,
                    dividerHeight: 0,
                    indicatorSize: TabBarIndicatorSize.label,
                  ),
                ),
                child: TabBar(
                  controller: _tabController,
                  isScrollable: false,
                  indicatorColor: scheme.primary,
                  indicatorSize: TabBarIndicatorSize.label,
                  indicatorWeight: 2.5,
                  dividerColor: Colors.transparent,
                  dividerHeight: 0,
                  overlayColor: const WidgetStatePropertyAll(Colors.transparent),
                  splashFactory: NoSplash.splashFactory,
                  labelColor: scheme.primary,
                  unselectedLabelColor: AppColors.secondaryText(context),
                  labelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  unselectedLabelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.normal),
                  tabs: _platforms.map((p) => Tab(text: _platformNames[p], height: 42)).toList(),
                ),
              ),
              // Leaderboard grid
              Expanded(
                child: categoriesAsync.when(
                  loading: () => const Center(
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(AppColors.amber),
                      ),
                    ),
                  ),
                  error: (error, stack) => Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.error_outline, color: AppColors.error, size: 48),
                        const SizedBox(height: 16),
                        Text('加载失败: $error', style: TextStyle(color: AppColors.secondaryText(context))),
                        const SizedBox(height: 16),
                        ElevatedButton(
                          onPressed: () => ref.invalidate(leaderboardCategoriesProvider),
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  ),
                  data: (categories) {
                    // 若首屏拉取分类成功但全部封面为空（网络抖动导致首曲封面未回），
                    // 自动重试一次，避免"只要不重启 app 就一张封面都没有"。
                    final hasNoCover =
                        categories.isNotEmpty &&
                        categories.every((c) => c.coverUrl == null || c.coverUrl!.isEmpty);
                    if (hasNoCover && _coverRetry < 2) {
                      _coverRetry++;
                      Future.microtask(() {
                        if (mounted) _refreshLeaderboards();
                      });
                    }
                    final grouped = _platforms.map((platform) {
                      final filtered = categories.where((c) => c.platform == platform).toList();
                      return _buildLeaderboardGrid(context, filtered, platform);
                    }).toList();
                    return TabBarView(
                      controller: _tabController,
                      physics: const NeverScrollableScrollPhysics(),
                      children: grouped,
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLeaderboardGrid(BuildContext context, List<LeaderboardCategory> categories, String platform) {
    if (categories.isEmpty) {
      return Center(
        child: Text('暂无排行榜数据', style: TextStyle(color: AppColors.mutedText(context))),
      );
    }
    return GridView.builder(
      padding: EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 16,
        crossAxisSpacing: 16,
        childAspectRatio: 0.85,
      ),
      itemCount: categories.length,
      itemBuilder: (context, index) {
        final category = categories[index];
        return _buildLeaderboardCard(context, category, platform, index);
      },
    );
  }

  Widget _buildLeaderboardCard(BuildContext context, LeaderboardCategory category, String platform, int index) {
    final cover = category.coverUrl;
    return Pressable(
      onTap: () => context.push('/leaderboard/detail?id=${Uri.encodeComponent(category.id)}&name=${Uri.encodeComponent(category.name)}'),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: _getAccentColor(platform, index).withAlpha(40),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (cover != null && cover.isNotEmpty)
                Image.network(
                  cover,
                  fit: BoxFit.cover,
                  // 首屏未加载完先显示占位，避免空白
                  frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                    if (wasSynchronouslyLoaded || frame != null) return child;
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        _LeaderboardCover(platform: platform, index: index, name: category.name),
                        child,
                      ],
                    );
                  },
                  errorBuilder: (_, __, ___) => _LeaderboardCover(
                    platform: platform,
                    index: index,
                    name: category.name,
                  ),
                )
              else
                _LeaderboardCover(
                  platform: platform,
                  index: index,
                  name: category.name,
                ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withAlpha(180),
                      ],
                    ),
                  ),
                  child: Text(
                    category.name,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                      shadows: [Shadow(blurRadius: 4, color: Colors.black54)],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _getAccentColor(String platform, int index) {
    final colors = _getPlatformPalette(platform);
    return colors[index % colors.length];
  }

  List<Color> _getPlatformPalette(String platform) {
    switch (platform) {
      case 'kw':
        return const [Color(0xFF6B3FA0), Color(0xFF9B59B6), Color(0xFF8E44AD), Color(0xFF7D3C98)];
      case 'tx':
        return const [Color(0xFF2355C0), Color(0xFF3498DB), Color(0xFF2980B9), Color(0xFF1F6FBB)];
      case 'wy':
        return const [Color(0xFF9B3060), Color(0xFFE74C3C), Color(0xFFC0392B), Color(0xFFD35400)];
      default:
        return const [Color(0xFF3D4A5A), Color(0xFF5D6D7E)];
    }
  }
}

/// 排行榜封面生成器 - 根据平台和索引生成独特视觉
class _LeaderboardCover extends StatelessWidget {
  final String platform;
  final int index;
  final String name;

  const _LeaderboardCover({
    required this.platform,
    required this.index,
    required this.name,
  });

  @override
  Widget build(BuildContext context) {
    final seed = _hashString(platform + index.toString());
    final random = Random(seed);

    final palette = _getPalette(platform);
    final baseColor = palette[index % palette.length];
    final accentColor = palette[(index + 1) % palette.length];

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment(
            random.nextDouble() * 2 - 1,
            random.nextDouble() * 2 - 1,
          ),
          end: Alignment(
            random.nextDouble() * 2 - 1,
            random.nextDouble() * 2 - 1,
          ),
          colors: [
            baseColor,
            accentColor,
            baseColor.withAlpha(180),
          ],
        ),
      ),
      child: Stack(
        children: [
          // 装饰图案
          ...List.generate(3, (i) => _buildDecorShape(random, i)),
          // 中心图标
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _getPlatformIcon(),
                  color: Colors.white.withAlpha(220),
                  size: 40,
                  shadows: const [Shadow(blurRadius: 8, color: Colors.black26)],
                ),
                const SizedBox(height: 4),
                Text(
                  _getShortName(),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Colors.white.withAlpha(200),
                    shadows: const [Shadow(blurRadius: 4, color: Colors.black38)],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDecorShape(Random random, int i) {
    final size = 40.0 + random.nextDouble() * 80;
    final dx = random.nextDouble() * 200 - 50;
    final dy = random.nextDouble() * 200 - 50;
    final opacity = 0.05 + random.nextDouble() * 0.15;

    return Positioned(
      left: dx,
      top: dy,
      child: Transform.rotate(
        angle: random.nextDouble() * pi * 2,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: Colors.white.withAlpha((opacity * 255).toInt()),
            shape: i % 2 == 0 ? BoxShape.circle : BoxShape.rectangle,
            borderRadius: i % 2 == 0 ? null : BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }

  String _getShortName() {
    if (name.length <= 4) return name;
    return name.replaceAll('榜', '').replaceAll('排行榜', '');
  }

  List<Color> _getPalette(String platform) {
    switch (platform) {
      case 'kw':
        return const [Color(0xFF6B3FA0), Color(0xFF9B59B6), Color(0xFF8E44AD), Color(0xFF5B2C6F)];
      case 'tx':
        return const [Color(0xFF2355C0), Color(0xFF3498DB), Color(0xFF2980B9), Color(0xFF1A5276)];
      case 'wy':
        return const [Color(0xFF9B3060), Color(0xFFE74C3C), Color(0xFFC0392B), Color(0xFF7B241C)];
      default:
        return const [Color(0xFF3D4A5A), Color(0xFF5D6D7E)];
    }
  }

  IconData _getPlatformIcon() {
    switch (platform) {
      case 'kw':
        return Icons.music_note;
      case 'tx':
        return Icons.queue_music;
      case 'wy':
        return Icons.cloud;
      default:
        return Icons.trending_up;
    }
  }

  int _hashString(String input) {
    int hash = 0;
    for (int i = 0; i < input.length; i++) {
      hash = (hash * 31 + input.codeUnitAt(i)) & 0x7FFFFFFF;
    }
    return hash;
  }
}
