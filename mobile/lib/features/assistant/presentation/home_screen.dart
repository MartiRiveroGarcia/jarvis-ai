import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import 'widgets/voice_button.dart';

/// The signed-in assistant shell. Voice is visual-only in Sprint 01: tapping the
/// button gives feedback but records nothing and calls no service.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  static const comingSoonMessage = 'Voice interaction is coming soon.';

  void _showComingSoon(BuildContext context) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text(comingSoonMessage),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

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
                  semanticLabel: 'Talk to Jarvis',
                  semanticHint: comingSoonMessage,
                  onPressed: () => _showComingSoon(context),
                ),
                const SizedBox(height: 28),
                Text('Tap to talk', style: theme.textTheme.titleMedium),
                const SizedBox(height: 6),
                Text(
                  comingSoonMessage,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
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
