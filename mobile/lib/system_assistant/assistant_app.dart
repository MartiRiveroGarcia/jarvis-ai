import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/theme.dart';
import '../features/assistant/presentation/widgets/voice_button.dart';
import '../features/auth/application/auth_controller.dart';
import '../features/auth/application/auth_state.dart';
import '../features/auth/presentation/widgets/auth_error_banner.dart';
import 'assistant_close.dart';

/// The Android system-assistant app: one screen, chosen by the auth state.
///
/// It can be shown over the lock screen, so it contains no navigation, no
/// account details and no account actions. Anything private stays in the
/// normal app, which this widget tree does not include.
class AssistantApp extends StatelessWidget {
  const AssistantApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Jarvis',
      debugShowCheckedModeBanner: false,
      theme: buildJarvisTheme(),
      home: const AssistantGate(),
    );
  }
}

/// Shows the assistant only with a valid session, and a safe message otherwise.
class AssistantGate extends ConsumerWidget {
  const AssistantGate({super.key});

  static const signedOutMessage = 'Sign in to Jarvis to use the assistant';
  static const unreachableMessage = "Can't reach Jarvis";

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    final close = ref.read(assistantCloseProvider);

    final content = switch (auth) {
      AuthInitializing() => const Padding(
        padding: EdgeInsets.only(top: 32),
        child: Center(
          child: CircularProgressIndicator(key: Key('assistant-progress')),
        ),
      ),
      AuthAuthenticated() => const _AssistantVoice(),
      AuthUnauthenticated() || AuthSignOutFailed() => _Message(
        key: const Key('assistant-signed-out'),
        message: signedOutMessage,
      ),
      AuthRestoreFailed() => _Message(
        key: const Key('assistant-unreachable'),
        message: unreachableMessage,
        onRetry: ref.read(authControllerProvider.notifier).retry,
      ),
    };

    return Scaffold(
      key: const Key('assistant-surface'),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const JarvisMark(),
                const SizedBox(height: 24),
                content,
                const SizedBox(height: 16),
                TextButton(
                  key: const Key('assistant-close'),
                  onPressed: close,
                  child: const Text('Close'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Placeholder for the voice session: the push-to-talk control is shown but
/// disabled, so nothing can be recorded or sent yet.
class _AssistantVoice extends StatelessWidget {
  const _AssistantVoice();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      key: const Key('assistant-voice'),
      children: [
        const VoiceButton(
          visual: VoiceButtonVisual.idle,
          semanticLabel: 'Talk to Jarvis',
        ),
        const SizedBox(height: 28),
        Text(
          'Hold to talk',
          key: const Key('assistant-status'),
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium,
        ),
      ],
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({super.key, required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AuthBanner.error(message),
        if (onRetry case final onRetry?) ...[
          const SizedBox(height: 16),
          FilledButton(
            key: const Key('assistant-retry'),
            onPressed: onRetry,
            child: const Text('Retry'),
          ),
        ],
      ],
    );
  }
}
