import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

typedef PlaybackMutationError = void Function(
  String operation,
  Object error,
  StackTrace stackTrace,
);

class PlaybackCommandCoordinator {
  final AudioPlayer _player;
  final VoidCallback? _onStateChanged;
  final PlaybackMutationError? _onError;

  Future<void> _tail = Future<void>.value();
  int _pendingReconciliations = 0;
  int _revision = 0;
  int _sourceToken = 0;
  _DesiredSource? _desiredSource;
  int? _installedSourceToken;
  bool _stopDesired = false;
  bool _desiredPlaying = false;
  int _intentRevision = 0;
  int? _resumeDeniedIntentRevision;
  int _interruptionDepth = 0;
  bool _interruptionMayResume = true;
  int _seekRevision = 0;
  int _appliedSeekRevision = 0;
  Duration? _desiredSeek;
  LoopMode? _desiredLoopMode;
  LoopMode? _appliedLoopMode;
  bool? _desiredShuffleEnabled;
  bool? _appliedShuffleEnabled;
  int _playCommandToken = 0;
  int? _activePlayCommandToken;
  int _lastPlayAttemptRevision = -1;
  int? _failedPlayIntentRevision;
  int? _failedPlaySourceToken;
  int? _failedSourceToken;

  PlaybackCommandCoordinator(
    this._player, {
    VoidCallback? onStateChanged,
    PlaybackMutationError? onError,
  })  : _onStateChanged = onStateChanged,
        _onError = onError;

  int get sourceToken => _sourceToken;
  int get intentRevision => _intentRevision;
  int get interruptionDepth => _interruptionDepth;
  bool get interruptionActive => _interruptionDepth > 0;
  bool get desiredPlaying => _desiredPlaying;
  bool get effectivePlaying => _effectivePlaying;
  Future<void> get settled => _tail;

  int requestSource({
    required String mediaId,
    required int queueIndex,
    required Duration position,
  }) {
    final token = ++_sourceToken;
    _desiredSource = _DesiredSource(
      token: token,
      mediaId: mediaId,
      queueIndex: queueIndex,
      position: position,
    );
    _failedSourceToken = null;
    _stopDesired = false;
    _desiredSeek = null;
    _appliedSeekRevision = _seekRevision;
    _markDirty();
    return token;
  }

  bool ownsSourceRequest(int token) => _desiredSource?.token == token;

  Future<bool> commitSource(int token, AudioSource source) async {
    final desired = _desiredSource;
    if (desired == null || desired.token != token) return false;
    desired.source = source;
    await _markDirty(awaitApplication: true);
    return _desiredSource?.token == token && _installedSourceToken == token;
  }

  Future<void> explicitPlay() {
    _intentRevision++;
    _desiredPlaying = true;
    _stopDesired = false;
    return _markDirty();
  }

  Future<void> explicitPause() {
    _intentRevision++;
    _desiredPlaying = false;
    return _markDirty();
  }

  Future<void> pausePreservingIntent() =>
      _markDirty(forcePause: true, awaitApplication: true);

  Future<void> setPlayingPreservingIntent(bool playing) {
    _desiredPlaying = playing;
    return _markDirty();
  }

  Future<void> reconcilePlayingIntent() => _markDirty();

  Future<void> recoverIdleSource() {
    _installedSourceToken = null;
    _activePlayCommandToken = null;
    return _markDirty();
  }

  Future<void> stop() {
    _intentRevision++;
    _desiredPlaying = false;
    _desiredSource = null;
    _stopDesired = true;
    _sourceToken++;
    return _markDirty();
  }

  Future<bool> seek(Duration position) async {
    _desiredSeek = position;
    final revision = ++_seekRevision;
    await _markDirty(awaitApplication: true);
    return _appliedSeekRevision >= revision;
  }

  Future<void> setLoopMode(LoopMode mode) {
    _desiredLoopMode = mode;
    return _markDirty();
  }

  Future<void> setShuffleModeEnabled(bool enabled) {
    _desiredShuffleEnabled = enabled;
    return _markDirty();
  }

  Future<void> beginInterruption() {
    if (_interruptionDepth == 0) _interruptionMayResume = true;
    _interruptionDepth++;
    return _markDirty();
  }

  Future<void> endInterruption({required bool mayResume}) {
    if (_interruptionDepth == 0) return settled;
    if (!mayResume) _interruptionMayResume = false;
    _interruptionDepth--;
    if (_interruptionDepth == 0) {
      if (!_interruptionMayResume) {
        _resumeDeniedIntentRevision = _intentRevision;
      }
      _interruptionMayResume = true;
    }
    return _markDirty();
  }

  Future<void> becomingNoisy() {
    _interruptionDepth = 0;
    _interruptionMayResume = true;
    _intentRevision++;
    _desiredPlaying = false;
    _resumeDeniedIntentRevision = _intentRevision;
    return _markDirty();
  }

  Future<void> _markDirty({
    bool forcePause = false,
    bool awaitApplication = false,
  }) {
    final revision = ++_revision;
    final previous = _tail;
    final queuedBehindMutation = _pendingReconciliations > 0;
    _pendingReconciliations++;
    final next = () async {
      await previous;
      await _reconcile(revision, forcePause: forcePause);
    }();
    final tracked = next.whenComplete(() => _pendingReconciliations--);
    _tail = tracked.catchError((Object _, StackTrace __) {});
    return awaitApplication || !queuedBehindMutation
        ? tracked
        : Future<void>.value();
  }

  bool get _effectivePlaying =>
      _desiredPlaying &&
      !interruptionActive &&
      (_resumeDeniedIntentRevision == null ||
          _intentRevision > _resumeDeniedIntentRevision!);

  Future<void> _reconcile(int commandRevision,
      {bool forcePause = false}) async {
    try {
      if (_desiredLoopMode != null && _desiredLoopMode != _appliedLoopMode) {
        final mode = _desiredLoopMode!;
        await _player.setLoopMode(mode);
        _appliedLoopMode = mode;
        _notifyIfCurrent(commandRevision);
      }

      if (_desiredShuffleEnabled != null &&
          _desiredShuffleEnabled != _appliedShuffleEnabled) {
        final enabled = _desiredShuffleEnabled!;
        await _player.setShuffleModeEnabled(enabled);
        _appliedShuffleEnabled = enabled;
        _notifyIfCurrent(commandRevision);
      }

      if (_stopDesired) {
        if (_installedSourceToken != null ||
            _player.playing ||
            _player.processingState != ProcessingState.idle) {
          await _player.stop();
        }
        _installedSourceToken = null;
        _activePlayCommandToken = null;
        _notifyIfCurrent(commandRevision);
        return;
      }

      final desiredSource = _desiredSource;
      var sourceChanged = false;
      if (desiredSource != null &&
          desiredSource.source != null &&
          _failedSourceToken != desiredSource.token &&
          _installedSourceToken != desiredSource.token) {
        try {
          await _player.setAudioSource(
            desiredSource.source!,
            initialPosition: desiredSource.position,
          );
        } catch (error, stackTrace) {
          _failedSourceToken = desiredSource.token;
          _onError?.call('setAudioSource', error, stackTrace);
          if (_desiredSource?.token == desiredSource.token) {
            _onStateChanged?.call();
          }
          return;
        }
        _installedSourceToken = desiredSource.token;
        _activePlayCommandToken = null;
        _lastPlayAttemptRevision = -1;
        sourceChanged = true;
        _notifyIfCurrent(commandRevision);
      }

      if (_desiredSeek != null &&
          _appliedSeekRevision != _seekRevision &&
          _installedSourceToken == _desiredSource?.token) {
        final position = _desiredSeek!;
        final seekRevision = _seekRevision;
        await _player.seek(position);
        _appliedSeekRevision = seekRevision;
        _notifyIfCurrent(commandRevision);
      }

      final sourceReady = _desiredSource != null &&
          _installedSourceToken == _desiredSource!.token;
      if (forcePause || !_effectivePlaying) {
        if (_player.playing || _activePlayCommandToken != null) {
          await _player.pause();
          _activePlayCommandToken = null;
          _notifyIfCurrent(commandRevision);
        }
        return;
      }

      if (!sourceReady) return;

      if ((sourceChanged || !_player.playing) &&
          _activePlayCommandToken == null) {
        if (_failedPlayIntentRevision == _intentRevision &&
            _failedPlaySourceToken == _installedSourceToken) {
          return;
        }
        if (_lastPlayAttemptRevision == _revision) return;
        _lastPlayAttemptRevision = _revision;
        final playToken = ++_playCommandToken;
        _activePlayCommandToken = playToken;
        try {
          final lifecycle = _player.play();
          _notifyIfCurrent(commandRevision);
          unawaited(lifecycle.then(
            (_) => _onPlayLifecycleComplete(playToken),
            onError: (Object error, StackTrace stackTrace) {
              _onPlayLifecycleError(playToken, error, stackTrace);
            },
          ));
        } catch (error, stackTrace) {
          _onPlayLifecycleError(playToken, error, stackTrace);
        }
      }
    } catch (error, stackTrace) {
      _onError?.call('reconcile', error, stackTrace);
      _notifyIfCurrent(commandRevision);
    }

    _notifyIfCurrent(commandRevision);

    if (commandRevision != _revision) await _reconcile(_revision);
  }

  void _onPlayLifecycleComplete(int token) {
    if (_activePlayCommandToken == token) {
      _activePlayCommandToken = null;
    }
    _markDirty();
  }

  void _onPlayLifecycleError(
    int token,
    Object error,
    StackTrace stackTrace,
  ) {
    if (_activePlayCommandToken == token) {
      _activePlayCommandToken = null;
      _failedPlayIntentRevision = _intentRevision;
      _failedPlaySourceToken = _installedSourceToken;
      _onError?.call('play', error, stackTrace);
      _onStateChanged?.call();
    }
    _markDirty();
  }

  void _notifyIfCurrent(int commandRevision) {
    if (commandRevision == _revision) _onStateChanged?.call();
  }
}

class _DesiredSource {
  final int token;
  final String mediaId;
  final int queueIndex;
  final Duration position;
  AudioSource? source;

  _DesiredSource({
    required this.token,
    required this.mediaId,
    required this.queueIndex,
    required this.position,
  });
}
