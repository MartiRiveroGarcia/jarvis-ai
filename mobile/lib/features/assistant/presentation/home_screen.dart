import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../auth/application/auth_controller.dart';
import '../../auth/application/auth_state.dart';

/// Temporary authenticated home so the auth flow can be exercised end to end.
/// Replaced by the voice-button home screen in the next commit.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    final email = auth is AuthAuthenticated ? auth.user.email : '';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Jarvis'),
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.go(Routes.settings),
          ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Signed in as $email', key: const Key('home-signed-in')),
              const SizedBox(height: 24),
              FilledButton.tonal(
                key: const Key('home-logout'),
                onPressed: () =>
                    ref.read(authControllerProvider.notifier).logout(),
                child: const Text('Log out'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
