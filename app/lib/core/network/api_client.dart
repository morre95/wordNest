import 'package:dio/dio.dart';

import 'api_config.dart';
import 'api_exception.dart';

/// Supplies the bearer token, and renews it when the server says it is stale.
///
/// An interface rather than a direct dependency on the session manager, because
/// the session manager needs the client to do the renewing — this is what keeps
/// that from being a cycle.
abstract interface class AccessTokens {
  /// The token to send, or null when this install has no session yet.
  Future<String?> current();

  /// Called once after a 401. Returns a fresh token, or null if the session is
  /// gone for good and the user has to start again.
  Future<String?> renew();
}

/// The single HTTP client. Every request the app makes goes through here, so
/// base URL, timeouts, authentication and error translation are decided once.
class ApiClient {
  /// [accessTokens] is a supplier rather than a value because the thing that
  /// holds the token needs this client in order to renew it. Resolving it at
  /// request time — by which point both exist — is what breaks that cycle.
  ApiClient({Dio? dio, AccessTokens Function()? accessTokens})
      : _tokens = accessTokens,
        _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: '${ApiConfig.baseUrl}${ApiConfig.apiPrefix}',
                connectTimeout: ApiConfig.connectTimeout,
                receiveTimeout: ApiConfig.receiveTimeout,
                contentType: Headers.jsonContentType,
                // We read the server's error envelope ourselves, so let every
                // status through rather than having Dio throw before we see it.
                validateStatus: (status) => status != null && status < 500,
              ),
            );

  final Dio _dio;
  final AccessTokens Function()? _tokens;

  Future<Map<String, dynamic>> post(
    String path, {
    required Map<String, dynamic> body,
    bool authenticated = true,
  }) {
    return _send(
      path,
      authenticated: authenticated,
      send: (options) => _dio.post<dynamic>(path, data: body, options: options),
    );
  }

  Future<Map<String, dynamic>> get(String path, {bool authenticated = true}) {
    return _send(
      path,
      authenticated: authenticated,
      send: (options) => _dio.get<dynamic>(path, options: options),
    );
  }

  Future<Map<String, dynamic>> delete(
    String path, {
    bool authenticated = true,
  }) {
    return _send(
      path,
      authenticated: authenticated,
      send: (options) => _dio.delete<dynamic>(path, options: options),
    );
  }

  /// Sends, and on an expired session renews once and sends again.
  ///
  /// Exactly once: if the renewed token is also refused, the session is gone
  /// and retrying forever would only hide that.
  Future<Map<String, dynamic>> _send(
    String path, {
    required bool authenticated,
    required Future<Response<dynamic>> Function(Options options) send,
  }) async {
    try {
      final response = await send(await _options(authenticated: authenticated));
      return _unwrap(response);
    } on DioException catch (error) {
      throw ApiException.from(error);
    } on ApiException catch (error) {
      if (!authenticated || error.kind != ApiFailureKind.unauthenticated) {
        rethrow;
      }
      final renewed = await _tokens?.call().renew();
      if (renewed == null) rethrow;
      try {
        final response = await send(
          Options(headers: {'Authorization': 'Bearer $renewed'}),
        );
        return _unwrap(response);
      } on DioException catch (error) {
        throw ApiException.from(error);
      }
    }
  }

  Future<Options> _options({required bool authenticated}) async {
    if (!authenticated) return Options();
    final token = await _tokens?.call().current();
    return Options(
      headers: token == null ? null : {'Authorization': 'Bearer $token'},
    );
  }

  Map<String, dynamic> _unwrap(Response<dynamic> response) {
    final body = response.data;
    final status = response.statusCode ?? 0;

    // 204 has no body by design — a successful delete, for instance.
    if (status == 204) return const {};

    if (status >= 400 || body is! Map || body['success'] != true) {
      throw ApiException.from(
        DioException.badResponse(
          statusCode: status,
          requestOptions: response.requestOptions,
          response: response,
        ),
      );
    }

    final data = body['data'];
    if (data is! Map<String, dynamic>) {
      throw const ApiException(
        ApiFailureKind.serverError,
        message: 'The response had no data object.',
      );
    }
    return data;
  }
}
