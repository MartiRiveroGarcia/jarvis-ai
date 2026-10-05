import 'package:jarvis/core/storage/auth_session.dart';
import 'package:jarvis/core/storage/token_store.dart';

/// Test double for [TokenStore] that records how it was used.
class InMemoryTokenStore implements TokenStore {
  InMemoryTokenStore([this.session]);

  AuthSession? session;
  int reads = 0;
  int writes = 0;
  int clears = 0;

  @override
  Future<AuthSession?> read() async {
    reads++;
    return session;
  }

  @override
  Future<void> write(AuthSession session) async {
    writes++;
    this.session = session;
  }

  @override
  Future<void> clear() async {
    clears++;
    session = null;
  }
}
