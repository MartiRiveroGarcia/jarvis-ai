import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
    );
  }
}
