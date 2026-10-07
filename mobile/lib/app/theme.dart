import 'package:flutter/material.dart';

/// Material 3, dark-first. Kept deliberately small.
ThemeData buildJarvisTheme() {
  final colorScheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF5B6CFF),
    brightness: Brightness.dark,
  );
  return ThemeData(
    colorScheme: colorScheme,
    scaffoldBackgroundColor: colorScheme.surface,
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
  );
}
