import 'dart:async';
import 'dart:typed_data';

import 'package:jarvis/features/voice/audio/voice_audio_errors.dart';
import 'package:jarvis/features/voice/audio/voice_player.dart';
import 'package:jarvis/features/voice/audio/voice_recorder.dart';
import 'package:jarvis/features/voice/audio/wav.dart';
import 'package:jarvis/features/voice/data/voice_api.dart';

/// A WAV holding [pcmBytes] bytes of silence.
Uint8List wavOf(int pcmBytes) => pcm16MonoToWav(Uint8List(pcmBytes));

/// [VoiceRecorder] driven by the test. Each call returns immediately unless
/// its gate is set, in which case it waits for the test to complete the gate.
class FakeVoiceRecorder implements VoiceRecorder {
  final List<String> calls = [];

  bool permission = true;
  Completer<bool>? permissionGate;
  Object? permissionError;

  Completer<void>? startGate;
  Object? startError;

  Completer<Uint8List>? stopGate;
  Object? stopError;
  Uint8List wav = wavOf(32000); // one second

  Object? cancelError;

  void Function()? _onLimitReached;

  int count(String call) => calls.where((c) => c == call).length;

  /// The callback the most recent start received.
  void Function() get limitCallback => _onLimitReached!;

  /// The recorder reaching its limit, as the real adapter reports it.
  void reachLimit() => limitCallback();

  @override
  Future<bool> ensurePermission() async {
    calls.add('ensurePermission');
    if (permissionError case final error?) {
      throw error;
    }
    return permissionGate?.future ?? permission;
  }

  @override
  Future<void> start({required void Function() onLimitReached}) async {
    calls.add('start');
    _onLimitReached = onLimitReached;
    if (startGate case final gate?) {
      await gate.future;
    }
    if (startError case final error?) {
      throw error;
    }
  }

  @override
  Future<Uint8List> stop() async {
    calls.add('stop');
    if (stopGate case final gate?) {
      return gate.future;
    }
    if (stopError case final error?) {
      throw error;
    }
    return wav;
  }

  @override
  Future<void> cancel() async {
    calls.add('cancel');
    if (cancelError case final error?) {
      throw error;
    }
  }

  @override
  Future<void> dispose() async => calls.add('dispose');
}

/// [VoicePlayer] driven by the test: each play stays pending until the test
/// completes or fails it, or stop() ends it as `stopped`.
class FakeVoicePlayer implements VoicePlayer {
  final List<String> calls = [];
  final List<Uint8List> played = [];

  /// When set, stop() waits for it before ending the playback.
  Completer<void>? stopGate;
  Object? stopError;

  /// When set, play() fails immediately with it.
  Object? playError;

  Completer<void>? _playback;

  int count(String call) => calls.where((c) => c == call).length;

  bool get isPlaying => _playback != null;

  /// Natural end of the active playback.
  void complete() => _settle(null);

  /// The active playback ending with [failure].
  void fail(VoicePlayerFailure failure) =>
      _settle(VoicePlayerException(failure));

  void _settle(Object? error) {
    final playback = _playback!;
    _playback = null;
    if (error == null) {
      playback.complete();
    } else {
      playback.completeError(error);
    }
  }

  @override
  Future<void> play(Uint8List mp3) {
    calls.add('play');
    played.add(mp3);
    if (playError case final error?) {
      return Future.error(error);
    }
    final playback = Completer<void>();
    _playback = playback;
    return playback.future;
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    if (stopGate case final gate?) {
      await gate.future;
    }
    if (_playback != null) {
      _settle(const VoicePlayerException(VoicePlayerFailure.stopped));
    }
    if (stopError case final error?) {
      throw error;
    }
  }

  @override
  Future<void> dispose() async => calls.add('dispose');
}

/// [VoiceApi] driven by the test.
class FakeVoiceApi implements VoiceApi {
  final List<Uint8List> requests = [];

  Completer<Uint8List>? gate;
  Object? error;
  Uint8List reply = Uint8List.fromList([0xFF, 0xF3, 1, 2, 3]);

  @override
  Future<Uint8List> respond(Uint8List wav) async {
    requests.add(wav);
    if (gate case final gate?) {
      return gate.future;
    }
    if (error case final error?) {
      throw error;
    }
    return reply;
  }
}
