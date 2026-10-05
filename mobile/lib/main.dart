import 'package:flutter/material.dart';

import 'core/config/app_config.dart';

void main() {
  // Validate configuration before anything else: an invalid API_BASE_URL
  // (or plain HTTP outside debug builds) stops the app at startup.
  final config = AppConfig.fromEnvironment();
  runApp(JarvisApp(config: config));
}

/// Root widget. A placeholder until routing, theming and authentication are added.
class JarvisApp extends StatelessWidget {
  const JarvisApp({super.key, required this.config});

  final AppConfig config;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Jarvis',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.dark,
        ),
      ),
      home: const Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Jarvis', style: TextStyle(fontSize: 32)),
              SizedBox(height: 8),
              Text('Voice-first personal AI assistant'),
            ],
          ),
        ),
      ),
    );
  }
}
