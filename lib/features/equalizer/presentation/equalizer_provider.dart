import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/storage/storage_service.dart';

// 10频段频率标签
const List<String> freqLabels = ['32', '64', '125', '250', '500', '1K', '2K', '4K', '8K', '16K'];

// 预设定义
enum EqPreset {
  flat('平坦', [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
  vocal('人声增强', [-2, -1, 0, 2, 4, 5, 4, 2, 0, -1]),
  bassBoost('低音加强', [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
  electronic('电子', [5, 4, 2, 0, -1, 0, 2, 4, 5, 4]),
  classical('古典', [4, 3, 2, 1, 0, 0, 1, 2, 3, 4]),
  rock('摇滚', [4, 3, 1, 0, -1, 0, 2, 3, 4, 4]),
  pop('流行', [-1, 1, 3, 4, 3, 0, -1, 1, 2, 2]),
  jazz('爵士', [3, 2, 0, 1, -1, 0, 1, 2, 3, 3]),
  hiphop('嘻哈', [5, 4, 1, 0, -1, 1, 0, -1, 2, 2]),
  custom('自定义', []);

  final String label;
  final List<int> gains;
  const EqPreset(this.label, this.gains);
}

// 均衡器状态
class EqualizerState {
  final bool enabled;
  final List<int> gains; // 10频段增益 -12~+12
  final EqPreset preset;

  const EqualizerState({
    this.enabled = false,
    required this.gains,
    this.preset = EqPreset.flat,
  });

  EqualizerState copyWith({bool? enabled, List<int>? gains, EqPreset? preset}) {
    return EqualizerState(
      enabled: enabled ?? this.enabled,
      gains: gains ?? this.gains,
      preset: preset ?? this.preset,
    );
  }
}

class EqualizerNotifier extends StateNotifier<EqualizerState> {
  EqualizerNotifier() : super(const EqualizerState(gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0])) {
    _load();
  }

  Future<void> _load() async {
    final storage = await StorageService.instance;
    final enabled = storage.getBool('eq_enabled') ?? false;
    final presetIndex = storage.getInt('eq_preset');
    final gainsList = storage.getStringList('eq_gains');

    List<int> gains = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    if (gainsList != null && gainsList.length == 10) {
      gains = gainsList.map((s) => int.tryParse(s) ?? 0).toList();
    }

    EqPreset preset = EqPreset.flat;
    if (presetIndex != null && presetIndex >= 0 && presetIndex < EqPreset.values.length) {
      preset = EqPreset.values[presetIndex];
    }

    state = EqualizerState(enabled: enabled, gains: gains, preset: preset);
  }

  Future<void> setEnabled(bool enabled) async {
    state = state.copyWith(enabled: enabled);
    final storage = await StorageService.instance;
    await storage.setBool('eq_enabled', enabled);
  }

  Future<void> selectPreset(EqPreset preset) async {
    if (preset == EqPreset.custom) return;
    final gains = List<int>.from(preset.gains);
    state = state.copyWith(enabled: true, gains: gains, preset: preset);
    final storage = await StorageService.instance;
    await storage.setBool('eq_enabled', true);
    await storage.setInt('eq_preset', preset.index);
    await storage.setStringList('eq_gains', gains.map((g) => g.toString()).toList());
  }

  Future<void> setBandGain(int bandIndex, int gain) async {
    final newGains = List<int>.from(state.gains);
    newGains[bandIndex] = gain.clamp(-12, 12);
    state = state.copyWith(gains: newGains, preset: EqPreset.custom);
    final storage = await StorageService.instance;
    await storage.setInt('eq_preset', EqPreset.custom.index);
    await storage.setStringList('eq_gains', newGains.map((g) => g.toString()).toList());
  }

  Future<void> reset() async {
    state = const EqualizerState(enabled: false, gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0], preset: EqPreset.flat);
    final storage = await StorageService.instance;
    await storage.setBool('eq_enabled', false);
    await storage.setInt('eq_preset', EqPreset.flat.index);
    await storage.setStringList('eq_gains', List.filled(10, '0'));
  }
}

final equalizerProvider = StateNotifierProvider<EqualizerNotifier, EqualizerState>((ref) {
  return EqualizerNotifier();
});

// 播放速度
class PlaybackSpeedNotifier extends StateNotifier<double> {
  PlaybackSpeedNotifier() : super(1.0) {
    _load();
  }

  Future<void> _load() async {
    final storage = await StorageService.instance;
    final speed = storage.getDouble('playback_speed');
    if (speed != null) state = speed;
  }

  Future<void> setSpeed(double speed) async {
    state = speed;
    final storage = await StorageService.instance;
    await storage.setDouble('playback_speed', speed);
  }
}

final playbackSpeedProvider = StateNotifierProvider<PlaybackSpeedNotifier, double>((ref) {
  return PlaybackSpeedNotifier();
});
