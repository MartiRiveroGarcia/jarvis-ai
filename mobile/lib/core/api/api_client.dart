import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../storage/token_store.dart';
import 'api_exception.dart';

typedef JsonObject = Map<String, Object?>;

/// A successful binary response. Its contents are never part of toString().
final class BinaryResponse {
  const BinaryResponse({required this.bytes, required this.mediaType});

  final Uint8List bytes;

  /// The response's media type, lower-cased and without parameters
  /// (e.g. `audio/mpeg`), or null when the response had none.
  final String? mediaType;

  @override
  String toString() => 'BinaryResponse(<hidden>)';
}

/// Thin JSON (and raw binary) client for the Jarvis backend.
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

  /// Error bodies of binary requests are only read to find a short `detail`.
  static const _maxErrorBodyBytes = 64 * 1024;

  final Uri _baseUrl;
  final http.Client _httpClient;
  final TokenStore _tokenStore;
  final Duration timeout;

  Future<JsonObject?> get(String path, {bool authenticated = false}) =>
      _send('GET', path, authenticated: authenticated);

  /// [bearerToken] sends that token instead of the stored one. It exists for one
  /// case: revoking a freshly issued session that could not be stored.
  ///
  /// [timeout] overrides the client's default [timeout] for this request only.
  Future<JsonObject?> post(
    String path, {
    JsonObject? body,
    bool authenticated = false,
    String? bearerToken,
    Duration? timeout,
  }) => _send(
    'POST',
    path,
    body: body,
    authenticated: authenticated,
    bearerToken: bearerToken,
    timeout: timeout,
  );

  /// POSTs [body] byte-for-byte with the given [contentType] and [accept]
  /// headers and returns the raw response.
  ///
  /// Only a 200 response is a success; its body may be at most
  /// [maxResponseBytes] (checked from Content-Length and while reading). Error
  /// responses map to the same [ApiException]s as JSON requests; at most 64 KiB
  /// of an error body is read, and only to find its `detail`.
  Future<BinaryResponse> postBinary(
    String path, {
    required Uint8List body,
    required String contentType,
    required String accept,
    required int maxResponseBytes,
    bool authenticated = false,
    Duration? timeout,
  }) async {
    const method = 'POST';
    final limit = timeout ?? this.timeout;
    final streamed = await _dispatch(
      method,
      path,
      headers: {'Accept': accept, 'Content-Type': contentType},
      authenticated: authenticated,
      limit: limit,
      // bodyBytes leaves the Content-Type exactly as given.
      writeBody: (request) => request.bodyBytes = body,
    );

    final status = streamed.statusCode;
    if (status != 200) {
      final errorBytes = await _guard(
        method,
        path,
        _readCapped(streamed, _maxErrorBodyBytes, limit),
      );
      final decoded = errorBytes == null
          ? null
          : _decodeJson(utf8.decode(errorBytes, allowMalformed: true));
      _throwForStatus(method, path, status, decoded);
    }

    final declared = streamed.contentLength;
    if (declared != null && declared > maxResponseBytes) {
      unawaited(streamed.stream.listen(null).cancel());
      throw UnexpectedResponseException(
        method: method,
        path: path,
        statusCode: status,
      );
    }
    final bytes = await _guard(
      method,
      path,
      _readCapped(streamed, maxResponseBytes, limit),
    );
    if (bytes == null) {
      throw UnexpectedResponseException(
        method: method,
        path: path,
        statusCode: status,
      );
    }
    return BinaryResponse(
      bytes: bytes,
      mediaType: _mediaType(streamed.headers['content-type']),
    );
  }

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
    String? bearerToken,
    Duration? timeout,
  }) async {
    final limit = timeout ?? this.timeout;
    final streamed = await _dispatch(
      method,
      path,
      headers: {
        'Accept': 'application/json',
        if (body != null) 'Content-Type': 'application/json',
      },
      authenticated: authenticated,
      bearerToken: bearerToken,
      limit: limit,
      writeBody: body == null
          ? null
          : (request) => request.body = jsonEncode(body),
    );
    final response = await _guard(
      method,
      path,
      http.Response.fromStream(streamed).timeout(limit),
    );
    return _handle(method, path, response);
  }

  /// The one authenticated send path: validated URL, Bearer header (or no
  /// request at all without a stored session), timeout and network mapping.
  Future<http.StreamedResponse> _dispatch(
    String method,
    String path, {
    required Map<String, String> headers,
    required bool authenticated,
    required Duration limit,
    String? bearerToken,
    void Function(http.Request request)? writeBody,
  }) async {
    final url = resolve(path);
    final allHeaders = {...headers};
    if (bearerToken != null) {
      allHeaders['Authorization'] = 'Bearer $bearerToken';
    } else if (authenticated) {
      final session = await _tokenStore.read();
      if (session == null) {
        throw UnauthorizedException(
          method: method,
          path: path,
          message: 'Not signed in',
          statusCode: null,
        );
      }
      allHeaders['Authorization'] = 'Bearer ${session.token}';
    }

    final request = http.Request(method, url)..headers.addAll(allHeaders);
    writeBody?.call(request);
    return _guard(method, path, _httpClient.send(request).timeout(limit));
  }

  /// Maps timeouts and connection failures to [NetworkException].
  static Future<T> _guard<T>(
    String method,
    String path,
    Future<T> future,
  ) async {
    try {
      return await future;
    } on TimeoutException {
      throw NetworkException(method: method, path: path, isTimeout: true);
    } on http.ClientException {
      // Its toString() includes the full URL; deliberately not propagated.
      throw NetworkException(method: method, path: path, isTimeout: false);
    }
  }

  /// Reads at most [maxBytes] of the body; returns null (and stops reading) if
  /// it is longer.
  static Future<Uint8List?> _readCapped(
    http.StreamedResponse response,
    int maxBytes,
    Duration limit,
  ) async {
    Future<Uint8List?> read() async {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.stream) {
        builder.add(chunk);
        if (builder.length > maxBytes) {
          return null; // leaving the loop cancels the subscription
        }
      }
      return builder.takeBytes();
    }

    return read().timeout(limit);
  }

  static String? _mediaType(String? header) {
    final type = header?.split(';').first.trim().toLowerCase();
    return type == null || type.isEmpty ? null : type;
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

    _throwForStatus(method, path, status, decoded);
  }

  /// The error mapping shared by JSON and binary requests. [decoded] is the
  /// parsed JSON error body, or null.
  static Never _throwForStatus(
    String method,
    String path,
    int status,
    Object? decoded,
  ) {
    final detail = _detailMessage(decoded);
    throw switch (status) {
      401 => UnauthorizedException(
        method: method,
        path: path,
        message: detail ?? 'Unauthorized',
      ),
      403 => ForbiddenException(
        method: method,
        path: path,
        message: detail ?? 'Forbidden',
      ),
      409 => ConflictException(
        method: method,
        path: path,
        message: detail ?? 'Conflict',
      ),
      422 => ValidationException(
        method: method,
        path: path,
        message: detail ?? 'Invalid request',
        fieldErrors: _fieldErrors(decoded),
      ),
      >= 500 && < 600 => ServerException(
        method: method,
        path: path,
        statusCode: status,
        detail: detail,
      ),
      _ => UnexpectedResponseException(
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
