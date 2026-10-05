import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/core/storage/auth_session.dart';
import 'package:jarvis/core/storage/token_store.dart';

const _token = 'Ab-_Ab-_Ab-_Ab-_Ab-_Ab-_Ab-_Ab-_Ab-_Ab-_xyz';

void main() {
  late SecureTokenStore store;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    store = SecureTokenStore();
  });

  Future<Map<String, String>> storedValues() =>
      const FlutterSecureStorage().readAll();

  group('SecureTokenStore', () {
    test('returns null when nothing is stored', () async {
      expect(await store.read(), isNull);
    });

    test('write then read returns the same session', () async {
      final session = AuthSession(
        token: _token,
        expiresAt: DateTime.utc(2030, 1, 2, 3, 4, 5, 6, 7),
      );

      await store.write(session);

      expect(await store.read(), session);
    });

    test(
      'expiresAt round-trips exactly as UTC, including microseconds',
      () async {
        final local = DateTime.utc(2030, 6, 1, 12, 30, 15, 123, 456).toLocal();

        await store.write(AuthSession(token: _token, expiresAt: local));
        final read = await store.read();

        expect(read!.expiresAt.isUtc, isTrue);
        expect(read.expiresAt, DateTime.utc(2030, 6, 1, 12, 30, 15, 123, 456));
        expect(
          (await storedValues())[SecureTokenStore.expiresAtKey],
          '2030-06-01T12:30:15.123456Z',
        );
      },
    );

    test('a non-UTC ISO timestamp in storage is normalised to UTC', () async {
      FlutterSecureStorage.setMockInitialValues({
        SecureTokenStore.tokenKey: _token,
        SecureTokenStore.expiresAtKey: '2030-06-01T14:30:00+02:00',
      });

      final read = await SecureTokenStore().read();

      expect(read!.expiresAt, DateTime.utc(2030, 6, 1, 12, 30));
      expect(read.expiresAt.isUtc, isTrue);
    });

    test('clear removes the session', () async {
      await store.write(
        AuthSession(token: _token, expiresAt: DateTime.utc(2030)),
      );

      await store.clear();

      expect(await store.read(), isNull);
      expect(await storedValues(), isEmpty);
    });

    test('stores only the token and its expiry', () async {
      await store.write(
        AuthSession(token: _token, expiresAt: DateTime.utc(2030)),
      );

      final values = await storedValues();
      expect(values.keys.toSet(), {
        SecureTokenStore.tokenKey,
        SecureTokenStore.expiresAtKey,
      });
      for (final key in values.keys) {
        expect(key, isNot(matches(RegExp('password|email|hash'))));
      }
    });

    for (final corrupt in <String, Map<String, String>>{
      'missing expiry': {SecureTokenStore.tokenKey: _token},
      'missing token': {SecureTokenStore.expiresAtKey: '2030-01-01T00:00:00Z'},
      'unparsable expiry': {
        SecureTokenStore.tokenKey: _token,
        SecureTokenStore.expiresAtKey: 'tomorrow',
      },
      'empty token': {
        SecureTokenStore.tokenKey: '',
        SecureTokenStore.expiresAtKey: '2030-01-01T00:00:00Z',
      },
    }.entries) {
      test('${corrupt.key} is cleared and treated as signed out', () async {
        FlutterSecureStorage.setMockInitialValues(corrupt.value);

        expect(await SecureTokenStore().read(), isNull);
        expect(await storedValues(), isEmpty);
      });
    }
  });

  group('AuthSession', () {
    test('always holds expiresAt in UTC', () {
      final session = AuthSession(
        token: _token,
        expiresAt: DateTime.utc(2030).toLocal(),
      );

      expect(session.expiresAt.isUtc, isTrue);
    });

    test('toString never contains the token', () {
      final session = AuthSession(token: _token, expiresAt: DateTime.utc(2030));

      expect(session.toString(), isNot(contains(_token)));
      expect(session.toString(), contains('<redacted>'));
    });

    test('is expired exactly at expiresAt, like the backend', () {
      final expiresAt = DateTime.utc(2030);
      final session = AuthSession(token: _token, expiresAt: expiresAt);

      expect(
        session.isExpiredAt(
          expiresAt.subtract(const Duration(microseconds: 1)),
        ),
        isFalse,
      );
      expect(session.isExpiredAt(expiresAt), isTrue);
      expect(
        session.isExpiredAt(expiresAt.add(const Duration(seconds: 1))),
        isTrue,
      );
    });
  });
}
