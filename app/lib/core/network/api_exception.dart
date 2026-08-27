import 'package:dio/dio.dart';

/// Why a backend call did not produce an answer.
enum ApiFailureKind {
  /// No network, DNS failure, connection refused, or a timeout. The queue
  /// should retry this one later.
  unreachable,

  /// The server understood and refused: bad input, unsupported language pair.
  /// Retrying will not help.
  rejected,

  /// The session is over. Milestone 4 refreshes the token and retries.
  unauthenticated,

  /// Rate limited. Retry after [retryAfter].
  throttled,

  /// The backend is up but its translation provider is not. Retry later.
  temporarilyUnavailable,

  /// A 5xx or a response we could not parse.
  serverError,
}

/// A backend failure, already classified into something a caller can act on.
class ApiException implements Exception {
  const ApiException(
    this.kind, {
    this.code,
    this.message,
    this.retryAfter,
  });

  final ApiFailureKind kind;

  /// The server's machine-readable error code, e.g. `UNSUPPORTED_LANGUAGE_PAIR`.
  final String? code;
  final String? message;
  final Duration? retryAfter;

  /// Whether waiting and trying again could succeed.
  bool get isRetryable => switch (kind) {
        ApiFailureKind.unreachable ||
        ApiFailureKind.throttled ||
        ApiFailureKind.temporarilyUnavailable ||
        ApiFailureKind.serverError =>
          true,
        ApiFailureKind.rejected || ApiFailureKind.unauthenticated => false,
      };

  /// Turns a Dio error into an [ApiException], reading the server's error
  /// envelope when there is one.
  factory ApiException.from(DioException error) {
    final response = error.response;
    if (response == null) {
      // Dio drops the response when the body cannot be decoded — a proxy
      // answering HTML with a JSON content type, for instance. That is a
      // server that answered badly, not a network we could not reach.
      return ApiException(
        switch (error.type) {
          DioExceptionType.connectionError ||
          DioExceptionType.connectionTimeout ||
          DioExceptionType.sendTimeout ||
          DioExceptionType.receiveTimeout =>
            ApiFailureKind.unreachable,
          _ => ApiFailureKind.serverError,
        },
        message: error.message,
      );
    }

    final body = response.data;
    String? code;
    String? message;
    if (body is Map && body['error'] is Map) {
      final envelope = body['error'] as Map;
      code = envelope['code'] as String?;
      message = envelope['message'] as String?;
    }

    final kind = switch (response.statusCode) {
      400 || 404 || 422 => ApiFailureKind.rejected,
      401 || 403 => ApiFailureKind.unauthenticated,
      429 => ApiFailureKind.throttled,
      503 => ApiFailureKind.temporarilyUnavailable,
      _ => ApiFailureKind.serverError,
    };

    return ApiException(
      kind,
      code: code,
      message: message,
      retryAfter: _retryAfter(response),
    );
  }

  static Duration? _retryAfter(Response<dynamic> response) {
    final header = response.headers.value('retry-after');
    final seconds = header == null ? null : int.tryParse(header);
    return seconds == null ? null : Duration(seconds: seconds);
  }

  @override
  String toString() => 'ApiException($kind, $code, $message)';
}
