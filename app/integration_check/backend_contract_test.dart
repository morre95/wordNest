@Tags(['contract'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/core/models/language.dart';
import 'package:wordnest/core/network/api_client.dart';
import 'package:wordnest/core/translation/backend_translator.dart';

/// Runs the real Dart client against a real wordnest-api.
///
/// Tagged `contract` so it is excluded from the default run: it needs a server.
/// Start one with `docker compose -f api/docker-compose.yml up api`, then:
///
///   flutter test integration_check --tags contract \
///     --dart-define=WORDNEST_API_BASE_URL=http://127.0.0.1:8000
void main() {
  const englishToSpanish = LanguagePair(
    source: Language(code: 'en', name: 'English'),
    target: Language(code: 'es', name: 'Spanish'),
  );

  test('the app and the service agree on the translation contract', () async {
    final translator = HttpBackendTranslator(ApiClient());

    final result = await translator.translate(
      'the bakery is closed',
      pair: englishToSpanish,
    );

    expect(result.sourceLanguage, 'en');
    expect(result.targetLanguage, 'es');
    expect(result.translation, isNotEmpty);
    expect(result.tokens, isNotEmpty);
    expect(
      result.tokens.map((token) => token.surfaceForm),
      ['the', 'bakery', 'is', 'closed'],
    );
    expect(
      result.tokens.where((token) => token.isContentWord).map((t) => t.lemma),
      ['bakery', 'closed'],
    );
  });

  test('an unsupported language pair is rejected, not retried', () async {
    final translator = HttpBackendTranslator(ApiClient());

    await expectLater(
      translator.translate(
        'hello',
        pair: const LanguagePair(
          source: Language(code: 'en', name: 'English'),
          target: Language(code: 'zz', name: 'Nonexistent'),
        ),
      ),
      throwsA(
        predicate(
          (error) => '$error'.contains('UNSUPPORTED_LANGUAGE_PAIR'),
          'is an UNSUPPORTED_LANGUAGE_PAIR failure',
        ),
      ),
    );
  });
}
