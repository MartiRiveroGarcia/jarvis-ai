import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/config/app_config.dart';
import 'core/providers.dart';
import 'system_assistant/assistant_app.dart';
import 'system_assistant/assistant_providers.dart';

/// Entrypoint of the Android system-assistant surface, started by its own
/// Flutter engine. It builds only [AssistantApp]: the normal app, its router
/// and its screens are not part of this entrypoint at all.
@pragma('vm:entry-point')
void assistantMain() {
  // The same configuration validation as the normal app.
  final config = AppConfig.fromEnvironment();
  runApp(
    ProviderScope(
      // No hidden automatic retries: retrying is always an explicit user action.
      retry: (_, _) => null,
      overrides: [
        appConfigProvider.overrideWithValue(config),
        ...assistantProviderOverrides,
      ],
      child: const AssistantApp(),
    ),
  );
}
