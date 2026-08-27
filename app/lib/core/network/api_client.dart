import 'package:dio/dio.dart';

import 'api_config.dart';
import 'api_exception.dart';

/// The single HTTP client. Every request the app makes goes through here, so
/// base URL, timeouts, and error translation are decided once.
class ApiClient {
  ApiClient({Dio? dio})
      : _dio = dio ??
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

  /// POSTs [body] and returns the `data` half of the response envelope.
  ///
  /// Throws [ApiException] for anything else, already classified.
  Future<Map<String, dynamic>> post(
    String path, {
    required Map<String, dynamic> body,
  }) async {
    try {
      // Deliberately `dynamic`: a proxy or a load balancer can answer with
      // HTML, and Dio must not fail casting that before we can classify it.
      final response = await _dio.post<dynamic>(path, data: body);
      return _unwrap(response);
    } on DioException catch (error) {
      throw ApiException.from(error);
    }
  }

  Future<Map<String, dynamic>> get(String path) async {
    try {
      final response = await _dio.get<dynamic>(path);
      return _unwrap(response);
    } on DioException catch (error) {
      throw ApiException.from(error);
    }
  }

  Map<String, dynamic> _unwrap(Response<dynamic> response) {
    final body = response.data;
    final status = response.statusCode ?? 0;

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
