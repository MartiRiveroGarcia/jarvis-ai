import '../../../core/api/api_exception.dart';

/// Why an authentication operation failed. Thrown by AuthController methods
/// and shown by the forms; it never changes the global AuthState by itself.
///
/// Never contains passwords or tokens. toString() omits emails.
sealed class AuthFailure implements Exception {
  const AuthFailure();

  @override
  String toString() => '$runtimeType';
}

final class InvalidCredentials extends AuthFailure {
  const InvalidCredentials();
}

final class AccountDisabled extends AuthFailure {
  const AccountDisabled();
}

final class RegistrationDisabled extends AuthFailure {
  const RegistrationDisabled();
}

final class EmailAlreadyRegistered extends AuthFailure {
  const EmailAlreadyRegistered();
}

final class ValidationFailed extends AuthFailure {
  const ValidationFailed({required this.message, this.fieldErrors = const []});

  final String message;
  final List<FieldError> fieldErrors;

  /// The first message for a request body field such as `email` or `password`.
  String? messageFor(String field) {
    for (final error in fieldErrors) {
      if (error.location.isNotEmpty && error.location.last == field) {
        return error.message;
      }
    }
    return null;
  }
}

final class NetworkFailure extends AuthFailure {
  const NetworkFailure({this.isTimeout = false});

  final bool isTimeout;
}

final class ServerFailure extends AuthFailure {
  const ServerFailure();
}

/// The device's secure storage could not read, write or remove the session.
final class StorageFailure extends AuthFailure {
  const StorageFailure();
}

/// The account was created, but the automatic login afterwards failed.
final class RegisteredButSignInFailed extends AuthFailure {
  const RegisteredButSignInFailed({required this.email, required this.cause});

  final String email;
  final AuthFailure cause;

  @override
  String toString() => 'RegisteredButSignInFailed(cause: $cause)';
}
