import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

typedef PlaybackMutationError = void Function(
  String operation,
  Object error,
  StackTrace stackTrace,
);
typedef PrepareForPlayback = Future<void> Function();

const minimumResolvedAudioDuration = Duration(seconds: 15);

final class ResolvedAudioTooShortException implements Exception {
  const ResolvedAudioTooShortException(this.duration);

  final Duration duration;

  @override
  String toString() => 'Resolved audio is only ${duration.inMilliseconds}ms; '
      'minimum is ${minimumResolvedAudioDuration.inSeconds}s';
}

sealed class SourceCommitResult {
  const SourceCommitResult();
}

final class SourceCommitInstalled extends SourceCommitResult {
  const SourceCommitInstalled();
}

final class SourceCommitStale extends SourceCommitResult {
  final bool nativeInstallApplied;

  const SourceCommitStale({this.nativeInstallApplied = false});
}

final class SourceCommitFailed extends SourceCommitResult {
  final Object error;
  final StackTrace stackTrace;

  const SourceCommitFailed(this.error, this.stackTrace);
}

final class PreservingPauseOwner {
  final int _intentRevision;
  final int? _sourceToken;

  PreservingPauseOwner._(this._intentRevision, this._sourceToken);
}

class PlaybackCommandCoordinator {
  final AudioPlayer _player;
  final VoidCallback? _onStateChanged;
  final PlaybackMutationError? _onError;
  final PrepareForPlayback? _prepareForPlayback;
  final Duration _sourceLoadTimeout;

  Future<void> _tail = Future<void>.value();
  int _pendingReconciliations = 0;
  int _revision = 0;
  int _sourceToken = 0;
  _DesiredSource? _desiredSource;
  int? _installedSourceToken;
  int? _temporarySourceToken;
  bool _stopDesired = false;
  bool _stopApplied = false;
  bool _desiredPlaying = false;
  final Set<PreservingPauseOwner> _preservingPauseOwners = {};
  int _intentRevision = 0;
  int? _resumeDeniedIntentRevision;
  int _interruptionDepth = 0;
  bool _interruptionMayResume = true;
  int _interruptionBeginIntentRevision = 0;
  int _seekRevision = 0;
  int _appliedSeekRevision = 0;
  int _failedSeekRevision = 0;
  Duration? _desiredSeek;
  LoopMode? _desiredLoopMode;
  LoopMode? _appliedLoopMode;
  bool? _desiredShuffleEnabled;
  bool? _appliedShuffleEnabled;
  int _playCommandToken = 0;
  int? _activePlayCommandToken;
  final Map<int, _PlayEndReason> _playEndReasons = {};
  final Map<int, int> _playSourceTokens = {};
  int _lastPlayAttemptRevision = -1;
  int? _failedPlayIntentRevision;
  int? _failedPlaySourceToken;
  int? _failedSourceToken;
  SourceCommitFailed? _failedSourceCommit;
  bool _shutdown = false;
  bool _stoppingAndWaiting = false;
  Object? _shutdownError;
  StackTrace? _shutdownStackTrace;

  PlaybackCommandCoordinator(
    this._player, {
    VoidCallback? onStateChanged,
    PlaybackMutationError? onError,
    PrepareForPlayback? prepareForPlayback,
    Duration sourceLoadTimeout = const Duration(seconds: 20),
  })  : _onStateChanged = onStateChanged,
        _onError = onError,
        _prepareForPlayback = prepareForPlayback,
        _sourceLoadTimeout = sourceLoadTimeout;

  int get sourceToken => _sourceToken;
  int? get desiredSourceToken => _desiredSource?.token;
  int? get desiredSourceOccurrenceId => _desiredSource?.occurrenceId;
  int? get installedSourceToken => _installedSourceToken;
  bool get installedSourceIsAuthoritative =>
      _installedSourceToken != null &&
      _installedSourceToken == _desiredSource?.token;
  int get intentRevision => _intentRevision;
  int get interruptionDepth => _interruptionDepth;
  bool get interruptionActive => _interruptionDepth > 0;
  bool get desiredPlayingIntent =>
      _desiredPlaying &&
      (_resumeDeniedIntentRevision == null ||
          _intentRevision > _resumeDeniedIntentRevision!);
  bool get effectivePlaying => _effectivePlaying;
  Future<void> get settled => _tail;

  int requestSource({
    required int occurrenceId,
    required Duration position,
  }) {
    if (_shutdown) return -1;
    final token = ++_sourceToken;
    _desiredSource = _DesiredSource(
      token: token,
      occurrenceId: occurrenceId,
      position: position,
    );
    _failedSourceToken = null;
    _failedSourceCommit = null;
    _stopDesired = false;
    _stopApplied = false;
    _desiredSeek = null;
    _appliedSeekRevision = _seekRevision;
    _markDirty();
    return token;
  }

  bool ownsSourceRequest(int token, int occurrenceId) {
    if (_shutdown) return false;
    final desired = _desiredSource;
    return desired?.token == token && desired?.occurrenceId == occurrenceId;
  }

  Future<SourceCommitResult> commitSource(int token, AudioSource source) async {
    if (_shutdown) return const SourceCommitStale();
    final desired = _desiredSource;
    if (desired == null || desired.token != token) {
      return const SourceCommitStale();
    }
    desired.source = source;
    await _markDirty(awaitApplication: true);
    if (_desiredSource?.token != token) {
      return SourceCommitStale(
        nativeInstallApplied: _installedSourceToken == token,
      );
    }
    if (_installedSourceToken == token) return const SourceCommitInstalled();
    return _failedSourceToken == token && _failedSourceCommit != null
        ? _failedSourceCommit!
        : const SourceCommitStale();
  }

  Future<bool> installTemporarySource(int token, AudioSource source) async {
    if (_shutdown || _desiredSource?.token != token) return false;
    final previous = _tail;
    _pendingReconciliations++;
    final next = () async {
      await previous;
      if (_shutdown || _desiredSource?.token != token) return false;
      try {
        await _player
            .setAudioSource(source, initialPosition: Duration.zero)
            .timeout(_sourceLoadTimeout);
      } catch (error, stackTrace) {
        if (error is TimeoutException) {
          try {
            await _player.stop();
          } catch (_) {}
        }
        _onError?.call('temporarySource', error, stackTrace);
        return false;
      }
      // Native silence replaced the previous source even if this request is
      // already stale. Clear the old authoritative token so bookkeeping cannot
      // claim the previous track is still installed.
      _installedSourceToken = null;
      _activePlayCommandToken = null;
      _lastPlayAttemptRevision = -1;
      if (_shutdown || _desiredSource?.token != token) {
        if (_temporarySourceToken == token) {
          _temporarySourceToken = null;
        }
        _onStateChanged?.call();
        return false;
      }
      _temporarySourceToken = token;
      if (_effectivePlaying && !_player.playing) {
        final playToken = ++_playCommandToken;
        _activePlayCommandToken = playToken;
        _playSourceTokens[playToken] = token;
        try {
          final prepareForPlayback = _prepareForPlayback;
          if (prepareForPlayback != null) await prepareForPlayback();
          final lifecycle = _player.play();
          unawaited(lifecycle.then(
            (_) => _onPlayLifecycleComplete(playToken),
            onError: (Object error, StackTrace stackTrace) {
              _onPlayLifecycleError(playToken, error, stackTrace);
            },
          ));
        } catch (error, stackTrace) {
          _onPlayLifecycleError(playToken, error, stackTrace);
          return false;
        }
      }
      _onStateChanged?.call();
      return true;
    }();
    final tracked = next.whenComplete(() => _pendingReconciliations--);
    _tail = tracked.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return tracked;
  }

  Future<void> discardTemporarySource(int token) async {
    if (_shutdown || _temporarySourceToken != token) return;
    final previous = _tail;
    _pendingReconciliations++;
    final next = () async {
      await previous;
      if (_shutdown || _temporarySourceToken != token) return;
      final playToken = _activePlayCommandToken;
      if (playToken != null) {
        _playEndReasons[playToken] = _PlayEndReason.pause;
      }
      if (_player.playing || playToken != null) await _player.pause();
      _temporarySourceToken = null;
      _activePlayCommandToken = null;
      _onStateChanged?.call();
    }();
    final tracked = next.whenComplete(() => _pendingReconciliations--);
    _tail = tracked.catchError((Object _, StackTrace __) {});
    await tracked;
  }

  Future<void> recordExplicitPlayIntent() {
    if (_shutdown) return Future<void>.value();
    _intentRevision++;
    _desiredPlaying = true;
    _stopDesired = false;
    _retireInactivePlayLifecycle();
    _failedPlayIntentRevision = null;
    _failedPlaySourceToken = null;
    if (_failedSourceToken == _desiredSource?.token) {
      _failedSourceToken = null;
      _failedSourceCommit = null;
      _installedSourceToken = null;
      _temporarySourceToken = null;
    }
    _retirePausedPlayLifecycle();
    return _markDirty();
  }

  Future<void> recordExplicitPauseIntent() {
    if (_shutdown) return Future<void>.value();
    _intentRevision++;
    _desiredPlaying = false;
    return _markDirty();
  }

  Future<PreservingPauseOwner> pausePreservingIntent() async {
    if (_shutdown) return PreservingPauseOwner._(_intentRevision, null);
    final owner = PreservingPauseOwner._(
      _intentRevision,
      _desiredSource?.token,
    );
    _preservingPauseOwners.add(owner);
    await _markDirty(awaitApplication: true);
    return owner;
  }

  Future<void> releasePreservingIntent(
    PreservingPauseOwner owner, {
    bool stopIfStillOwnsIntent = false,
  }) {
    if (_shutdown) return Future<void>.value();
    if (!_preservingPauseOwners.remove(owner)) return settled;
    if (stopIfStillOwnsIntent &&
        owner._intentRevision == _intentRevision &&
        owner._sourceToken == _desiredSource?.token) {
      _desiredPlaying = false;
    }
    if (_preservingPauseOwners.isEmpty) _retirePausedPlayLifecycle();
    return _markDirty();
  }

  Future<void> setDesiredPlayingPreservingIntent(bool playing) {
    if (_shutdown) return Future<void>.value();
    _desiredPlaying = playing;
    if (playing) {
      _retirePausedPlayLifecycle();
    }
    return _markDirty();
  }

  Future<void> clearPreservingPauseOwners() {
    if (_shutdown) return Future<void>.value();
    if (_preservingPauseOwners.isEmpty) return settled;
    _preservingPauseOwners.clear();
    _retirePausedPlayLifecycle();
    return _markDirty();
  }

  Future<void> reconcilePlayingIntent() =>
      _shutdown ? Future<void>.value() : _markDirty();

  Future<void> recoverIdleSource() {
    if (_shutdown) return Future<void>.value();
    _installedSourceToken = null;
    _temporarySourceToken = null;
    _activePlayCommandToken = null;
    return _markDirty();
  }

  Future<void> stop() {
    if (_shutdown) return settle();
    _prepareStop();
    return _markDirty();
  }

  Future<void> stopAndWait() async {
    if (_shutdown) {
      await settle();
      if (_shutdownError case final error?) {
        Error.throwWithStackTrace(error, _shutdownStackTrace!);
      }
      return;
    }
    _shutdown = true;
    _stoppingAndWaiting = true;
    _shutdownError = null;
    _shutdownStackTrace = null;
    _prepareStop();
    try {
      await _markDirty(awaitApplication: true);
      await settle();
      if (_shutdownError case final error?) {
        Error.throwWithStackTrace(error, _shutdownStackTrace!);
      }
    } finally {
      _stoppingAndWaiting = false;
    }
  }

  Future<void> settle() async {
    while (true) {
      final tail = _tail;
      await tail;
      if (identical(tail, _tail)) return;
    }
  }

  void _prepareStop() {
    _intentRevision++;
    _desiredPlaying = false;
    _desiredSource = null;
    _stopDesired = true;
    _stopApplied = false;
    _sourceToken++;
  }

  Future<bool> seek(Duration position) async {
    if (_shutdown) return false;
    _desiredSeek = position;
    final revision = ++_seekRevision;
    await _markDirty(awaitApplication: true);
    return _appliedSeekRevision == revision;
  }

  Future<void> setLoopMode(LoopMode mode) {
    if (_shutdown) return Future<void>.value();
    _desiredLoopMode = mode;
    return _markDirty();
  }

  Future<void> setShuffleModeEnabled(bool enabled) {
    if (_shutdown) return Future<void>.value();
    _desiredShuffleEnabled = enabled;
    return _markDirty();
  }

  Future<void> beginInterruption() {
    if (_shutdown) return Future<void>.value();
    if (_interruptionDepth == 0) {
      _interruptionMayResume = true;
      _interruptionBeginIntentRevision = _intentRevision;
    }
    _interruptionDepth++;
    return _markDirty();
  }

  Future<void> endInterruption({
    required bool mayResume,
    bool allowAutomaticResume = true,
  }) {
    if (_shutdown) return Future<void>.value();
    if (_interruptionDepth == 0) return settled;
    if (!mayResume) _interruptionMayResume = false;
    _interruptionDepth--;
    if (_interruptionDepth == 0) {
      final hasNewExplicitPlay =
          _desiredPlaying && _intentRevision > _interruptionBeginIntentRevision;
      if (!_interruptionMayResume ||
          (!allowAutomaticResume && !hasNewExplicitPlay)) {
        _resumeDeniedIntentRevision = _intentRevision;
      }
      _interruptionMayResume = true;
    }
    return _markDirty();
  }

  Future<void> becomingNoisy() {
    if (_shutdown) return Future<void>.value();
    _retireInactivePlayLifecycle();
    _interruptionDepth = 0;
    _interruptionMayResume = true;
    _intentRevision++;
    _desiredPlaying = false;
    _resumeDeniedIntentRevision = _intentRevision;
    return _markDirty();
  }

  Future<void> _markDirty({
    bool awaitApplication = false,
  }) {
    final revision = ++_revision;
    final previous = _tail;
    final queuedBehindMutation = _pendingReconciliations > 0;
    _pendingReconciliations++;
    final next = () async {
      await previous;
      await _reconcile(revision);
    }();
    final tracked = next.whenComplete(() => _pendingReconciliations--);
    _tail = tracked.catchError((Object _, StackTrace __) {});
    return awaitApplication || !queuedBehindMutation
        ? tracked
        : Future<void>.value();
  }

  bool get _effectivePlaying =>
      desiredPlayingIntent &&
      _preservingPauseOwners.isEmpty &&
      !interruptionActive;

  Future<void> _reconcile(int commandRevision) async {
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
        if (!_stopApplied &&
            (_installedSourceToken != null ||
                _player.playing ||
                _player.processingState != ProcessingState.idle)) {
          final playToken = _activePlayCommandToken;
          if (playToken != null) {
            _playEndReasons[playToken] = _PlayEndReason.stop;
          }
          _stopApplied = true;
          await _player.stop();
        }
        _stopApplied = true;
        _installedSourceToken = null;
        _temporarySourceToken = null;
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
          final duration = await _player
              .setAudioSource(
                desiredSource.source!,
                initialPosition: desiredSource.position,
              )
              .timeout(_sourceLoadTimeout);
          if (duration != null && duration < minimumResolvedAudioDuration) {
            throw ResolvedAudioTooShortException(duration);
          }
        } catch (error, stackTrace) {
          // just_audio assigns audioSource before native loading completes, so
          // object identity cannot prove that AVPlayer accepted the media.
          _failedSourceToken = desiredSource.token;
          _failedSourceCommit = SourceCommitFailed(error, stackTrace);
          if (_installedSourceToken == desiredSource.token) {
            _installedSourceToken = null;
          }
          if (error is TimeoutException ||
              error is ResolvedAudioTooShortException) {
            try {
              await _player.stop();
            } catch (_) {}
          }
          if (_desiredSource?.token == desiredSource.token) {
            _onStateChanged?.call();
          }
          return;
        }
        _installedSourceToken = desiredSource.token;
        _temporarySourceToken = null;
        _activePlayCommandToken = null;
        _lastPlayAttemptRevision = -1;
        sourceChanged = true;
        _notifyIfCurrent(commandRevision);
        if (_desiredSource?.token != desiredSource.token) {
          await _reconcile(_revision);
          return;
        }
      }

      if (_desiredSeek != null &&
          _appliedSeekRevision != _seekRevision &&
          _failedSeekRevision != _seekRevision &&
          _installedSourceToken == _desiredSource?.token) {
        final position = _desiredSeek!;
        final seekRevision = _seekRevision;
        try {
          await _player.seek(position);
          _appliedSeekRevision = seekRevision;
        } catch (error, stackTrace) {
          _failedSeekRevision = seekRevision;
          _onError?.call('seek', error, stackTrace);
        }
        _notifyIfCurrent(commandRevision);
      }

      final sourceReady = desiredSource != null &&
          (_installedSourceToken == desiredSource.token ||
              _temporarySourceToken == desiredSource.token);
      if (!_effectivePlaying) {
        if (_player.playing || _activePlayCommandToken != null) {
          final playToken = _activePlayCommandToken;
          if (playToken != null) {
            _playEndReasons[playToken] = _preservingPauseOwners.isNotEmpty
                ? _PlayEndReason.preservingPause
                : _PlayEndReason.pause;
          }
          await _player.pause();
          _notifyIfCurrent(commandRevision);
        }
        return;
      }

      if (!sourceReady) return;

      if ((sourceChanged || !_player.playing) &&
          _activePlayCommandToken == null) {
        final playableSourceToken =
            _installedSourceToken ?? _temporarySourceToken;
        if (playableSourceToken == null) return;
        if (_failedPlayIntentRevision == _intentRevision &&
            _failedPlaySourceToken == playableSourceToken) {
          return;
        }
        if (_lastPlayAttemptRevision == _revision) return;
        _lastPlayAttemptRevision = _revision;
        final playToken = ++_playCommandToken;
        _activePlayCommandToken = playToken;
        _playSourceTokens[playToken] = playableSourceToken;
        try {
          final prepareForPlayback = _prepareForPlayback;
          if (prepareForPlayback != null) await prepareForPlayback();
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
      if (_stoppingAndWaiting) {
        _shutdownError ??= error;
        _shutdownStackTrace ??= stackTrace;
      }
      _onError?.call('reconcile', error, stackTrace);
      _notifyIfCurrent(commandRevision);
    }

    _notifyIfCurrent(commandRevision);

    if (commandRevision != _revision) await _reconcile(_revision);
  }

  void _onPlayLifecycleComplete(int token) {
    final ownsLifecycle = _ownsPlayLifecycle(token);
    final reason = _playEndReasons.remove(token) ??
        (_player.processingState == ProcessingState.completed
            ? _PlayEndReason.completed
            : _PlayEndReason.unknown);
    if (!ownsLifecycle) {
      _playSourceTokens.remove(token);
      return;
    }
    _playSourceTokens.remove(token);
    _activePlayCommandToken = null;
    if (reason == _PlayEndReason.completed || reason == _PlayEndReason.stop) {
      return;
    }
    _markDirty();
  }

  void _onPlayLifecycleError(
    int token,
    Object error,
    StackTrace stackTrace,
  ) {
    final ownsLifecycle = _ownsPlayLifecycle(token);
    _playEndReasons.remove(token);
    if (!ownsLifecycle) {
      _playSourceTokens.remove(token);
      return;
    }
    _playSourceTokens.remove(token);
    _activePlayCommandToken = null;
    final failedSourceToken = _installedSourceToken ?? _temporarySourceToken;
    _failedPlayIntentRevision = _intentRevision;
    _failedPlaySourceToken = failedSourceToken;
    _failedSourceToken = failedSourceToken;
    if (_installedSourceToken == failedSourceToken) {
      _installedSourceToken = null;
    }
    if (_temporarySourceToken == failedSourceToken) {
      _temporarySourceToken = null;
    }
    _onError?.call('play', error, stackTrace);
    _onStateChanged?.call();
    _markDirty();
  }

  bool _ownsPlayLifecycle(int token) {
    final sourceToken = _playSourceTokens[token];
    return _activePlayCommandToken == token &&
        sourceToken != null &&
        (sourceToken == _installedSourceToken ||
            sourceToken == _temporarySourceToken) &&
        sourceToken == _desiredSource?.token;
  }

  void _retirePausedPlayLifecycle() {
    final token = _activePlayCommandToken;
    if (token == null) return;
    final reason = _playEndReasons[token];
    if (reason == _PlayEndReason.pause ||
        reason == _PlayEndReason.preservingPause) {
      _invalidateActivePlayLifecycle();
    }
  }

  void _retireInactivePlayLifecycle() {
    if (!_player.playing) _invalidateActivePlayLifecycle();
  }

  void _invalidateActivePlayLifecycle() {
    final token = _activePlayCommandToken;
    if (token == null) return;
    _playEndReasons.remove(token);
    _playSourceTokens.remove(token);
    _activePlayCommandToken = null;
  }

  void _notifyIfCurrent(int commandRevision) {
    if (commandRevision == _revision) _onStateChanged?.call();
  }
}

enum _PlayEndReason { preservingPause, pause, stop, completed, unknown }

class _DesiredSource {
  final int token;
  final int occurrenceId;
  final Duration position;
  AudioSource? source;

  _DesiredSource({
    required this.token,
    required this.occurrenceId,
    required this.position,
  });
}
