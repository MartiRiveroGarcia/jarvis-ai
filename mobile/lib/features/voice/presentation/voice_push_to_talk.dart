import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../assistant/presentation/widgets/voice_button.dart';
import '../application/voice_conversation_controller.dart';
import '../application/voice_conversation_state.dart';
import 'voice_messages.dart';

/// Push-to-talk with Jarvis: the voice button and its live status, wired to
/// the voice conversation controller.
///
/// Shared by every surface that offers voice, so press, release, cancel,
/// activation and state presentation behave the same everywhere. It renders
/// state and forwards presses; every decision stays in the controller.
class VoicePushToTalk extends ConsumerWidget {
  const VoicePushToTalk({
    super.key,
    this.buttonSize = 168,
    this.statusGap = 28,
    this.failureMessage = voiceFailureMessage,
  });

  static const semanticLabel = 'Talk to Jarvis';

  final double buttonSize;

  /// Space between the button and the status text.
  final double statusGap;

  /// User-facing text for a failure; a surface may word some differently.
  final String Function(VoiceConversationFailure failure) failureMessage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final state = ref.watch(voiceConversationControllerProvider);
    final voice = ref.read(voiceConversationControllerProvider.notifier);
    void start() => unawaited(voice.start());
    void stop() => unawaited(voice.stop());
    void cancel() => unawaited(voice.cancel());

    final status = voiceStatusText(state);
    final failure = switch (state) {
      VoiceIdle(:final failure?) => failureMessage(failure),
      _ => null,
    };
    final instruction = voiceInstructionText(state);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        VoiceButton(
          visual: switch (state) {
            VoiceIdle() => VoiceButtonVisual.idle,
            VoiceRecording() => VoiceButtonVisual.listening,
            VoiceProcessing() => VoiceButtonVisual.thinking,
            VoicePlaying() => VoiceButtonVisual.speaking,
          },
          semanticLabel: semanticLabel,
          semanticValue: status,
          semanticHint: voiceSemanticHint(state),
          onPressStart: state is VoiceProcessing ? null : start,
          onPressEnd: stop,
          onPressCancel: cancel,
          onActivate: switch (state) {
            VoiceIdle() || VoicePlaying() => start,
            VoiceRecording() => stop,
            VoiceProcessing() => null,
          },
          size: buttonSize,
        ),
        SizedBox(height: statusGap),
        Semantics(
          liveRegion: true,
          container: true,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                status,
                key: const Key('voice-status'),
                style: theme.textTheme.titleMedium,
              ),
              if (failure ?? instruction case final detail?) ...[
                const SizedBox(height: 6),
                Text(
                  detail,
                  key: Key(failure != null ? 'voice-failure' : 'voice-hint'),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: failure != null
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
