import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../voice/application/voice_conversation_controller.dart';
import '../../voice/application/voice_conversation_state.dart';
import '../../voice/presentation/voice_messages.dart';
import 'widgets/voice_button.dart';

/// The signed-in assistant shell: push-to-talk with Jarvis.
///
/// Renders the voice conversation state and forwards presses to the
/// controller; every decision about recording, requests and playback stays
/// there. Session expiry needs nothing here: the router moves to login.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  static const semanticLabel = 'Talk to Jarvis';

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
      VoiceIdle(:final failure?) => voiceFailureMessage(failure),
      _ => null,
    };
    final instruction = voiceInstructionText(state);

    return Scaffold(
      key: const Key('assistant-home'),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        scrolledUnderElevation: 0,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.graphic_eq_rounded, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            const Text('Jarvis'),
          ],
        ),
        actions: [
          IconButton(
            key: const Key('home-settings'),
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.push(Routes.settings),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
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
                ),
                const SizedBox(height: 28),
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
                          key: Key(
                            failure != null ? 'voice-failure' : 'voice-hint',
                          ),
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
            ),
          ),
        ),
      ),
    );
  }
}
