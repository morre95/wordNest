import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/core/speech/speech_recognizer.dart';
import 'package:wordnest/core/speech/speech_socket.dart';

/// The socket has to land on the same backend every other call uses; a debug
/// build pointing two ways at once is the failure this guards against.
void main() {
  group('speechSocketUri', () {
    test('turns the development base URL into a ws address', () {
      final uri = speechSocketUri(
        languageCode: 'en',
        mode: ListeningMode.single,
        baseUrl: 'http://10.0.2.2:8000',
      );

      expect(uri.scheme, 'ws');
      expect(uri.host, '10.0.2.2');
      expect(uri.port, 8000);
      expect(uri.path, '/api/v1/speech/stream');
    });

    test('a secure backend gets a secure socket', () {
      final uri = speechSocketUri(
        languageCode: 'en',
        mode: ListeningMode.single,
        baseUrl: 'https://api.wordnest.example',
      );

      expect(uri.scheme, 'wss');
    });

    test('a trailing slash does not double up', () {
      final uri = speechSocketUri(
        languageCode: 'en',
        mode: ListeningMode.single,
        baseUrl: 'http://localhost:8000/',
      );

      expect(uri.path, '/api/v1/speech/stream');
    });

    test('carries the language and mode the session needs', () {
      final uri = speechSocketUri(
        languageCode: 'sv',
        mode: ListeningMode.continuous,
        baseUrl: 'http://localhost:8000',
      );

      expect(uri.queryParameters['language'], 'sv');
      expect(uri.queryParameters['mode'], 'continuous');
    });

    test('states the audio format rather than leaving it implicit', () {
      // Without these on the wire, changing the capture format would produce
      // garbage transcripts instead of an error.
      final uri = speechSocketUri(
        languageCode: 'en',
        mode: ListeningMode.single,
        baseUrl: 'http://localhost:8000',
      );

      expect(uri.queryParameters['encoding'], 'linear16');
      expect(uri.queryParameters['sample_rate'], '16000');
      expect(uri.queryParameters['channels'], '1');
    });

    test('refuses a base URL that is not http', () {
      expect(
        () => speechSocketUri(
          languageCode: 'en',
          mode: ListeningMode.single,
          baseUrl: 'ftp://example.com',
        ),
        throwsArgumentError,
      );
    });
  });
}
