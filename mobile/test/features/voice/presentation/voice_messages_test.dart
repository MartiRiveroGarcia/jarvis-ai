import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/features/voice/application/voice_conversation_state.dart';
import 'package:jarvis/features/voice/presentation/voice_messages.dart';

void main() {
  test('every failure has its exact, stable message', () {
    const expected = {
      VoiceConversationFailure.permissionDenied: 'Microphone access is off. Allow microphone access to talk to Jarvis.',
      VoiceConversationFailure.microphoneFailed:
          "The microphone couldn't be used. Try again.",
      VoiceConversationFailure.unsupportedAudio:
          "This device's microphone format isn't supported.",
      VoiceConversationFailure.tooShort: 'Hold the button a little longer.',
      VoiceConversationFailure.invalidAudio:
          "Jarvis couldn't process that recording. Try again.",
      VoiceConversationFailure.noSpeech: "Jarvis didn't hear anything.",
      VoiceConversationFailure.rejected: "Jarvis couldn't answer that request.",
      VoiceConversationFailure.busy: 'Jarvis is busy. Try again shortly.',
      VoiceConversationFailure.notAvailable: 'Jarvis is not available.',
      VoiceConversationFailure.unavailable:
          'Jarvis is temporarily unavailable.',
      VoiceConversationFailure.tooSlow: 'Jarvis took too long to respond.',
      VoiceConversationFailure.network:
          "Couldn't reach Jarvis. Check your connection and try again.",
      VoiceConversationFailure.playbackFailed: "The reply couldn't be played.",
      VoiceConversationFailure.unexpected: 'Something went wrong. Try again.',
    };

    expect(expected.keys, unorderedEquals(VoiceConversationFailure.values));
    for (final MapEntry(key: failure, value: message) in expected.entries) {
      expect(voiceFailureMessage(failure), message, reason: failure.name);
    }
  });

  test('messages are distinct and never the raw failure name', () {
    final messages = VoiceConversationFailure.values.map(voiceFailureMessage);

    expect(messages.toSet(), hasLength(VoiceConversationFailure.values.length));
    for (final failure in VoiceConversationFailure.values) {
      final message = voiceFailureMessage(failure);
      expect(message, isNot(failure.name));
      expect(message, isNot(contains('VoiceConversationFailure')));
    }
  });

  test('the permission message claims neither kind of denial', () {
    final message = voiceFailureMessage(
      VoiceConversationFailure.permissionDenied,
    );

    expect(message.toLowerCase(), isNot(contains('settings')));
    expect(message.toLowerCase(), isNot(contains('again')));
  });

  test('status, instruction and hint per state', () {
    expect(voiceStatusText(const VoiceIdle()), 'Hold to talk');
    expect(
      voiceStatusText(const VoiceIdle(VoiceConversationFailure.busy)),
      'Hold to talk',
    );
    expect(voiceStatusText(const VoiceRecording()), 'Listening…');
    expect(voiceStatusText(const VoiceProcessing()), 'Jarvis is thinking…');
    expect(voiceStatusText(const VoicePlaying()), 'Jarvis is speaking…');

    expect(voiceInstructionText(const VoiceIdle()), isNull);
    expect(voiceInstructionText(const VoiceRecording()), 'Release to send');
    expect(voiceInstructionText(const VoiceProcessing()), isNull);
    expect(voiceInstructionText(const VoicePlaying()), 'Press to interrupt');

    expect(
      voiceSemanticHint(const VoiceIdle()),
      'Hold to talk, or double-tap to start',
    );
    expect(voiceSemanticHint(const VoiceRecording()), 'Double-tap to send');
    expect(voiceSemanticHint(const VoiceProcessing()), isNull);
    expect(voiceSemanticHint(const VoicePlaying()), 'Double-tap to interrupt');
  });
}
