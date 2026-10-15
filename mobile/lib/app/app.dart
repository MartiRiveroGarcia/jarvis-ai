import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/voice/presentation/voice_lifecycle_bridge.dart';
import 'router.dart';
import 'theme.dart';

class JarvisApp extends ConsumerWidget {
  const JarvisApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'Jarvis',
      debugShowCheckedModeBanner: false,
      theme: buildJarvisTheme(),
      routerConfig: ref.watch(routerProvider),
      // Above every route: voice is app-level, not tied to one screen.
      builder: (_, child) =>
          VoiceLifecycleBridge(child: child ?? const SizedBox.shrink()),
    );
  }
}
