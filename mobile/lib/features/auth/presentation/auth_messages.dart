import '../application/auth_failure.dart';

/// User-facing text for an [AuthFailure]. Never includes emails or passwords.
String authFailureMessage(AuthFailure failure) => switch (failure) {
  InvalidCredentials() => 'Incorrect email or password.',
  AccountDisabled() => 'This account is disabled.',
  RegistrationDisabled() => "New accounts can't be created right now.",
  EmailAlreadyRegistered() =>
    'An account with this email already exists. Try logging in.',
  ValidationFailed(:final message) => message,
  NetworkFailure(isTimeout: true) => 'Jarvis took too long to respond.',
  NetworkFailure() =>
    "Couldn't reach Jarvis. Check your connection and try again.",
  ServerFailure() => 'Something went wrong on the server. Please try again.',
  StorageFailure() =>
    "Couldn't save your sign-in securely on this device. Please try again.",
  RegisteredButSignInFailed() =>
    "Your account was created, but we couldn't sign you in automatically. "
        'Please log in.',
};
