import 'dart:async';

import 'package:flutter_riverpod/misc.dart' show Override;

import '../features/voice/audio/voice_recorder.dart';

/// Provider overrides for the assistant engine's own ProviderScope.
///
/// The assistant can be shown over the lock screen, so it never shows
/// Android's microphone permission dialog: its recorder only checks the grant.
/// Without it, no recording starts and the panel asks the user to open Jarvis.
final List<Override> assistantProviderOverrides = [
  voiceRecorderProvider.overrideWith((ref) {
    final recorder = RecordVoiceRecorder(requestPermission: false);
    ref.onDispose(() => unawaited(recorder.dispose()));
    return recorder;
  }),
];
