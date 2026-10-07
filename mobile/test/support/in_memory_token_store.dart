import 'package:jarvis/core/storage/auth_session.dart';
import 'package:jarvis/core/storage/token_store.dart';

/// Thrown by [InMemoryTokenStore] to simulate a secure-storage failure.
class FakeStorageException implements Exception {
  const FakeStorageException(this.operation);

  final String operation;
}

/// Test double for [TokenStore] that records calls and can simulate failures.
class InMemoryTokenStore implements TokenStore {
  InMemoryTokenStore([this.session]);

  AuthSession? session;
  int reads = 0;
  int writes = 0;
  int clears = 0;

  bool failRead = false;
  bool failWrite = false;

  /// Simulates a write that stored the token but failed before finishing.
  bool partialWrite = false;
  bool failClear = false;

  /// Ordered log of successful operations, shared with other fakes in a test.
  List<String> events = [];

  @override
  Future<AuthSession?> read() async {
    reads++;
    if (failRead) {
      throw const FakeStorageException('read');
    }
    return session;
  }

  @override
  Future<void> write(AuthSession session) async {
    writes++;
    if (partialWrite) {
      this.session = session;
      throw const FakeStorageException('write');
    }
    if (failWrite) {
      throw const FakeStorageException('write');
    }
    this.session = session;
    events.add('store.write');
  }

  @override
  Future<void> clear() async {
    clears++;
    if (failClear) {
      throw const FakeStorageException('clear');
    }
    session = null;
    events.add('store.clear');
  }
}
