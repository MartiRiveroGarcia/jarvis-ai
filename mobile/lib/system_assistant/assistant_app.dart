import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/theme.dart';
import '../features/auth/application/auth_controller.dart';
import '../features/auth/application/auth_state.dart';
import '../features/auth/presentation/widgets/auth_error_banner.dart';
import '../features/voice/application/voice_conversation_state.dart';
import '../features/voice/presentation/voice_lifecycle_bridge.dart';
import '../features/voice/presentation/voice_messages.dart';
import '../features/voice/presentation/voice_push_to_talk.dart';
import 'assistant_close.dart';

/// The Android system-assistant app: one compact bottom panel, chosen by the
/// auth state, over a transparent window.
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
      // The Android window is transparent: nothing outside the panel is drawn.
      theme: buildJarvisTheme().copyWith(
        scaffoldBackgroundColor: Colors.transparent,
      ),
      // Cancels any voice activity as soon as the panel leaves the
      // foreground: Back, a tap outside, screen off or the session ending.
      builder: (_, child) =>
          VoiceLifecycleBridge(child: child ?? const SizedBox.shrink()),
      home: const AssistantGate(),
    );
  }
}

/// Shows the assistant only with a valid session, and a safe message otherwise,
/// always inside the same compact panel at the bottom of the screen.
class AssistantGate extends ConsumerWidget {
  const AssistantGate({super.key});

  static const signedOutMessage = 'Sign in to Jarvis to use the assistant';
  static const unreachableMessage = "Can't reach Jarvis";
  static const microphoneAccessMessage =
      'Open Jarvis to allow microphone access';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    final close = ref.read(assistantCloseProvider);

    final content = switch (auth) {
      AuthInitializing() => const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
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
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // The transparent area around the panel: a tap there ends the
          // session too. It never reaches the app or lock screen below.
          Positioned.fill(
            child: Semantics(
              label: 'Close Jarvis',
              button: true,
              onTap: close,
              excludeSemantics: true,
              child: GestureDetector(
                key: const Key('assistant-outside'),
                behavior: HitTestBehavior.opaque,
                onTap: close,
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: _Panel(
              children: [
                const _Header(),
                const SizedBox(height: 16),
                content,
                const SizedBox(height: 8),
                TextButton(
                  key: const Key('assistant-close'),
                  onPressed: close,
                  child: const Text('Close'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The compact, top-rounded assistant panel.
class _Panel extends StatelessWidget {
  const _Panel({required this.children});

  final List<Widget> children;

  static const maxWidth = 600.0;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: maxWidth),
      // Claims every touch inside the panel, including padding and empty
      // space, so none falls through to the close area behind it. A Listener
      // takes no part in gestures: the panel's own controls still work.
      child: Listener(
        key: const Key('assistant-panel-hit-area'),
        behavior: HitTestBehavior.opaque,
        child: _surface(colors),
      ),
    );
  }

  Widget _surface(ColorScheme colors) {
    return Material(
      key: const Key('assistant-panel'),
      color: colors.surfaceContainerHigh,
      elevation: 8,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.graphic_eq_rounded, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Text('Jarvis', style: theme.textTheme.titleLarge),
      ],
    );
  }
}

/// Push-to-talk inside the panel: the same control and semantics as the
/// normal app, with this engine's own controller, recorder and player. Nothing
/// is recorded until the user presses the control.
class _AssistantVoice extends StatelessWidget {
  const _AssistantVoice();

  @override
  Widget build(BuildContext context) {
    return const VoicePushToTalk(
      key: Key('assistant-voice'),
      buttonSize: 104,
      statusGap: 12,
      failureMessage: assistantVoiceFailureMessage,
    );
  }
}

/// The assistant never asks for the microphone itself, so a missing grant
/// points to the normal app; every other failure reads as in the normal app.
String assistantVoiceFailureMessage(VoiceConversationFailure failure) =>
    switch (failure) {
      VoiceConversationFailure.permissionDenied =>
        AssistantGate.microphoneAccessMessage,
      _ => voiceFailureMessage(failure),
    };

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
