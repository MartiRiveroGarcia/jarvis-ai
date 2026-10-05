import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/assistant/presentation/home_screen.dart';
import '../features/auth/application/auth_controller.dart';
import '../features/auth/application/auth_state.dart';
import '../features/auth/presentation/login_screen.dart';
import '../features/auth/presentation/register_screen.dart';
import '../features/auth/presentation/splash_screen.dart';
import '../features/settings/presentation/settings_screen.dart';

abstract final class Routes {
  static const splash = '/splash';
  static const login = '/login';
  static const register = '/register';
  static const home = '/';
  static const settings = '/settings';
}

/// Where the user may be for a given auth state. Pure, so it can be tested
/// exhaustively. Every target it returns is allowed in that same state, so
/// redirects cannot loop. Unknown paths are redirected like any other.
String? authRedirect(AuthState auth, String path) => switch (auth) {
  AuthInitializing() ||
  AuthRestoreFailed() ||
  AuthSignOutFailed() => path == Routes.splash ? null : Routes.splash,
  AuthUnauthenticated() =>
    path == Routes.login || path == Routes.register ? null : Routes.login,
  AuthAuthenticated() =>
    path == Routes.home || path == Routes.settings ? null : Routes.home,
};

/// One GoRouter for the app's lifetime. Auth changes are forwarded through a
/// ValueNotifier (ref.listen, not ref.watch), so the router is never rebuilt;
/// refreshListenable makes it re-run [authRedirect] for the current location.
final routerProvider = Provider<GoRouter>((ref) {
  final auth = ValueNotifier<AuthState>(ref.read(authControllerProvider));
  ref.listen(authControllerProvider, (_, next) => auth.value = next);

  final router = GoRouter(
    initialLocation: Routes.splash,
    refreshListenable: auth,
    redirect: (_, state) => authRedirect(auth.value, state.uri.path),
    routes: [
      GoRoute(path: Routes.splash, builder: (_, _) => const SplashScreen()),
      GoRoute(
        path: Routes.login,
        builder: (_, state) => LoginScreen(
          prefill: state.extra is LoginPrefill
              ? state.extra! as LoginPrefill
              : null,
        ),
      ),
      GoRoute(path: Routes.register, builder: (_, _) => const RegisterScreen()),
      GoRoute(path: Routes.home, builder: (_, _) => const HomeScreen()),
      GoRoute(path: Routes.settings, builder: (_, _) => const SettingsScreen()),
    ],
  );

  ref.onDispose(() {
    router.dispose();
    auth.dispose();
  });
  return router;
});
