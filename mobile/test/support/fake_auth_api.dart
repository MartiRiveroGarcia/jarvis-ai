import 'package:jarvis/core/api/api_exception.dart';
import 'package:jarvis/core/storage/auth_session.dart';
import 'package:jarvis/features/auth/data/auth_api.dart';
import 'package:jarvis/features/auth/domain/login_result.dart';
import 'package:jarvis/features/auth/domain/user.dart';

const testToken = 'Ab-_Ab-_Ab-_Ab-_Ab-_Ab-_Ab-_Ab-_Ab-_Ab-_xyz';
const otherToken = 'Zz9_Zz9_Zz9_Zz9_Zz9_Zz9_Zz9_Zz9_Zz9_Zz9_abc';

final testUser = User(
  id: '00000000-0000-0000-0000-000000000001',
  email: 'marti@example.com',
  createdAt: DateTime.utc(2026, 10, 5),
);

AuthSession testSession({String token = testToken, DateTime? expiresAt}) =>
    AuthSession(token: token, expiresAt: expiresAt ?? DateTime.utc(2030));

ApiException networkError(String path) =>
    NetworkException(method: 'POST', path: path, isTimeout: false);

/// Scriptable [AuthApi]. Each handler defaults to success.
class FakeAuthApi implements AuthApi {
  FakeAuthApi({List<String>? events}) : events = events ?? [];

  final List<String> events;
  final List<String> calls = [];
  final List<AuthSession?> logoutSessions = [];

  Future<User> Function()? onRegister;
  Future<LoginResult> Function()? onLogin;
  Future<User> Function()? onMe;
  Future<void> Function()? onLogout;

  @override
  Future<User> register({required String email, required String password}) {
    calls.add('register');
    return onRegister?.call() ?? Future.value(testUser);
  }

  @override
  Future<LoginResult> login({required String email, required String password}) {
    calls.add('login');
    return onLogin?.call() ??
        Future.value(LoginResult(user: testUser, session: testSession()));
  }

  @override
  Future<User> me() {
    calls.add('me');
    return onMe?.call() ?? Future.value(testUser);
  }

  @override
  Future<void> logout({AuthSession? session}) {
    calls.add('logout');
    logoutSessions.add(session);
    return onLogout?.call() ?? Future.value();
  }
}
