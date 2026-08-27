import '../models/language.dart';
import '../network/api_client.dart';
import 'remote_translation.dart';

/// Translation from the backend: better than the on-device model, and the only
/// source of lemmas, parts of speech and target-language word forms.
///
/// A separate interface from [OnDeviceTranslator] on purpose — they are not
/// interchangeable. The on-device one is always available and returns a string;
/// this one needs the network and returns a linguistic breakdown.
abstract interface class BackendTranslator {
  /// Throws [ApiException] when the backend cannot answer.
  Future<RemoteTranslation> translate(
    String text, {
    required LanguagePair pair,
  });
}

class HttpBackendTranslator implements BackendTranslator {
  const HttpBackendTranslator(this._client);

  final ApiClient _client;

  @override
  Future<RemoteTranslation> translate(
    String text, {
    required LanguagePair pair,
  }) async {
    final data = await _client.post(
      '/translations',
      body: {
        'source_text': text,
        'source_language': pair.source.code,
        'target_language': pair.target.code,
      },
    );
    return RemoteTranslation.fromJson(data);
  }
}
