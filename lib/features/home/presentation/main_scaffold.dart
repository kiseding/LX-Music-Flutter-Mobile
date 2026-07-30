import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/pressable.dart';
import '../../player/presentation/widgets/mini_player.dart';

/// 主壳：底栏 + 迷你播放器；分支内容由 [SwipeBranchContainer] 提供。
class MainScaffold extends StatelessWidget {
  final StatefulNavigationShell navigationShell;

  const MainScaffold({
    super.key,
    required this.navigationShell,
  });

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final bottomInset = media.padding.bottom;
    final navHeight = 37.0 + bottomInset;
    const miniHeight = 78.0;
    const gap = 7.0;
    final selectedIndex = navigationShell.currentIndex;
    // 壳层布局必须与键盘无关：任何 keyboardOpen 时改 padding/挪 chrome
    // 都会在 iOS 首次聚焦时触发布局抖动 → 输入法秒关。
    // 键盘盖住底栏即可；内容区始终预留 chrome 高度。
    final chromeBottom = navHeight + gap + miniHeight;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Stack(
        children: [
          Positioned.fill(
            child: Padding(
              padding: EdgeInsets.only(bottom: chromeBottom),
              child: navigationShell,
            ),
          ),
          Positioned(
            left: 3,
            right: 3,
            bottom: navHeight + gap,
            child: const MiniPlayer(floating: true, alwaysShow: true),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _BottomNav(
              height: navHeight,
              bottomInset: bottomInset,
              selectedIndex: selectedIndex,
              onTap: (i) => navigationShell.goBranch(i),
            ),
          ),
        ],
      ),
    );
  }
}

/// 双页跟手滑动：目标页从侧边跟入，松手后顺势切完，不再弹回/闪跳。
class SwipeBranchContainer extends StatefulWidget {
  final int currentIndex;
  final List<Widget> children;
  final void Function(int index) onSelect;

  const SwipeBranchContainer({
    super.key,
    required this.currentIndex,
    required this.children,
    required this.onSelect,
  });

  @override
  State<SwipeBranchContainer> createState() => _SwipeBranchContainerState();
}

class _SwipeBranchContainerState extends State<SwipeBranchContainer>
    with SingleTickerProviderStateMixin {
  double _dx = 0;
  bool _dragging = false;
  bool _animating = false;
  late final AnimationController _anim;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 240));
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant SwipeBranchContainer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部 goBranch（点底栏）时重置手势状态
    if (oldWidget.currentIndex != widget.currentIndex &&
        !_animating &&
        !_dragging) {
      _dx = 0;
    }
  }

  Future<void> _animateTo(double end) async {
    final start = _dx;
    _anim.reset();
    final tween = Tween<double>(begin: start, end: end).animate(
      CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic),
    );
    void tick() {
      if (mounted) setState(() => _dx = tween.value);
    }

    tween.addListener(tick);
    setState(() {
      _dragging = false;
      _animating = true;
    });
    await _anim.forward();
    tween.removeListener(tick);
  }

  Future<void> _finish(double width, double velocity) async {
    if (_animating) return;
    final idx = widget.currentIndex;
    final threshold = width * 0.18;
    int? target;
    if ((_dx < -threshold || velocity < -400) &&
        idx < widget.children.length - 1) {
      target = idx + 1;
    } else if ((_dx > threshold || velocity > 400) && idx > 0) {
      target = idx - 1;
    }

    if (target == null) {
      await _animateTo(0);
      if (!mounted) return;
      setState(() {
        _animating = false;
        _dx = 0;
      });
      return;
    }

    final end = target > idx ? -width : width;
    await _animateTo(end);
    if (!mounted) return;
    // 切页时同时清零位移：新页以静止态显示，无回弹
    setState(() {
      _animating = false;
      _dragging = false;
      _dx = 0;
    });
    widget.onSelect(target);
  }

  /// 输入框已聚焦：整页卸横滑，避免误滑关盘。
  /// 不读 viewInsets：键盘动画中 MediaQuery 变化会 rebuild 手势树，
  /// 在 iOS 首焦过程中足以把输入法打掉。
  bool get _imeActive {
    return FocusManager.instance.primaryFocus?.context
            ?.findAncestorStateOfType<EditableTextState>() !=
        null;
  }

  /// 根因：父级 HorizontalDrag 只要 addAllowedPointer，就会进 gesture arena，
  /// 与 TextField 首击抢手势 → iOS 输入法秒关。落在可编辑区域时直接不参赛。
  bool _shouldParticipateInSwipe(Offset globalPosition) {
    if (_animating) return false;
    if (_imeActive) return false;
    if (_hitTestEditable(globalPosition)) return false;
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final idx = widget.currentIndex;
    final count = widget.children.length;
    final moving = _dragging || _animating;

    // 邻页：跟手预览
    int? neighbor;
    if (moving) {
      if (_dx < 0 && idx < count - 1) {
        neighbor = idx + 1;
      } else if (_dx > 0 && idx > 0) {
        neighbor = idx - 1;
      }
    }

    final stack = ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (!moving)
            for (var i = 0; i < count; i++)
              Offstage(
                offstage: i != idx,
                child: TickerMode(
                  enabled: i == idx,
                  child: widget.children[i],
                ),
              ),
          if (moving) ...[
            if (neighbor != null)
              Transform.translate(
                offset: Offset(_dx < 0 ? width + _dx : -width + _dx, 0),
                child: widget.children[neighbor],
              ),
            Transform.translate(
              offset: Offset(_dx.clamp(-width, width), 0),
              child: widget.children[idx],
            ),
          ],
        ],
      ),
    );

    // 始终挂载识别器，但 addAllowedPointer 在 TextField/已聚焦时直接 return，
    // 不进 arena。禁止在聚焦时拆掉 GestureDetector（子树结构突变也会关盘）。
    return RawGestureDetector(
      gestures: <Type, GestureRecognizerFactory>{
        _EditableAwareHorizontalDragGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<
                _EditableAwareHorizontalDragGestureRecognizer>(
          () => _EditableAwareHorizontalDragGestureRecognizer(
            debugOwner: this,
            shouldParticipate: _shouldParticipateInSwipe,
            supportedDevices: {
              PointerDeviceKind.touch,
              PointerDeviceKind.trackpad,
            },
          ),
          (_EditableAwareHorizontalDragGestureRecognizer instance) {
            // ignore: invalid_use_of_protected_member
            instance.gestureSettings = const DeviceGestureSettings(
              touchSlop: 28,
            );
            instance
              ..onStart = (details) {
                if (_animating) return;
                setState(() {
                  _dragging = true;
                  _dx = 0;
                });
              }
              ..onUpdate = (details) {
                if (_animating || !_dragging) return;
                setState(() => _dx += details.delta.dx);
              }
              ..onEnd = (details) {
                if (_animating) return;
                _finish(width, details.primaryVelocity ?? 0);
              }
              ..onCancel = () {
                if (_animating) return;
                _finish(width, 0);
              };
          },
        ),
      },
      behavior: HitTestBehavior.translucent,
      child: stack,
    );
  }

  bool _hitTestEditable(Offset globalPosition) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return false;
    final local = box.globalToLocal(globalPosition);
    final result = BoxHitTestResult();
    if (!box.hitTest(result, position: local)) return false;
    for (final entry in result.path) {
      final t = entry.target;
      if (t is RenderEditable) return true;
    }
    return false;
  }
}

/// 落在 TextField 时不进入 gesture arena，从根上避免与首焦抢手势。
class _EditableAwareHorizontalDragGestureRecognizer
    extends HorizontalDragGestureRecognizer {
  _EditableAwareHorizontalDragGestureRecognizer({
    required this.shouldParticipate,
    super.debugOwner,
    super.supportedDevices,
  });

  final bool Function(Offset globalPosition) shouldParticipate;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (!shouldParticipate(event.position)) {
      return;
    }
    super.addAllowedPointer(event);
  }
}

class _BottomNav extends StatelessWidget {
  final double height;
  final double bottomInset;
  final int selectedIndex;
  final ValueChanged<int> onTap;

  const _BottomNav({
    required this.height,
    required this.bottomInset,
    required this.selectedIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).scaffoldBackgroundColor;
    return Container(
      height: height,
      color: bg,
      padding: EdgeInsets.only(top: 0, bottom: bottomInset > 0 ? 0 : 2),
      child: Row(
        children: [
          _item(context, 0, Icons.home_outlined, Icons.home, '首页'),
          _item(context, 1, Icons.search, Icons.search, '搜索'),
          _item(context, 2, Icons.library_music_outlined, Icons.library_music,
              '歌单'),
          _item(context, 3, Icons.settings_outlined, Icons.settings, '设置'),
        ],
      ),
    );
  }

  Widget _item(BuildContext context, int index, IconData icon,
      IconData activeIcon, String label) {
    final isSelected = index == selectedIndex;
    final accent = Theme.of(context).colorScheme.primary;
    final isDark = AppColors.isDark(context);
    // 未选中也要深、粗（约 90% 不透明）
    final muted = isDark ? const Color(0xE6FFFFFF) : const Color(0xE6000000);
    return Expanded(
      child: Pressable(
        semanticLabel: label,
        selected: isSelected,
        onTap: () => onTap(index),
        scale: 0.92,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isSelected ? activeIcon : icon,
              size: 23,
              color: isSelected ? accent : muted,
              weight: 700,
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.15,
                color: isSelected ? accent : muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
