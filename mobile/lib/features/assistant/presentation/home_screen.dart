import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../voice/presentation/voice_push_to_talk.dart';

/// The signed-in assistant shell: push-to-talk with Jarvis.
///
/// Renders the voice conversation state and forwards presses to the
/// controller; every decision about recording, requests and playback stays
/// there. Session expiry needs nothing here: the router moves to login.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  static const semanticLabel = VoicePushToTalk.semanticLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
            child: const VoicePushToTalk(),
          ),
        ),
      ),
    );
  }
}
