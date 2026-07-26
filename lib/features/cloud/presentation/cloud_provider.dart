import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/cloud_api_client.dart';

final cloudApiProvider = Provider<CloudApiClient>((ref) {
  final client = CloudApiClient();
  // fire-and-forget load; screens await ensureLoaded
  client.load();
  return client;
});

final cloudSessionProvider =
    StateNotifierProvider<CloudSessionNotifier, CloudSessionState>((ref) {
  return CloudSessionNotifier(ref.watch(cloudApiProvider));
});

class CloudSessionState {
  final bool loaded;
  final bool loggedIn;
  final String? baseUrl;
  final String? username;
  final String? role;
  final String? error;

  const CloudSessionState({
    this.loaded = false,
    this.loggedIn = false,
    this.baseUrl,
    this.username,
    this.role,
    this.error,
  });

  CloudSessionState copyWith({
    bool? loaded,
    bool? loggedIn,
    String? baseUrl,
    String? username,
    String? role,
    String? error,
  }) {
    return CloudSessionState(
      loaded: loaded ?? this.loaded,
      loggedIn: loggedIn ?? this.loggedIn,
      baseUrl: baseUrl ?? this.baseUrl,
      username: username ?? this.username,
      role: role ?? this.role,
      error: error,
    );
  }
}

class CloudSessionNotifier extends StateNotifier<CloudSessionState> {
  final CloudApiClient _api;

  CloudSessionNotifier(this._api) : super(const CloudSessionState()) {
    refresh();
  }

  Future<void> refresh() async {
    await _api.load();
    var loggedIn = _api.isLoggedIn;
    if (loggedIn) {
      loggedIn = await _api.verify();
      if (!loggedIn) await _api.clearSession();
    }
    state = CloudSessionState(
      loaded: true,
      loggedIn: loggedIn,
      baseUrl: _api.baseUrl,
      username: _api.username,
      role: _api.role,
    );
  }

  Future<void> setBaseUrl(String url) async {
    await _api.setBaseUrl(url);
    state = state.copyWith(baseUrl: _api.baseUrl, error: null);
  }

  Future<bool> login(String username, String password) async {
    try {
      await _api.login(username, password);
      state = CloudSessionState(
        loaded: true,
        loggedIn: true,
        baseUrl: _api.baseUrl,
        username: _api.username,
        role: _api.role,
      );
      return true;
    } catch (e) {
      state = state.copyWith(error: e.toString(), loggedIn: false);
      return false;
    }
  }

  Future<bool> register(String username, String password) async {
    try {
      await _api.register(username, password);
      state = CloudSessionState(
        loaded: true,
        loggedIn: true,
        baseUrl: _api.baseUrl,
        username: _api.username,
        role: _api.role,
      );
      return true;
    } catch (e) {
      state = state.copyWith(error: e.toString(), loggedIn: false);
      return false;
    }
  }

  Future<void> logout() async {
    await _api.clearSession();
    state = CloudSessionState(
      loaded: true,
      loggedIn: false,
      baseUrl: _api.baseUrl,
    );
  }
}
