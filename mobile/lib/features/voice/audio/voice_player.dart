import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'voice_audio_errors.dart';

/// Plays one MP3 reply at a time from memory.
///
/// Jarvis writes no audio file. On Android, playback uses audioplayers'
/// BytesSource through the platform's in-memory byte source.
abstract interface class VoicePlayer {
  /// Completes only when playback reaches its natural end. Throws
  /// [VoicePlayerException]: `stopped` if stop()/dispose() ended it, `busy` if
  /// another playback is active, `playbackFailed` if the platform failed.
  Future<void> play(Uint8List mp3);

  /// Stops the active playback, if any. Idempotent.
  Future<void> stop();

  /// Stops and releases everything. Idempotent.
  Future<void> dispose();
}

final voicePlayerProvider = Provider<VoicePlayer>((ref) {
  final player = AudioplayersVoicePlayer();
  ref.onDispose(() => unawaited(player.dispose()));
  return player;
});

/// [VoicePlayer] backed by the `audioplayers` package, one [AudioPlayer] per
/// playback, so events from an earlier playback can never reach a later one.
class AudioplayersVoicePlayer implements VoicePlayer {
  AudioplayersVoicePlayer({AudioPlayer Function()? createPlayer})
    : _createPlayer = createPlayer ?? AudioPlayer.new {
    // The package prints its errors by default, including a description of the
    // source derived from the audio bytes. Nothing audio-derived may be logged.
    AudioLogger.logLevel = AudioLogLevel.none;
  }

  static const mimeType = 'audio/mpeg';

  final AudioPlayer Function() _createPlayer;
  _Playback? _active;
  bool _disposed = false;

  @override
  Future<void> play(Uint8List mp3) async {
    if (_disposed) {
      throw const VoicePlayerException(VoicePlayerFailure.disposed);
    }
    if (_active != null) {
      throw const VoicePlayerException(VoicePlayerFailure.busy);
    }
    final playback = _Playback(_createPlayer());
    _active = playback;
    // Listen before starting, so neither completion nor an error can be missed.
    // One subscription to the raw event stream: onPlayerComplete is a filtered
    // view of it that also carries its errors, so listening there without an
    // error handler would leave platform errors unhandled.
    playback.subscriptions.add(
      playback.player.eventStream.listen(
        (event) {
          if (event.eventType == AudioEventType.complete) {
            _settle(playback);
          }
        },
        onError: (Object _) =>
            _settle(playback, failure: VoicePlayerFailure.playbackFailed),
      ),
    );
    try {
      await playback.player.play(BytesSource(mp3, mimeType: mimeType));
    } on Object {
      _settle(playback, failure: VoicePlayerFailure.playbackFailed);
    }
    // Resolves on natural completion only (see _settle).
    return playback.done.future;
  }

  @override
  Future<void> stop() async {
    final playback = _active;
    if (playback == null) {
      return;
    }
    try {
      await playback.player.stop();
    } on Object {
      // Best effort: the playback is settled and released regardless.
    }
    _settle(playback, failure: VoicePlayerFailure.stopped);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await stop();
  }

  /// Settles [playback] once; later events for it are ignored.
  void _settle(_Playback playback, {VoicePlayerFailure? failure}) {
    if (playback.done.isCompleted) {
      return;
    }
    if (identical(_active, playback)) {
      _active = null;
    }
    if (failure == null) {
      playback.done.complete();
    } else {
      playback.done.completeError(VoicePlayerException(failure));
    }
    unawaited(playback.release());
  }
}

/// One playback and the resources it owns.
class _Playback {
  _Playback(this.player) {
    // Settling can happen before the caller has started awaiting; this marks
    // the error as observed while still delivering it to the caller.
    done.future.ignore();
  }

  final AudioPlayer player;
  final Completer<void> done = Completer<void>();
  final List<StreamSubscription<Object?>> subscriptions = [];

  Future<void> release() async {
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    subscriptions.clear();
    try {
      await player.dispose();
    } on Object {
      // Nothing more can be done for a player being discarded.
    }
  }
}
