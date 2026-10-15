import 'package:flutter/foundation.dart';

/// Why a voice conversation ended without a spoken reply. Presentation turns
/// these into messages; nothing here carries audio, text, sizes or durations.
///
/// There is no session-expired value: that is handled by the auth flow.
enum VoiceConversationFailure {
  /// Microphone access was refused (including "don't ask again").
  permissionDenied,

  /// The microphone could not be started, read or stopped.
  microphoneFailed,

  /// The device delivered audio in a format other than 16 kHz mono PCM.
  unsupportedAudio,

  /// The recording was shorter than the minimum; it was not sent.
  tooShort,

  /// The backend did not accept the recording.
  invalidAudio,

  /// The backend found no recognisable speech.
  noSpeech,

  /// The assistant declined the request.
  rejected,

  /// Too many requests.
  busy,

  /// The voice assistant is not configured on the backend.
  notAvailable,

  /// The voice assistant failed temporarily.
  unavailable,

  /// No reply in time.
  tooSlow,

  /// The backend could not be reached.
  network,

  /// The reply could not be played.
  playbackFailed,

  /// Anything else.
  unexpected,
}

/// Public state of the voice conversation. Each value is true when published:
/// [VoiceRecording] means the microphone is actually capturing.
@immutable
sealed class VoiceConversationState {
  const VoiceConversationState();
}

/// Nothing in progress. [failure] is why the last conversation ended, if it
/// failed; it stays until the next start or a cancel.
final class VoiceIdle extends VoiceConversationState {
  const VoiceIdle([this.failure]);

  final VoiceConversationFailure? failure;

  @override
  bool operator ==(Object other) =>
      other is VoiceIdle && other.failure == failure;

  @override
  int get hashCode => Object.hash(VoiceIdle, failure);

  @override
  String toString() => 'VoiceIdle(${failure?.name ?? ''})';
}

final class VoiceRecording extends VoiceConversationState {
  const VoiceRecording();

  @override
  String toString() => 'VoiceRecording()';
}

/// The recording is being sent and the reply prepared.
final class VoiceProcessing extends VoiceConversationState {
  const VoiceProcessing();

  @override
  String toString() => 'VoiceProcessing()';
}

/// The spoken reply is playing.
final class VoicePlaying extends VoiceConversationState {
  const VoicePlaying();

  @override
  String toString() => 'VoicePlaying()';
}
