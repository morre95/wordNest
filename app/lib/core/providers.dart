import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'db/database.dart';
import 'enrichment/enrichment_service.dart';
import 'network/api_client.dart';
import 'db/glossary_repository.dart';
import 'db/utterance_repository.dart';
import 'models/language.dart';
import 'permissions/microphone_permission.dart';
import 'settings/language_preferences.dart';
import 'speech/platform_speech_recognizer.dart';
import 'speech/speech_recognizer.dart';
import 'translation/backend_translator.dart';
import 'translation/mlkit_translator.dart';
import 'translation/translator.dart';

/// The language pair read from storage before the first frame, so the speak
/// screen can render its final state immediately instead of flashing a default.
///
/// Overridden in `main()` and in tests; never used unoverridden.
final initialLanguagePairProvider = Provider<LanguagePair>(
  (ref) => throw StateError(
    'initialLanguagePairProvider must be overridden with the remembered pair',
  ),
);

final languagePreferencesProvider = Provider<LanguagePreferences>(
  (ref) => SharedPreferencesLanguagePreferences(),
);

final microphonePermissionsProvider = Provider<MicrophonePermissions>(
  (ref) => const PlatformMicrophonePermissions(),
);

final speechRecognizerProvider = Provider<SpeechRecognizer>((ref) {
  final recognizer = PlatformSpeechRecognizer();
  ref.onDispose(recognizer.dispose);
  return recognizer;
});

final onDeviceTranslatorProvider = Provider<OnDeviceTranslator>((ref) {
  final translator = MlKitTranslator();
  ref.onDispose(translator.dispose);
  return translator;
});

/// The device's source of truth. Opened once and kept for the app's lifetime;
/// tests override this with an in-memory database.
final databaseProvider = Provider<WordNestDatabase>((ref) {
  final database = WordNestDatabase();
  ref.onDispose(database.close);
  return database;
});

final glossaryRepositoryProvider = Provider<GlossaryRepository>(
  (ref) => GlossaryRepository(database: ref.watch(databaseProvider)),
);

final utteranceRepositoryProvider = Provider<UtteranceRepository>(
  (ref) => UtteranceRepository(
    database: ref.watch(databaseProvider),
    glossaryRepository: ref.watch(glossaryRepositoryProvider),
  ),
);

final apiClientProvider = Provider<ApiClient>((ref) => ApiClient());

final backendTranslatorProvider = Provider<BackendTranslator>(
  (ref) => HttpBackendTranslator(ref.watch(apiClientProvider)),
);

/// Turns locally-saved utterances into enriched ones when the backend is up.
final enrichmentServiceProvider = Provider<EnrichmentService>((ref) {
  final service = EnrichmentService(
    backendTranslator: ref.watch(backendTranslatorProvider),
    utteranceRepository: ref.watch(utteranceRepositoryProvider),
    glossaryRepository: ref.watch(glossaryRepositoryProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});
