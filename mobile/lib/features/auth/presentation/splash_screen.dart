import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/auth_controller.dart';
import '../application/auth_failure.dart';
import '../application/auth_state.dart';
import 'widgets/auth_error_banner.dart';

/// Shown while the stored session is restored, and for the two blocking
/// states that need the user to retry: restore failed and sign-out failed.
class SplashScreen extends ConsumerWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    final controller = ref.read(authControllerProvider.notifier);

    final content = switch (auth) {
      AuthRestoreFailed(:final cause) => _Problem(
        key: const Key('restore-failed'),
        message: switch (cause) {
          NetworkFailure() => "Can't reach Jarvis right now.",
          StorageFailure() => "Couldn't read your saved sign-in.",
          _ => 'Something went wrong on the server.',
        },
        onRetry: controller.retry,
        secondaryLabel: 'Sign out of this device',
        onSecondary: controller.signOutOnThisDevice,
      ),
      AuthSignOutFailed() => _Problem(
        key: const Key('sign-out-failed'),
        message: "Couldn't remove your sign-in from this device.",
        onRetry: controller.signOutOnThisDevice,
      ),
      _ => const Padding(
        padding: EdgeInsets.only(top: 32),
        child: Center(
          child: CircularProgressIndicator(key: Key('splash-progress')),
        ),
      ),
    };

    return AuthLayout(
      children: [const JarvisMark(), const SizedBox(height: 24), content],
    );
  }
}

class _Problem extends StatelessWidget {
  const _Problem({
    super.key,
    required this.message,
    required this.onRetry,
    this.secondaryLabel,
    this.onSecondary,
  });

  final String message;
  final VoidCallback onRetry;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AuthBanner.error(message),
        const SizedBox(height: 16),
        FilledButton(onPressed: onRetry, child: const Text('Retry')),
        if (secondaryLabel != null && onSecondary != null) ...[
          const SizedBox(height: 8),
          TextButton(onPressed: onSecondary, child: Text(secondaryLabel!)),
        ],
      ],
    );
  }
}
