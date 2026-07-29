import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/cloud_api_client.dart';

final cloudApiProvider = Provider<CloudApiClient>((ref) => CloudApiClient());

final cloudSessionProvider =
    StateNotifierProvider<CloudSessionNotifier, CloudSessionState>((ref) {
  return CloudSessionNotifier(ref.watch(cloudApiProvider));
});

class CloudSessionState {
  final bool loaded;
  final bool loggedIn;
  final bool checking;
  final String? baseUrl;
  final String? username;
  final String? role;
  final String? error;

  const CloudSessionState({
    this.loaded = false,
    this.loggedIn = false,
    this.checking = false,
    this.baseUrl,
    this.username,
    this.role,
    this.error,
  });

  CloudSessionState copyWith({
    bool? loaded,
    bool? loggedIn,
    bool? checking,
    String? baseUrl,
    String? username,
    String? role,
    String? error,
  }) {
    return CloudSessionState(
      loaded: loaded ?? this.loaded,
      loggedIn: loggedIn ?? this.loggedIn,
      checking: checking ?? this.checking,
      baseUrl: baseUrl ?? this.baseUrl,
      username: username ?? this.username,
      role: role ?? this.role,
      error: error,
    );
  }
}

class CloudSessionNotifier extends StateNotifier<CloudSessionState> {
  CloudSessionNotifier(this._api, {bool autoRefresh = true})
      : super(const CloudSessionState()) {
    if (autoRefresh) refresh();
  }

  final CloudApiClient _api;
  int _generation = 0;

  bool _current(int generation) => generation == _generation;

  CloudSessionState _sessionState({String? error}) {
    return CloudSessionState(
      loaded: true,
      checking: false,
      loggedIn: _api.isLoggedIn,
      baseUrl: _api.baseUrl,
      username: _api.username,
      role: _api.role,
      error: error,
    );
  }

  Future<void> refresh() async {
    final generation = ++_generation;
    state = state.copyWith(checking: true, error: null);
    try {
      await _api.load();
    } catch (error) {
      if (!_current(generation)) return;
      state = state.copyWith(
        loaded: true,
        checking: false,
        error: '无法读取安全凭据: $error',
      );
      return;
    }
    if (!_current(generation)) return;

    final verification =
        _api.isLoggedIn ? await _api.verify() : CloudVerification.noSession;
    if (!_current(generation)) return;

    if (verification == CloudVerification.unauthorized && _api.isLoggedIn) {
      try {
        await _api.clearSession();
      } catch (_) {
        if (!_current(generation)) return;
        state = _sessionState(error: '无法清除安全凭据');
        return;
      }
      if (!_current(generation)) return;
    }

    state = _sessionState(
      error: verification == CloudVerification.unavailable
          ? '服务器暂时不可用，已保留登录状态'
          : _api.configurationError,
    );
  }

  Future<void> setBaseUrl(String url) async {
    final generation = ++_generation;
    try {
      await _api.setBaseUrl(url);
    } on ArgumentError catch (error) {
      if (_current(generation)) {
        state =
            state.copyWith(checking: false, error: error.message?.toString());
      }
      rethrow;
    }
    if (!_current(generation)) return;
    state = _sessionState();
  }

  Future<bool> login(String username, String password) async {
    final generation = ++_generation;
    try {
      await _api.login(username, password);
    } catch (error) {
      if (_current(generation)) {
        state = state.copyWith(checking: false, error: error.toString());
      }
      return false;
    }
    if (!_current(generation)) return false;
    state = _sessionState();
    return true;
  }

  Future<bool> register(String username, String password) async {
    final generation = ++_generation;
    try {
      await _api.register(username, password);
    } catch (error) {
      if (_current(generation)) {
        state = state.copyWith(checking: false, error: error.toString());
      }
      return false;
    }
    if (!_current(generation)) return false;
    state = _sessionState();
    return true;
  }

  Future<void> logout() async {
    final generation = ++_generation;
    try {
      await _api.clearSession();
    } catch (_) {
      if (_current(generation)) {
        state = _sessionState(error: '无法清除安全凭据');
      }
      return;
    }
    if (!_current(generation)) return;
    state = _sessionState();
  }
}
