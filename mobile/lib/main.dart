import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'core/config/app_config.dart';
import 'core/providers.dart';

void main() {
  // Validate configuration before anything else: an invalid API_BASE_URL
  // (or plain HTTP outside debug builds) stops the app at startup.
  final config = AppConfig.fromEnvironment();
  runApp(
    ProviderScope(
      // No hidden automatic retries: retrying is always an explicit user action.
      retry: (_, _) => null,
      overrides: [appConfigProvider.overrideWithValue(config)],
      child: const JarvisApp(),
    ),
  );
}
