import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../storage/token_store.dart';
import 'api_exception.dart';

typedef JsonObject = Map<String, Object?>;

/// Thin JSON client for the Jarvis backend.
///
/// - Requests always go to [baseUrl]: paths are validated and appended to its
///   path, so a token can never be sent to another host.
/// - `Authorization: Bearer` is added only for `authenticated: true` calls.
/// - Nothing is logged. Errors are typed [ApiException]s without secrets.
/// - A 401 is reported, not acted on: auth state is the caller's concern.
class ApiClient {
  ApiClient({
    required this._baseUrl,
    required this._httpClient,
    required this._tokenStore,
    this.timeout = const Duration(seconds: 15),
  });

  static const _maxDetailLength = 200;

  final Uri _baseUrl;
  final http.Client _httpClient;
  final TokenStore _tokenStore;
  final Duration timeout;

  Future<JsonObject?> get(String path, {bool authenticated = false}) =>
      _send('GET', path, authenticated: authenticated);

  Future<JsonObject?> post(
    String path, {
    JsonObject? body,
    bool authenticated = false,
  }) => _send('POST', path, body: body, authenticated: authenticated);

  /// Joins a validated [path] onto the base URL, preserving the base path.
  ///
  /// Throws [ArgumentError] for anything that is not a plain absolute path:
  /// it must start with a single "/" and contain no scheme, host, query,
  /// fragment or ".." segment.
  Uri resolve(String path) {
    final parsed = Uri.tryParse(path);
    final isPlainPath =
        parsed != null &&
        path.startsWith('/') &&
        !path.startsWith('//') &&
        !path.contains('\\') &&
        !parsed.hasScheme &&
        !parsed.hasAuthority &&
        !path.contains('?') &&
        !path.contains('#') &&
        !_hasDotSegment(path);
    if (!isPlainPath) {
      throw ArgumentError.value(path, 'path', 'must be a plain absolute path');
    }
    return _baseUrl.replace(path: '${_baseUrl.path}$path');
  }

  /// Checks the raw path: Uri parsing silently normalises "a/../b" to "b".
  static bool _hasDotSegment(String path) => path
      .split('/')
      .any(
        (segment) =>
            segment == '.' ||
            segment == '..' ||
            segment.toLowerCase().contains('%2e'),
      );

  Future<JsonObject?> _send(
    String method,
    String path, {
    required bool authenticated,
    JsonObject? body,
  }) async {
    final url = resolve(path);
    final headers = <String, String>{'Accept': 'application/json'};
    if (body != null) {
      headers['Content-Type'] = 'application/json';
    }
    if (authenticated) {
      final session = await _tokenStore.read();
      if (session == null) {
        throw UnauthorizedException(
          method: method,
          path: path,
          message: 'Not signed in',
          statusCode: null,
        );
      }
      headers['Authorization'] = 'Bearer ${session.token}';
    }

    final request = http.Request(method, url)..headers.addAll(headers);
    if (body != null) {
      request.body = jsonEncode(body);
    }

    final http.Response response;
    try {
      final streamed = await _httpClient.send(request).timeout(timeout);
      response = await http.Response.fromStream(streamed).timeout(timeout);
    } on TimeoutException {
      throw NetworkException(method: method, path: path, isTimeout: true);
    } on http.ClientException {
      // Its toString() includes the full URL; deliberately not propagated.
      throw NetworkException(method: method, path: path, isTimeout: false);
    }

    return _handle(method, path, response);
  }

  JsonObject? _handle(String method, String path, http.Response response) {
    final status = response.statusCode;
    if (status == 204) {
      return null;
    }
    final decoded = _decodeJson(response.body);

    if (status == 200 || status == 201) {
      if (decoded is Map<String, Object?>) {
        return decoded;
      }
      throw UnexpectedResponseException(
        method: method,
        path: path,
        statusCode: status,
      );
    }

    final detail = _detailMessage(decoded);
    return switch (status) {
      401 => throw UnauthorizedException(
        method: method,
        path: path,
        message: detail ?? 'Unauthorized',
      ),
      403 => throw ForbiddenException(
        method: method,
        path: path,
        message: detail ?? 'Forbidden',
      ),
      409 => throw ConflictException(
        method: method,
        path: path,
        message: detail ?? 'Conflict',
      ),
      422 => throw ValidationException(
        method: method,
        path: path,
        message: detail ?? 'Invalid request',
        fieldErrors: _fieldErrors(decoded),
      ),
      >= 500 && < 600 => throw ServerException(
        method: method,
        path: path,
        statusCode: status,
      ),
      _ => throw UnexpectedResponseException(
        method: method,
        path: path,
        statusCode: status,
      ),
    };
  }

  static Object? _decodeJson(String body) {
    if (body.isEmpty) {
      return null;
    }
    try {
      return jsonDecode(body);
    } on FormatException {
      return null;
    }
  }

  /// The backend's `detail` string, if present and reasonably short.
  static String? _detailMessage(Object? decoded) {
    if (decoded is! Map<String, Object?>) {
      return null;
    }
    final detail = decoded['detail'];
    if (detail is! String || detail.isEmpty) {
      return null;
    }
    return detail.length <= _maxDetailLength
        ? detail
        : detail.substring(0, _maxDetailLength);
  }

  /// Field errors from the backend's sanitised 422 format: `{loc, msg, type}`.
  static List<FieldError> _fieldErrors(Object? decoded) {
    if (decoded is! Map<String, Object?>) {
      return const [];
    }
    final detail = decoded['detail'];
    if (detail is! List<Object?>) {
      return const [];
    }
    return [
      for (final item in detail)
        if (item is Map<String, Object?> && item['msg'] is String)
          FieldError(
            location: [
              if (item['loc'] case final List<Object?> loc)
                for (final part in loc) '$part',
            ],
            message: item['msg']! as String,
          ),
    ];
  }
}
