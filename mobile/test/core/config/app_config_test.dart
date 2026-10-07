import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/core/config/app_config.dart';

const _apiBaseUrlDefined = bool.hasEnvironment('API_BASE_URL');

void main() {
  group('fromEnvironment', () {
    test('defaults to the emulator URL when API_BASE_URL is not defined', () {
      expect(
        AppConfig.fromEnvironment().apiBaseUrl,
        Uri.parse('http://10.0.2.2:8000'),
      );
    }, skip: _apiBaseUrlDefined ? 'API_BASE_URL is defined' : false);

    test(
      'uses --dart-define=API_BASE_URL when provided',
      () {
        const raw = String.fromEnvironment('API_BASE_URL');
        expect(
          AppConfig.fromEnvironment().apiBaseUrl,
          AppConfig.parse(raw, allowInsecureHttp: true).apiBaseUrl,
        );
      },
      skip: _apiBaseUrlDefined
          ? false
          : 'run with --dart-define=API_BASE_URL=... to check overrides',
    );

    test('allows plain HTTP only because tests run in debug mode', () {
      expect(kDebugMode, isTrue);
      expect(() => AppConfig.fromEnvironment(), returnsNormally);
    });
  });

  group('parse', () {
    test('accepts http and https URLs, LAN IPs, ports and base paths', () {
      for (final raw in [
        'https://api.example.com',
        'http://10.0.2.2:8000',
        'http://192.168.1.20:8000',
        'https://example.com/jarvis',
      ]) {
        expect(
          AppConfig.parse(raw, allowInsecureHttp: true).apiBaseUrl,
          Uri.parse(raw),
          reason: raw,
        );
      }
    });

    test('removes trailing slashes', () {
      expect(
        AppConfig.parse(
          'https://example.com/jarvis/',
          allowInsecureHttp: false,
        ).apiBaseUrl.toString(),
        'https://example.com/jarvis',
      );
      expect(
        AppConfig.parse(
          'https://example.com/',
          allowInsecureHttp: false,
        ).apiBaseUrl.toString(),
        'https://example.com',
      );
    });

    test('debug policy accepts http', () {
      expect(
        AppConfig.parse(
          'http://192.168.1.20:8000',
          allowInsecureHttp: true,
        ).apiBaseUrl.scheme,
        'http',
      );
    });

    test('non-debug policy rejects http but accepts https', () {
      expect(
        () => AppConfig.parse(
          'http://192.168.1.20:8000',
          allowInsecureHttp: false,
        ),
        throwsA(isA<InvalidConfigException>()),
      );
      expect(
        AppConfig.parse(
          'https://api.example.com',
          allowInsecureHttp: false,
        ).apiBaseUrl.scheme,
        'https',
      );
    });

    for (final raw in [
      '',
      'not a url',
      '/api',
      'api.example.com',
      'ftp://api.example.com',
      'https://',
      'https://api.example.com?debug=1',
      'https://api.example.com#section',
      'https://user:pass@api.example.com',
    ]) {
      test('rejects "$raw"', () {
        expect(
          () => AppConfig.parse(raw, allowInsecureHttp: true),
          throwsA(isA<InvalidConfigException>()),
        );
      });
    }

    test('error messages never contain the configured value', () {
      try {
        AppConfig.parse(
          'https://jarvis:s3cret@api.example.com',
          allowInsecureHttp: true,
        );
        fail('expected InvalidConfigException');
      } on InvalidConfigException catch (error) {
        expect(error.toString(), isNot(contains('s3cret')));
        expect(error.toString(), isNot(contains('api.example.com')));
      }
    });
  });
}
