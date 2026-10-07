import 'package:flutter/foundation.dart';

/// Thrown when the build-time configuration is invalid.
///
/// Messages describe the broken rule only; they never echo the configured value,
/// which could contain credentials.
class InvalidConfigException implements Exception {
  const InvalidConfigException(this.message);

  final String message;

  @override
  String toString() => 'InvalidConfigException: $message';
}

/// Application configuration, fixed at build time.
///
/// `API_BASE_URL` is configuration, not a secret: anything passed with
/// `--dart-define` is compiled into the app and can be recovered from it.
@immutable
class AppConfig {
  const AppConfig({required this.apiBaseUrl});

  /// Android emulator alias for the development machine's localhost.
  static const defaultApiBaseUrl = 'http://10.0.2.2:8000';

  /// Normalised base URL: no trailing slash, query, fragment or credentials.
  final Uri apiBaseUrl;

  /// Reads `--dart-define=API_BASE_URL=...`. Plain HTTP is accepted only in debug
  /// builds; profile and release builds require HTTPS.
  factory AppConfig.fromEnvironment() => AppConfig.parse(
    const String.fromEnvironment(
      'API_BASE_URL',
      defaultValue: defaultApiBaseUrl,
    ),
    allowInsecureHttp: kDebugMode,
  );

  /// Validates and normalises [raw]. Throws [InvalidConfigException].
  static AppConfig parse(String raw, {required bool allowInsecureHttp}) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || !uri.isAbsolute || uri.host.isEmpty) {
      throw const InvalidConfigException(
        'API_BASE_URL must be an absolute http(s) URL with a host',
      );
    }
    if (uri.scheme != 'https' && uri.scheme != 'http') {
      throw const InvalidConfigException('API_BASE_URL must use http or https');
    }
    if (uri.scheme == 'http' && !allowInsecureHttp) {
      throw const InvalidConfigException(
        'API_BASE_URL must use https outside debug builds',
      );
    }
    if (uri.userInfo.isNotEmpty) {
      throw const InvalidConfigException(
        'API_BASE_URL must not contain credentials',
      );
    }
    if (uri.hasQuery || uri.hasFragment) {
      throw const InvalidConfigException(
        'API_BASE_URL must not contain a query or fragment',
      );
    }

    var path = uri.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return AppConfig(apiBaseUrl: uri.replace(path: path));
  }
}
