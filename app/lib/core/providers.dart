import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth/auth_api.dart';
import 'auth/device_identity.dart';
import 'auth/session_manager.dart';
import 'auth/session_store.dart';
import 'db/database.dart';
import 'db/sync_repository.dart';
import 'enrichment/enrichment_service.dart';
import 'network/api_client.dart';
import 'sync/sync_api.dart';
import 'sync/sync_engine.dart';
import 'db/glossary_repository.dart';
import 'db/review_repository.dart';
import 'db/utterance_repository.dart';
import 'models/language.dart';
import 'permissions/microphone_permission.dart';
import 'settings/language_preferences.dart';
import 'settings/speech_engine_controller.dart';
import 'settings/speech_engine_preferences.dart';
import 'speech/deepgram_speech_recognizer.dart';
import 'speech/fallback_speech_recognizer.dart';
import 'speech/microphone_stream.dart';
import 'speech/platform_speech_recognizer.dart';
import 'speech/speech_engine.dart';
import 'speech/speech_recognizer.dart';
import 'speech/speech_socket.dart';
import 'translation/backend_translator.dart';
import 'tts/platform_speaker.dart';
import 'tts/speaker.dart';
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

/// The recogniser choice read from storage before the first frame, alongside
/// the language pair. Which recogniser exists is decided by this, so learning
/// it late would mean building one and immediately throwing it away.
///
/// Overridden in `main()` and in tests; never used unoverridden.
final initialSpeechEngineProvider = Provider<SpeechEngine>(
  (ref) => throw StateError(
    'initialSpeechEngineProvider must be overridden with the stored engine',
  ),
);

final speechEnginePreferencesProvider = Provider<SpeechEnginePreferences>(
  (ref) => SharedPreferencesSpeechEnginePreferences(),
);

final speechEngineProvider =
    NotifierProvider<SpeechEngineController, SpeechEngine>(
  SpeechEngineController.new,
);

final microphoneStreamProvider = Provider<MicrophoneStream>((ref) {
  final microphone = RecordMicrophoneStream();
  ref.onDispose(microphone.dispose);
  return microphone;
});

final speechSocketFactoryProvider =
    Provider<SpeechSocketFactory>((ref) => connectSpeechSocket);

/// Supplies the speech socket's bearer token.
///
/// A closure rather than the `AccessTokens` interface the HTTP client uses:
/// that interface lives beside dio, and nothing under `core/speech` may import
/// dio. A function type crosses the boundary where the interface cannot.
final speechCredentialsProvider = Provider<SpeechCredentials>((ref) {
  return ({bool renew = false}) {
    final sessions = ref.read(sessionManagerProvider);
    return renew ? sessions.renew() : sessions.current();
  };
});

/// Builds the recogniser for an engine.
///
/// A seam rather than a convenience: without it, a test of the engine switch
/// would have to construct a real [PlatformSpeechRecognizer] and its platform
/// channels just to watch one recogniser be replaced by another.
final speechRecognizerFactoryProvider =
    Provider<SpeechRecognizer Function(SpeechEngine)>((ref) {
  return (engine) => switch (engine) {
        SpeechEngine.phone => PlatformSpeechRecognizer(),
        // Wrapped rather than used bare: a cloud recogniser that cannot reach
        // its server would otherwise leave the microphone dead, in an app whose
        // whole promise is that it works without a connection.
        SpeechEngine.deepgram => FallbackSpeechRecognizer(
            preferred: DeepgramSpeechRecognizer(
              microphone: ref.read(microphoneStreamProvider),
              connect: ref.read(speechSocketFactoryProvider),
              credentials: ref.read(speechCredentialsProvider),
            ),
            fallback: PlatformSpeechRecognizer(),
          ),
      };
});

/// The recogniser the app is currently set to use.
///
/// Watches the engine, so changing the setting tears this one down and builds
/// the other. Riverpod runs the previous build's `onDispose` before the next
/// build, so there is never a moment with two live recognisers.
final speechRecognizerProvider = Provider<SpeechRecognizer>((ref) {
  final build = ref.watch(speechRecognizerFactoryProvider);
  final recognizer = build(ref.watch(speechEngineProvider));
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

/// The client and the session manager need each other: the client attaches the
/// bearer token, and renewing that token is itself a request. The client takes
/// its token source as a supplier resolved at request time, which breaks the
/// cycle without either of them holding a half-built object.
// The explicit variable type is required: these three reference each other,
// and without it the analyser cannot infer them.
final Provider<ApiClient> apiClientProvider = Provider<ApiClient>(
  (ref) => ApiClient(accessTokens: () => ref.read(sessionManagerProvider)),
);

final Provider<AuthApi> authApiProvider = Provider<AuthApi>(
  (ref) => HttpAuthApi(ref.watch(apiClientProvider)),
);

final Provider<SessionManager> sessionManagerProvider =
    Provider<SessionManager>((ref) {
  final manager = SessionManager(
    authApi: ref.watch(authApiProvider),
    sessionStore: PreferencesSessionStore(),
    deviceIdentity: PlatformDeviceIdentity(),
  );
  ref.onDispose(manager.dispose);
  return manager;
});

final syncRepositoryProvider = Provider<SyncRepository>(
  (ref) => SyncRepository(database: ref.watch(databaseProvider)),
);

final syncApiProvider = Provider<SyncApi>(
  (ref) => HttpSyncApi(ref.watch(apiClientProvider)),
);

final syncEngineProvider = Provider<SyncEngine>((ref) {
  final engine = SyncEngine(
    syncApi: ref.watch(syncApiProvider),
    syncRepository: ref.watch(syncRepositoryProvider),
    sessionManager: ref.watch(sessionManagerProvider),
  );
  ref.onDispose(engine.dispose);
  return engine;
});

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

final reviewRepositoryProvider = Provider<ReviewRepository>(
  (ref) => ReviewRepository(database: ref.watch(databaseProvider)),
);

final speakerProvider = Provider<Speaker>((ref) {
  final speaker = PlatformSpeaker();
  ref.onDispose(speaker.dispose);
  return speaker;
});
