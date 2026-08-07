import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

enum AppLogLevel { info, warning, error }

final class AppLogEntry {
  const AppLogEntry({
    required this.timestamp,
    required this.level,
    required this.category,
    required this.message,
    this.stackTrace,
  });

  final DateTime timestamp;
  final AppLogLevel level;
  final String category;
  final String message;
  final String? stackTrace;

  String get text {
    final time = timestamp.toIso8601String();
    final levelName = level.name.toUpperCase();
    final buffer = StringBuffer('[$time][$levelName][$category] $message');
    if (stackTrace case final stack? when stack.isNotEmpty) {
      buffer
        ..write('\n')
        ..write(stack);
    }
    return buffer.toString();
  }
}

final class AppLog with WidgetsBindingObserver {
  AppLog({this.maximumEntries = 2000});

  static final AppLog instance = AppLog();

  final int maximumEntries;
  final List<AppLogEntry> _items = [];
  final ValueNotifier<List<AppLogEntry>> entries =
      ValueNotifier<List<AppLogEntry>>(const []);
  DebugPrintCallback? _previousDebugPrint;
  FlutterExceptionHandler? _previousFlutterError;
  bool Function(Object error, StackTrace stackTrace)? _previousPlatformError;
  bool _installed = false;

  void install() {
    if (_installed) return;
    _installed = true;
    _previousDebugPrint = debugPrint;
    debugPrint = _captureDebugPrint;
    _previousFlutterError = FlutterError.onError;
    FlutterError.onError = _captureFlutterError;
    _previousPlatformError = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = _capturePlatformError;
    WidgetsBinding.instance.addObserver(this);
    record('app', 'diagnostic logging started');
  }

  void record(
    String category,
    Object? message, {
    AppLogLevel level = AppLogLevel.info,
    StackTrace? stackTrace,
  }) {
    var text = _redact(message?.toString() ?? '');
    if (text.length > 8000) {
      text = '${text.substring(0, 8000)}\n… message truncated';
    }
    _items.add(
      AppLogEntry(
        timestamp: DateTime.now(),
        level: level,
        category: category,
        message: text,
        stackTrace:
            stackTrace == null ? null : _redact(stackTrace.toString()),
      ),
    );
    if (_items.length > maximumEntries) {
      _items.removeRange(0, _items.length - maximumEntries);
    }
    entries.value = List.unmodifiable(_items);
  }

  void clear() {
    if (_items.isEmpty) return;
    _items.clear();
    entries.value = const [];
  }

  String exportText() => _items.map((entry) => entry.text).join('\n\n');

  void _captureDebugPrint(String? message, {int? wrapWidth}) {
    if (message != null && message.isNotEmpty) record('debug', message);
    _previousDebugPrint?.call(message, wrapWidth: wrapWidth);
  }

  void _captureFlutterError(FlutterErrorDetails details) {
    record(
      'flutter',
      details.exceptionAsString(),
      level: AppLogLevel.error,
      stackTrace: details.stack,
    );
    final previous = _previousFlutterError;
    if (previous != null) {
      previous(details);
    } else {
      FlutterError.presentError(details);
    }
  }

  bool _capturePlatformError(Object error, StackTrace stackTrace) {
    record('platform', error, level: AppLogLevel.error, stackTrace: stackTrace);
    return _previousPlatformError?.call(error, stackTrace) ?? false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    record('lifecycle', state.name);
  }

  @override
  void didHaveMemoryPressure() {
    record('lifecycle', 'memory pressure', level: AppLogLevel.warning);
  }

  String _redact(String value) {
    return value
        .replaceAllMapped(
          RegExp(
            r'(authorization\s*[:=]\s*)(?:bearer\s+)?[^\s,]+',
            caseSensitive: false,
          ),
          (match) => '${match.group(1)}***',
        )
        .replaceAllMapped(
          RegExp(
            r'((?:access[-_]?token|token)\s*[:=]\s*)[^\s,&#]+',
            caseSensitive: false,
          ),
          (match) => '${match.group(1)}***',
        )
        .replaceAllMapped(
          RegExp(
            r'([?&](?:(?:access[-_]?token|token)|authorization|signature|sign|'
            r'(?:x-)?api[-_]?key|cookie|password)=)[^&#\s]+',
            caseSensitive: false,
          ),
          (match) => '${match.group(1)}***',
        )
        .replaceAllMapped(
          RegExp(r'(cookie\s*[:=]\s*)[^\r\n]+', caseSensitive: false),
          (match) => '${match.group(1)}***',
        );
  }
}

final class AppLogNavigationObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    AppLog.instance.record('navigation', 'push ${_routeName(route)}');
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    AppLog.instance.record('navigation', 'pop ${_routeName(route)}');
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    AppLog.instance.record(
      'navigation',
      'replace ${_routeName(oldRoute)} → ${_routeName(newRoute)}',
    );
  }

  String _routeName(Route<dynamic>? route) =>
      route?.settings.name ?? route?.runtimeType.toString() ?? 'unknown';
}

final appLogNavigationObserver = AppLogNavigationObserver();
