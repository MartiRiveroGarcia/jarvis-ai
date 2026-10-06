/// Build metadata about the app (not runtime configuration).
abstract final class AppInfo {
  static const name = 'Jarvis';

  /// The `version` from pubspec.yaml (e.g. "0.1.0"), which the Flutter tool
  /// passes to every build as FLUTTER_BUILD_NAME. Null if it was not provided.
  static String? get version {
    const buildName = String.fromEnvironment('FLUTTER_BUILD_NAME');
    return buildName.isEmpty ? null : buildName;
  }
}
