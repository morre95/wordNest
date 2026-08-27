import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/core/network/api_client.dart';
import 'package:wordnest/core/network/api_exception.dart';

/// Answers requests from a table, so the client's parsing and error
/// classification can be tested without a server.
class _CannedAdapter implements HttpClientAdapter {
  _CannedAdapter(this.respond);

  final ResponseBody Function(RequestOptions options) respond;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async =>
      respond(options);

  @override
  void close({bool force = false}) {}
}

Dio dioReturning(
  String body, {
  int status = 200,
  Map<String, List<String>> headers = const {},
}) {
  final dio = Dio(
    BaseOptions(validateStatus: (status) => status != null && status < 500),
  );
  dio.httpClientAdapter = _CannedAdapter(
    (options) => ResponseBody.fromString(
      body,
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
        ...headers,
      },
    ),
  );
  return dio;
}

Dio dioThatCannotConnect() {
  final dio = Dio();
  dio.httpClientAdapter = _CannedAdapter(
    (options) => throw DioException.connectionError(
      requestOptions: options,
      reason: 'no route to host',
    ),
  );
  return dio;
}

void main() {
  group('successful responses', () {
    test('unwraps the data half of the envelope', () async {
      final client = ApiClient(
        dio: dioReturning('{"success":true,"data":{"translation":"hola"}}'),
      );

      final data = await client.post('/translations', body: const {});

      expect(data, {'translation': 'hola'});
    });

    test('a success envelope with no data object is a server error', () async {
      final client = ApiClient(dio: dioReturning('{"success":true,"data":42}'));

      await expectLater(
        client.post('/translations', body: const {}),
        throwsA(
          isA<ApiException>().having(
            (error) => error.kind,
            'kind',
            ApiFailureKind.serverError,
          ),
        ),
      );
    });
  });

  group('failure classification', () {
    Future<ApiException> failureFrom(
      String body, {
      required int status,
      Map<String, List<String>> headers = const {},
    }) async {
      final client = ApiClient(
        dio: dioReturning(body, status: status, headers: headers),
      );
      try {
        await client.post('/translations', body: const {});
        fail('expected an ApiException');
      } on ApiException catch (error) {
        return error;
      }
    }

    test('a rejected request carries the server error code', () async {
      final failure = await failureFrom(
        '{"success":false,"error":{"code":"UNSUPPORTED_LANGUAGE_PAIR",'
        '"message":"nope"}}',
        status: 422,
      );

      expect(failure.kind, ApiFailureKind.rejected);
      expect(failure.code, 'UNSUPPORTED_LANGUAGE_PAIR');
      expect(failure.message, 'nope');
      expect(failure.isRetryable, isFalse);
    });

    test('a throttled request reads Retry-After', () async {
      final failure = await failureFrom(
        '{"success":false,"error":{"code":"RATE_LIMITED","message":"slow down"}}',
        status: 429,
        headers: {
          'retry-after': ['12'],
        },
      );

      expect(failure.kind, ApiFailureKind.throttled);
      expect(failure.retryAfter, const Duration(seconds: 12));
      expect(failure.isRetryable, isTrue);
    });

    test('an expired session is not retryable without new credentials',
        () async {
      final failure = await failureFrom(
        '{"success":false,"error":{"code":"UNAUTHORIZED","message":"expired"}}',
        status: 401,
      );

      expect(failure.kind, ApiFailureKind.unauthenticated);
      expect(failure.isRetryable, isFalse);
    });

    test('an unavailable provider is retryable', () async {
      final failure = await failureFrom(
        '{"success":false,"error":{"code":"TRANSLATION_UNAVAILABLE",'
        '"message":"down"}}',
        status: 503,
      );

      expect(failure.kind, ApiFailureKind.temporarilyUnavailable);
      expect(failure.isRetryable, isTrue);
    });

    test('an unparseable body still classifies by status', () async {
      final failure = await failureFrom('not json at all', status: 502);

      expect(failure.kind, ApiFailureKind.serverError);
      expect(failure.code, isNull);
    });

    test('no network at all is unreachable and retryable', () async {
      final client = ApiClient(dio: dioThatCannotConnect());

      try {
        await client.post('/translations', body: const {});
        fail('expected an ApiException');
      } on ApiException catch (error) {
        expect(error.kind, ApiFailureKind.unreachable);
        expect(error.isRetryable, isTrue);
      }
    });
  });
}
