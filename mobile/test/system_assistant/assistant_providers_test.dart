import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/features/voice/audio/voice_recorder.dart';
import 'package:jarvis/system_assistant/assistant_providers.dart';

void main() {
  test('the assistant engine records with a check-only permission', () {
    final container = ProviderContainer(overrides: assistantProviderOverrides);
    addTearDown(container.dispose);

    final recorder = container.read(voiceRecorderProvider);

    expect(recorder, isA<RecordVoiceRecorder>());
    expect((recorder as RecordVoiceRecorder).requestPermission, isFalse);
  });

  test('the normal app keeps the requesting recorder', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final recorder = container.read(voiceRecorderProvider);

    expect((recorder as RecordVoiceRecorder).requestPermission, isTrue);
  });
}
