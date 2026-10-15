import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../auth/application/auth_controller.dart';
import '../../auth/application/auth_state.dart';
import '../audio/voice_audio_errors.dart';
import '../audio/voice_audio_format.dart';
import '../audio/voice_player.dart';
import '../audio/voice_recorder.dart';
import '../data/voice_api.dart';
import 'voice_conversation_state.dart';

final voiceApiProvider = Provider<VoiceApi>(
  (ref) => VoiceApi(ref.watch(apiClientProvider)),
);

/// App-level and kept alive: whatever triggers a conversation (the voice
/// button now, a system assistant session later) drives the same instance.
final voiceConversationControllerProvider =
    NotifierProvider<VoiceConversationController, VoiceConversationState>(
      VoiceConversationController.new,
    );

/// One spoken exchange at a time: record, send, play the reply.
///
/// Trigger-independent: no widgets, no BuildContext. [start], [stop] and
/// [cancel] never throw; every outcome is published as state. Nothing is
/// logged or kept: the recording and the reply exist only while in use.
class VoiceConversationController extends Notifier<VoiceConversationState> {
  late VoiceRecorder _recorder;
  late VoicePlayer _player;

  /// Identifies the current conversation. Every await is followed by a check
  /// against it; a continuation of an older conversation changes nothing.
  /// Incremented synchronously, before any cleanup, by start, cancel, reset
  /// and disposal.
  int _generation = 0;

  /// From start until the microphone is actually capturing. Private: the
  /// public state stays [VoiceIdle] until recording really begins.
  bool _starting = false;

  /// A native recorder start still in flight, of any conversation. Only one
  /// runs at a time, and the recorder is never cancelled while one runs: the
  /// start's own continuation cancels it if it was invalidated meanwhile.
  Future<void>? _recorderStart;

  @override
  VoiceConversationState build() {
    _recorder = ref.read(voiceRecorderProvider);
    _player = ref.read(voicePlayerProvider);
    ref.listen(authControllerProvider, (previous, next) {
      if (previous is AuthAuthenticated && next is! AuthAuthenticated) {
        unawaited(_reset());
      }
    });
    ref.onDispose(() {
      _invalidate();
      unawaited(_releaseAudio());
    });
    return const VoiceIdle();
  }

  /// Starts recording. From [VoicePlaying], stops the reply first. Ignored
  /// while starting, recording or processing.
  Future<void> start() async {
    if (_starting) {
      return;
    }
    switch (state) {
      case VoiceIdle():
        await _startFor(_begin());
      case VoicePlaying():
        final generation = _begin();
        await _stopPlayback();
        if (_isCurrent(generation)) {
          await _startFor(generation);
        }
      case VoiceRecording() || VoiceProcessing():
        return;
    }
  }

  /// Ends the recording and sends it. Released before the microphone started
  /// (for example during the permission prompt), it silently abandons the
  /// start. Ignored otherwise.
  Future<void> stop() async {
    if (_starting) {
      _invalidate();
      _publish(const VoiceIdle());
      return;
    }
    await _stopFor(_generation);
  }

  /// Abandons whatever is in progress and clears any failure. A request
  /// already sent may still finish; its result is ignored.
  Future<void> cancel() async {
    if (!_starting && state == const VoiceIdle()) {
      return;
    }
    await _reset();
  }

  /// A new conversation: invalidates the previous one and clears any failure.
  int _begin() {
    _invalidate();
    _starting = true;
    _publish(const VoiceIdle());
    return _generation;
  }

  Future<void> _startFor(int generation) async {
    final bool granted;
    try {
      granted = await _recorder.ensurePermission();
    } on Object {
      _end(generation, VoiceConversationFailure.unexpected);
      return;
    }
    if (!_isCurrent(generation)) {
      return;
    }
    if (!granted) {
      _end(generation, VoiceConversationFailure.permissionDenied);
      return;
    }
    // An invalidated start may still be finishing; wait for it to cancel.
    for (var pending = _recorderStart; pending != null;) {
      await pending;
      pending = _recorderStart;
      if (!_isCurrent(generation)) {
        return;
      }
    }
    final done = Completer<void>();
    _recorderStart = done.future;
    try {
      await _startRecorder(generation);
    } finally {
      _recorderStart = null;
      done.complete();
    }
  }

  Future<void> _startRecorder(int generation) async {
    try {
      await _recorder.start(
        onLimitReached: () => unawaited(_stopFor(generation)),
      );
    } on Object catch (error) {
      if (!_isCurrent(generation)) {
        return; // a failed start leaves nothing to release
      }
      if (error case VoiceRecorderException(
        failure: VoiceRecorderFailure.startFailed,
      )) {
        _end(generation, VoiceConversationFailure.microphoneFailed);
        return;
      }
      await _cancelRecorder();
      _end(generation, VoiceConversationFailure.unexpected);
      return;
    }
    if (!_isCurrent(generation)) {
      await _cancelRecorder();
      return;
    }
    _starting = false;
    state = const VoiceRecording();
  }

  /// The single stop path, for a manual stop and the recording limit alike.
  Future<void> _stopFor(int generation) async {
    if (!_isCurrent(generation) || state is! VoiceRecording) {
      return;
    }
    // Synchronously, so a second stop (manual or limit) finds nothing to do.
    state = const VoiceProcessing();
    // Read before awaiting: the provider may be disposed by then.
    final api = ref.read(voiceApiProvider);
    final auth = ref.read(authControllerProvider.notifier);

    final mp3 = await _replyFor(generation, api, auth);
    if (mp3 == null || !_isCurrent(generation)) {
      return;
    }
    state = const VoicePlaying();
    try {
      await _player.play(mp3);
    } on VoicePlayerException catch (error) {
      switch (error.failure) {
        case VoicePlayerFailure.stopped:
          _end(generation);
        case VoicePlayerFailure.playbackFailed:
          _end(generation, VoiceConversationFailure.playbackFailed);
        case VoicePlayerFailure.busy || VoicePlayerFailure.disposed:
          if (_isCurrent(generation)) {
            await _stopPlayback();
          }
          _end(generation, VoiceConversationFailure.unexpected);
      }
      return;
    } on Object {
      _end(generation, VoiceConversationFailure.unexpected);
      return;
    }
    _end(generation);
  }

  /// Stops the recording and returns the spoken reply, or null when the
  /// conversation ended (failure published) or was invalidated. The recording
  /// is referenced only here.
  Future<Uint8List?> _replyFor(
    int generation,
    VoiceApi api,
    AuthController auth,
  ) async {
    final Uint8List wav;
    try {
      wav = await _recorder.stop();
    } on VoiceRecorderException catch (error) {
      _end(generation, _recorderFailure(error.failure));
      return null;
    } on Object {
      _end(generation, VoiceConversationFailure.unexpected);
      return null;
    }
    if (!_isCurrent(generation)) {
      return null;
    }
    final pcmBytes = wav.length - VoiceAudioFormat.wavHeaderBytes;
    if (pcmBytes < 0) {
      _end(generation, VoiceConversationFailure.unexpected);
      return null;
    }
    if (pcmBytes < VoiceAudioFormat.minPcmBytes) {
      _end(generation, VoiceConversationFailure.tooShort);
      return null;
    }
    try {
      return await api.respond(wav);
    } on VoiceException catch (error) {
      if (!_isCurrent(generation)) {
        return null;
      }
      if (error.failure == VoiceFailure.sessionExpired) {
        await _expireSession(generation, auth);
        return null;
      }
      _end(generation, _apiFailure(error.failure));
      return null;
    } on Object {
      _end(generation, VoiceConversationFailure.unexpected);
      return null;
    }
  }

  /// The session is invalid whether or not anything shows it. The router
  /// moves to login; no voice failure is shown.
  Future<void> _expireSession(int generation, AuthController auth) async {
    try {
      await auth.sessionExpired();
    } on Object {
      // The auth state reflects any failure to remove the session.
    }
    // Normally the auth listener has already reset; this covers the rest.
    if (_isCurrent(generation)) {
      await _reset();
    }
  }

  /// Invalidates the current conversation and publishes idle synchronously,
  /// then releases the microphone and player.
  Future<void> _reset() async {
    _invalidate();
    _publish(const VoiceIdle());
    await _releaseAudio();
  }

  void _invalidate() {
    _generation++;
    _starting = false;
  }

  /// Best effort; never throws.
  Future<void> _releaseAudio() async {
    if (_recorderStart == null) {
      await _cancelRecorder();
    }
    await _stopPlayback();
  }

  Future<void> _cancelRecorder() async {
    try {
      await _recorder.cancel();
    } on Object {
      // Nothing more can be done; nothing is kept either way.
    }
  }

  Future<void> _stopPlayback() async {
    try {
      await _player.stop();
    } on Object {
      // The player settles and releases its playback regardless.
    }
  }

  /// Ends the current conversation as idle, with [failure] if given. Does
  /// nothing for an invalidated one.
  void _end(int generation, [VoiceConversationFailure? failure]) {
    if (!_isCurrent(generation)) {
      return;
    }
    _starting = false;
    state = VoiceIdle(failure);
  }

  void _publish(VoiceConversationState next) {
    if (state != next) {
      state = next;
    }
  }

  bool _isCurrent(int generation) => ref.mounted && generation == _generation;

  static VoiceConversationFailure _recorderFailure(
    VoiceRecorderFailure failure,
  ) => switch (failure) {
    VoiceRecorderFailure.startFailed ||
    VoiceRecorderFailure.captureFailed ||
    VoiceRecorderFailure.stopFailed =>
      VoiceConversationFailure.microphoneFailed,
    VoiceRecorderFailure.unsupportedAudio =>
      VoiceConversationFailure.unsupportedAudio,
    VoiceRecorderFailure.alreadyRecording ||
    VoiceRecorderFailure.notRecording ||
    VoiceRecorderFailure.disposed => VoiceConversationFailure.unexpected,
  };

  static VoiceConversationFailure _apiFailure(VoiceFailure failure) =>
      switch (failure) {
        // Handled by the auth flow before mapping; listed for exhaustiveness.
        VoiceFailure.sessionExpired => VoiceConversationFailure.unexpected,
        VoiceFailure.invalidAudio => VoiceConversationFailure.invalidAudio,
        VoiceFailure.noSpeech => VoiceConversationFailure.noSpeech,
        VoiceFailure.rejected => VoiceConversationFailure.rejected,
        VoiceFailure.busy => VoiceConversationFailure.busy,
        VoiceFailure.notAvailable => VoiceConversationFailure.notAvailable,
        VoiceFailure.unavailable => VoiceConversationFailure.unavailable,
        VoiceFailure.tooSlow => VoiceConversationFailure.tooSlow,
        VoiceFailure.network => VoiceConversationFailure.network,
        VoiceFailure.unexpected => VoiceConversationFailure.unexpected,
      };
}
