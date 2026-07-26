import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_colors.dart';
import 'equalizer_provider.dart';

class EqualizerScreen extends ConsumerStatefulWidget {
  const EqualizerScreen({super.key});

  @override
  ConsumerState<EqualizerScreen> createState() => _EqualizerScreenState();
}

class _EqualizerScreenState extends ConsumerState<EqualizerScreen> {
  @override
  Widget build(BuildContext context) {
    final eqState = ref.watch(equalizerProvider);

    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: Text('均衡器', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.onScaffold(context))),
          actions: [
            TextButton(
              onPressed: () => ref.read(equalizerProvider.notifier).reset(),
              child: Text('重置', style: TextStyle(color: AppColors.secondaryText(context), fontSize: 13)),
            ),
          ],
        ),
        body: Column(
          children: [
            // 启用开关
            _buildEnableToggle(eqState.enabled),
            // 预设芯片
            _buildPresetChips(eqState),
            // 频段推子区域
            Expanded(
              child: _buildFrequencyBars(eqState),
            ),
            // 低音/高音滑块
            _buildBassTrebleSliders(eqState),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildEnableToggle(bool enabled) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Row(
        children: [
          Text('启用均衡器', style: TextStyle(color: AppColors.onScaffold(context), fontSize: 14, fontWeight: FontWeight.w500)),
          const Spacer(),
          Switch.adaptive(
            value: enabled,
            onChanged: (v) => ref.read(equalizerProvider.notifier).setEnabled(v),
            activeColor: AppColors.amber,
          ),
        ],
      ),
    );
  }

  Widget _buildPresetChips(EqualizerState eqState) {
    final presets = EqPreset.values.where((p) => p != EqPreset.custom).toList();
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: 16),
        itemCount: presets.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final preset = presets[index];
          final isSelected = eqState.preset == preset;
          return GestureDetector(
            onTap: () => ref.read(equalizerProvider.notifier).selectPreset(preset),
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: isSelected ? AppColors.amber.withAlpha(40) : AppColors.surface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: isSelected ? AppColors.amber.withAlpha(100) : AppColors.border,
                  width: 1,
                ),
              ),
              child: Text(
                preset.label,
                style: TextStyle(
                  color: isSelected ? AppColors.amber : AppColors.textSecondary,
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildFrequencyBars(EqualizerState eqState) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                // dB 刻度和网格线
                _buildDbScale(),
                // 频段推子
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: List.generate(10, (index) {
                    return _buildFrequencyBand(index, eqState.gains[index], eqState.enabled);
                  }),
                ),
              ],
            ),
          ),
          // 频率标签
          Padding(
            padding: EdgeInsets.only(top: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: freqLabels.map((label) {
                return SizedBox(
                  width: 28,
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.mutedText(context), fontSize: 9),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDbScale() {
    return Positioned.fill(
      child: Row(
        children: [
          // dB 标签
          SizedBox(
            width: 32,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _dbLabel('+12'),
                _dbLabel('+6'),
                _dbLabel('0', highlight: true),
                _dbLabel('-6'),
                _dbLabel('-12'),
              ],
            ),
          ),
          // 网格线
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _gridLine(false),
                _gridLine(false),
                _gridLine(true), // 0 dB 高亮
                _gridLine(false),
                _gridLine(false),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _dbLabel(String text, {bool highlight = false}) {
    return Text(
      text,
      style: TextStyle(
        color: highlight ? AppColors.textSecondary : AppColors.textMuted,
        fontSize: 9,
        fontWeight: highlight ? FontWeight.w500 : FontWeight.normal,
      ),
    );
  }

  Widget _gridLine(bool isZero) {
    return Container(
      height: 1,
      color: isZero ? AppColors.border.withAlpha(80) : AppColors.border.withAlpha(30),
    );
  }

  Widget _buildFrequencyBand(int index, int gain, bool enabled) {
    return SizedBox(
      width: 28,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final height = constraints.maxHeight;
          final center = height / 2;
          // 计算手柄位置：gain 范围 -12~+12，映射到 0~height
          final normalizedGain = (gain + 12) / 24; // 0~1
          final handleY = height - (normalizedGain * height);

          return GestureDetector(
            onVerticalDragUpdate: enabled
                ? (details) {
                    final newY = details.localPosition.dy.clamp(0.0, height);
                    final newNormalized = 1 - (newY / height);
                    final newGain = (newNormalized * 24 - 12).round().clamp(-12, 12);
                    ref.read(equalizerProvider.notifier).setBandGain(index, newGain);
                  }
                : null,
            child: Stack(
              children: [
                // 轨道
                Center(
                  child: Container(
                    width: 4,
                    decoration: BoxDecoration(
                      color: AppColors.cardBorder(context).withAlpha(50),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                // 填充条
                Positioned(
                  left: 12,
                  right: 12,
                  top: gain >= 0 ? center - (gain / 12.0) * (height / 2) : center,
                  bottom: gain >= 0 ? center : center + (gain.abs() / 12.0) * (height / 2),
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: gain >= 0
                          ? const LinearGradient(
                              begin: Alignment.bottomCenter,
                              end: Alignment.topCenter,
                              colors: [Color(0x801ED760), AppColors.amber],
                            )
                          : LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Color(0x805B9BFF), AppColors.info],
                            ),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                // 手柄
                Positioned(
                  left: 6,
                  top: handleY - 8,
                  child: Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: gain >= 0 ? AppColors.amber : AppColors.info,
                      border: Border.all(color: Theme.of(context).scaffoldBackgroundColor, width: 2.5),
                      boxShadow: [
                        BoxShadow(
                          color: (gain >= 0 ? AppColors.amber : AppColors.info).withAlpha(100),
                          blurRadius: 8,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildBassTrebleSliders(EqualizerState eqState) {
    // 低音 = 前3个频段的平均值，高音 = 后3个频段的平均值
    final bassGain = ((eqState.gains[0] + eqState.gains[1] + eqState.gains[2]) / 3).round();
    final trebleGain = ((eqState.gains[7] + eqState.gains[8] + eqState.gains[9]) / 3).round();

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: [
          _buildSliderRow('低音', bassGain, AppColors.amber),
          const SizedBox(height: 12),
          _buildSliderRow('高音', trebleGain, AppColors.info),
        ],
      ),
    );
  }

  Widget _buildSliderRow(String label, int value, Color color) {
    return Row(
      children: [
        SizedBox(
          width: 48,
          child: Text(label, style: TextStyle(color: AppColors.secondaryText(context), fontSize: 12, fontWeight: FontWeight.w500)),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderThemeData(
              activeTrackColor: color,
              inactiveTrackColor: AppColors.border.withAlpha(50),
              thumbColor: color,
              overlayColor: color.withAlpha(30),
              trackHeight: 4,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
            ),
            child: Slider(
              value: (value + 12) / 24, // 归一化到 0~1
              onChanged: null, // 只读，通过频段推子调节
            ),
          ),
        ),
        SizedBox(
          width: 48,
          child: Text(
            '${value > 0 ? '+' : ''}$value dB',
            textAlign: TextAlign.right,
            style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w500),
          ),
        ),
      ],
    );
  }
}
