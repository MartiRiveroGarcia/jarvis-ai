/// Errors raised by `ApiClient`.
///
/// They carry only the method, request path, status code and the backend's
/// generic `detail` message. They never contain tokens, headers, request bodies
/// or raw response bodies.
sealed class ApiException implements Exception {
  const ApiException({
    required this.method,
    required this.path,
    required this.message,
    this.statusCode,
  });

  final String method;
  final String path;
  final int? statusCode;
  final String message;

  @override
  String toString() {
    final status = statusCode == null ? '' : '$statusCode, ';
    return '$runtimeType($status$method $path): $message';
  }
}

/// The server could not be reached or did not answer in time.
final class NetworkException extends ApiException {
  const NetworkException({
    required super.method,
    required super.path,
    required this.isTimeout,
  }) : super(
         message: isTimeout
             ? 'The server took too long to respond'
             : 'Could not reach the server',
       );

  final bool isTimeout;
}

/// 401, or an authenticated call made without a stored session.
final class UnauthorizedException extends ApiException {
  const UnauthorizedException({
    required super.method,
    required super.path,
    required super.message,
    super.statusCode = 401,
  });
}

/// 403.
final class ForbiddenException extends ApiException {
  const ForbiddenException({
    required super.method,
    required super.path,
    required super.message,
  }) : super(statusCode: 403);
}

/// 409.
final class ConflictException extends ApiException {
  const ConflictException({
    required super.method,
    required super.path,
    required super.message,
  }) : super(statusCode: 409);
}

/// One field-level validation problem reported by the backend.
final class FieldError {
  const FieldError({required this.location, required this.message});

  /// For example `['body', 'password']`.
  final List<String> location;
  final String message;

  @override
  String toString() => 'FieldError(${location.join('.')}: $message)';
}

/// 422. [fieldErrors] is empty when the backend returned a single message.
final class ValidationException extends ApiException {
  const ValidationException({
    required super.method,
    required super.path,
    required super.message,
    this.fieldErrors = const [],
  }) : super(statusCode: 422);

  final List<FieldError> fieldErrors;
}

/// 5xx. The server's response is deliberately not exposed.
final class ServerException extends ApiException {
  const ServerException({
    required super.method,
    required super.path,
    required int super.statusCode,
  }) : super(message: 'The server encountered an error');
}

/// Any other status code, or a response that is not the expected JSON.
final class UnexpectedResponseException extends ApiException {
  const UnexpectedResponseException({
    required super.method,
    required super.path,
    super.statusCode,
  }) : super(message: 'Unexpected response from the server');
}
