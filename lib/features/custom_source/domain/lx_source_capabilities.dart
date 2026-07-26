class LxSourceCapabilities {
  static const supportedPlatforms = {'kw', 'kg', 'tx', 'wy', 'mg', 'local'};
  static const supportedActions = {'musicUrl', 'lyric', 'pic'};
  static const supportedQualities = {
    '128k',
    '320k',
    'flac',
    'flac24bit',
    'hires',
  };

  const LxSourceCapabilities._(this._actions, this._qualities);

  final Map<String, Set<String>> _actions;
  final Map<String, Set<String>> _qualities;

  bool get isEmpty => _actions.isEmpty;

  static bool requiresDeclaration(String action) {
    return supportedActions.contains(action);
  }

  bool supports(String source, String action, [String? quality]) {
    final platform = source.toLowerCase();
    if (_actions[platform]?.contains(action) != true) return false;
    // musicUrl：未声明 qualitys 视为支持全部官方音质（与桌面一致）
    if (action != 'musicUrl' || quality == null) return true;
    final qs = _qualities[platform];
    if (qs == null || qs.isEmpty) return true;
    return qs.contains(quality.toLowerCase());
  }

  static LxSourceCapabilities fromInitData(dynamic data) {
    final actions = <String, Set<String>>{};
    final qualities = <String, Set<String>>{};
    if (data is! Map || data['sources'] is! Map) {
      return LxSourceCapabilities._(actions, qualities);
    }

    for (final entry in (data['sources'] as Map).entries) {
      final platform = entry.key.toString().toLowerCase();
      if (!supportedPlatforms.contains(platform) || entry.value is! Map) {
        continue;
      }
      final config = entry.value as Map;
      final declaredActions = <String>{};
      for (final action in supportedActions) {
        if (config[action] == true ||
            (config['actions'] is List &&
                (config['actions'] as List).contains(action))) {
          declaredActions.add(action);
        }
      }
      if (declaredActions.isNotEmpty) actions[platform] = declaredActions;

      final declaredQualities = config['qualitys'] ?? config['qualities'];
      if (declaredQualities is List) {
        qualities[platform] = declaredQualities
            .map((quality) => quality.toString().toLowerCase())
            .where(supportedQualities.contains)
            .toSet();
      }
    }
    return LxSourceCapabilities._(actions, qualities);
  }
}
