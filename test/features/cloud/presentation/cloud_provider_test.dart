import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/features/cloud/domain/cloud_api_client.dart';
import 'package:lx_music_flutter/features/cloud/presentation/cloud_provider.dart';

final class ControlledCloudApiClient extends CloudApiClient {
  ControlledCloudApiClient({bool initiallyLoggedIn = false})
      : _loggedIn = initiallyLoggedIn,
        _username = initiallyLoggedIn ? 'saved-user' : null,
        _role = initiallyLoggedIn ? 'user' : null;

  Completer<void> loadCompleter = Completer<void>();
  Completer<Map<String, dynamic>> loginCompleter =
      Completer<Map<String, dynamic>>();
  Completer<Map<String, dynamic>> registerCompleter =
      Completer<Map<String, dynamic>>();
  Completer<void> clearCompleter = Completer<void>();
  Completer<void> clearStarted = Completer<void>();
  Completer<void> baseUrlCompleter = Completer<void>();
  Completer<CloudVerification> verifyCompleter = Completer<CloudVerification>();
  Completer<void> verifyStarted = Completer<void>();

  bool loadImmediately = true;
  bool clearImmediately = true;
  bool baseUrlImmediately = true;
  CloudVerification? nextVerification;
  int clearCount = 0;
  bool _loggedIn;
  String? _username;
  String? _role;
  String? _token = 'old-token';
  int _sessionRevision = 0;
  String? _baseUrl = 'https://old.example';
  String? _configurationError;

  @override
  String? get baseUrl => _baseUrl;

  @override
  String? get configurationError => _configurationError;

  @override
  bool get isLoggedIn => _loggedIn;

  @override
  String? get role => _role;

  @override
  String? get token => _token;

  @override
  int get sessionRevision => _sessionRevision;

  @override
  String? get username => _username;

  @override
  Future<void> load() =>
      loadImmediately ? Future.value() : loadCompleter.future;

  @override
  Future<Map<String, dynamic>> login(String username, String password) async {
    final result = await loginCompleter.future;
    _loggedIn = true;
    _token = 'new-token';
    _username = result['username']?.toString() ?? username;
    _role = result['role']?.toString() ?? 'user';
    return result;
  }

  @override
  Future<Map<String, dynamic>> register(
    String username,
    String password,
  ) async {
    final result = await registerCompleter.future;
    _loggedIn = true;
    _username = result['username']?.toString() ?? username;
    _role = result['role']?.toString() ?? 'user';
    return result;
  }

  @override
  Future<void> clearSession(
      {String? expectedToken, int? expectedRevision}) async {
    clearCount++;
    if (!clearStarted.isCompleted) clearStarted.complete();
    if (!clearImmediately) await clearCompleter.future;
    if ((expectedToken != null && _token != expectedToken) ||
        (expectedRevision != null && _sessionRevision != expectedRevision)) {
      return;
    }
    _loggedIn = false;
    _token = null;
    _username = null;
    _role = null;
  }

  @override
  Future<void> setBaseUrl(String url) async {
    _sessionRevision++;
    if (!baseUrlImmediately) await baseUrlCompleter.future;
    _baseUrl = url;
    _configurationError = null;
  }

  @override
  Future<CloudVerification> verify() {
    if (!verifyStarted.isCompleted) verifyStarted.complete();
    return nextVerification == null
        ? verifyCompleter.future
        : Future.value(nextVerification);
  }

  void completeLogin({required String username, String role = 'user'}) {
    loginCompleter.complete({'username': username, 'role': role});
  }

  void failLogin(Object error) => loginCompleter.completeError(error);

  void completeVerify(CloudVerification verification) {
    verifyCompleter.complete(verification);
  }

  void failVerify(Object error) => verifyCompleter.completeError(error);
}

void main() {
  test('late refresh cannot overwrite a newer login', () async {
    final api = ControlledCloudApiClient(initiallyLoggedIn: true);
    final notifier = CloudSessionNotifier(api, autoRefresh: false);

    final refresh = notifier.refresh();
    await api.verifyStarted.future;
    final login = notifier.login('new-user', 'password');
    api.completeLogin(username: 'new-user');

    expect(await login, isTrue);
    api.completeVerify(CloudVerification.unauthorized);
    await refresh;

    expect(notifier.state.loggedIn, isTrue);
    expect(notifier.state.username, 'new-user');
    expect(api.clearCount, 0);
  });

  test('blocked unauthorized cleanup cannot erase a newer login', () async {
    final api = ControlledCloudApiClient(initiallyLoggedIn: true)
      ..nextVerification = CloudVerification.unauthorized
      ..clearImmediately = false;
    final notifier = CloudSessionNotifier(api, autoRefresh: false);

    final refresh = notifier.refresh();
    await api.clearStarted.future;
    final login = notifier.login('new-user', 'password');
    api.completeLogin(username: 'new-user');
    expect(await login, isTrue);

    api.clearCompleter.complete();
    await refresh;

    expect(notifier.state.loggedIn, isTrue);
    expect(notifier.state.username, 'new-user');
    expect(api.token, 'new-token');
  });

  test('blocked unauthorized cleanup cannot erase a newer base URL', () async {
    final api = ControlledCloudApiClient(initiallyLoggedIn: true)
      ..nextVerification = CloudVerification.unauthorized
      ..clearImmediately = false;
    final notifier = CloudSessionNotifier(api, autoRefresh: false);

    final refresh = notifier.refresh();
    await api.clearStarted.future;
    await notifier.setBaseUrl('https://new.example');

    api.clearCompleter.complete();
    await refresh;

    expect(notifier.state.loggedIn, isTrue);
    expect(notifier.state.baseUrl, 'https://new.example');
    expect(api.token, 'old-token');
  });

  test('late refresh cannot overwrite a newer logout', () async {
    final api = ControlledCloudApiClient(initiallyLoggedIn: true);
    final notifier = CloudSessionNotifier(api, autoRefresh: false);

    final refresh = notifier.refresh();
    await api.verifyStarted.future;
    final logout = notifier.logout();
    await logout;
    api.completeVerify(CloudVerification.valid);
    await refresh;

    expect(notifier.state.loggedIn, isFalse);
    expect(notifier.state.username, isNull);
  });

  test('late refresh cannot overwrite a newer base URL', () async {
    final api = ControlledCloudApiClient(initiallyLoggedIn: true);
    final notifier = CloudSessionNotifier(api, autoRefresh: false);

    final refresh = notifier.refresh();
    await api.verifyStarted.future;
    await notifier.setBaseUrl('https://new.example');
    api.completeVerify(CloudVerification.valid);
    await refresh;

    expect(notifier.state.baseUrl, 'https://new.example');
  });

  test('outage preserves an authenticated session', () async {
    final api = ControlledCloudApiClient(initiallyLoggedIn: true)
      ..nextVerification = CloudVerification.unavailable;
    final notifier = CloudSessionNotifier(api, autoRefresh: false);

    await notifier.refresh();

    expect(notifier.state.loaded, isTrue);
    expect(notifier.state.checking, isFalse);
    expect(notifier.state.loggedIn, isTrue);
    expect(notifier.state.error, contains('服务器暂时不可用'));
    expect(api.clearCount, 0);
  });

  test('401 clears the authenticated session', () async {
    final api = ControlledCloudApiClient(initiallyLoggedIn: true)
      ..nextVerification = CloudVerification.unauthorized;
    final notifier = CloudSessionNotifier(api, autoRefresh: false);

    await notifier.refresh();

    expect(notifier.state.loggedIn, isFalse);
    expect(api.clearCount, 1);
  });

  test('clear failure preserves the authenticated session and reports an error',
      () async {
    final api = ControlledCloudApiClient(initiallyLoggedIn: true)
      ..nextVerification = CloudVerification.unauthorized
      ..clearImmediately = false;
    final notifier = CloudSessionNotifier(api, autoRefresh: false);

    final refresh = notifier.refresh();
    await api.clearStarted.future;
    api.clearCompleter.completeError(StateError('keychain unavailable'));
    await refresh;

    expect(notifier.state.loggedIn, isTrue);
    expect(notifier.state.username, 'saved-user');
    expect(notifier.state.error, contains('无法清除安全凭据'));
  });

  test('a stale login safety failure remains visible after a newer command',
      () async {
    final api = ControlledCloudApiClient();
    final notifier = CloudSessionNotifier(api, autoRefresh: false);

    final login = notifier.login('user', 'password');
    await notifier.setBaseUrl('https://new.example');
    api.failLogin(const CloudSessionSafetyError(
      'Cloud session became stale and was invalidated. Please sign in again.',
    ));

    expect(await login, isFalse);
    expect(notifier.state.error, contains('invalidated'));
  });

  test('a stale refresh safety failure remains visible after a newer command',
      () async {
    final api = ControlledCloudApiClient(initiallyLoggedIn: true);
    final notifier = CloudSessionNotifier(api, autoRefresh: false);

    final refresh = notifier.refresh();
    await api.verifyStarted.future;
    await notifier.setBaseUrl('https://new.example');
    api.failVerify(const CloudSessionSafetyError(
      'Cloud session became stale and was invalidated. Please sign in again.',
    ));
    await refresh;

    expect(notifier.state.error, contains('invalidated'));
    expect(notifier.state.loggedIn, isTrue);
    expect(notifier.state.baseUrl, 'https://new.example');
  });
}
