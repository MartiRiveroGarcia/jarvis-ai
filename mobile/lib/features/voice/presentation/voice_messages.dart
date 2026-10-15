import '../application/voice_conversation_state.dart';

/// Fixed user-facing text for the voice conversation. Nothing here comes from
/// the backend or the platform, and nothing reveals content, sizes or timing.

/// The main status line for [state].
String voiceStatusText(VoiceConversationState state) => switch (state) {
  VoiceIdle() => 'Hold to talk',
  VoiceRecording() => 'Listening…',
  VoiceProcessing() => 'Jarvis is thinking…',
  VoicePlaying() => 'Jarvis is speaking…',
};

/// A secondary instruction for [state], if any. Failures use
/// [voiceFailureMessage] instead.
String? voiceInstructionText(VoiceConversationState state) => switch (state) {
  VoiceRecording() => 'Release to send',
  VoicePlaying() => 'Press to interrupt',
  VoiceIdle() || VoiceProcessing() => null,
};

/// The accessibility hint for [state]; none while processing, when the button
/// is unavailable.
String? voiceSemanticHint(VoiceConversationState state) => switch (state) {
  VoiceIdle() => 'Hold to talk, or double-tap to start',
  VoiceRecording() => 'Double-tap to send',
  VoicePlaying() => 'Double-tap to interrupt',
  VoiceProcessing() => null,
};

/// User-facing text for a failed conversation.
///
/// Permission: Android does not tell the app whether the user denied once or
/// chose "don't ask again", so the text claims neither.
String voiceFailureMessage(
  VoiceConversationFailure failure,
) => switch (failure) {
  VoiceConversationFailure.permissionDenied =>
    'Microphone access is off. Allow microphone access to talk to Jarvis.',
  VoiceConversationFailure.microphoneFailed =>
    "The microphone couldn't be used. Try again.",
  VoiceConversationFailure.unsupportedAudio =>
    "This device's microphone format isn't supported.",
  VoiceConversationFailure.tooShort => 'Hold the button a little longer.',
  VoiceConversationFailure.invalidAudio =>
    "Jarvis couldn't process that recording. Try again.",
  VoiceConversationFailure.noSpeech => "Jarvis didn't hear anything.",
  VoiceConversationFailure.rejected => "Jarvis couldn't answer that request.",
  VoiceConversationFailure.busy => 'Jarvis is busy. Try again shortly.',
  VoiceConversationFailure.notAvailable => 'Jarvis is not available.',
  VoiceConversationFailure.unavailable => 'Jarvis is temporarily unavailable.',
  VoiceConversationFailure.tooSlow => 'Jarvis took too long to respond.',
  VoiceConversationFailure.network =>
    "Couldn't reach Jarvis. Check your connection and try again.",
  VoiceConversationFailure.playbackFailed => "The reply couldn't be played.",
  VoiceConversationFailure.unexpected => 'Something went wrong. Try again.',
};
