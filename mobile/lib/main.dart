import 'package:flutter/material.dart';

void main() {
  runApp(const JarvisApp());
}

/// Root widget. A placeholder until routing, theming and authentication are added.
class JarvisApp extends StatelessWidget {
  const JarvisApp({super.key});

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
