import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/core/db/database.dart';
import 'package:wordnest/core/db/tables.dart';
import 'package:wordnest/core/models/language.dart';
import 'package:wordnest/core/network/api_exception.dart';
import 'package:wordnest/core/translation/remote_translation.dart';
import 'package:wordnest/core/permissions/microphone_permission.dart';
import 'package:wordnest/core/speech/speech_recognizer.dart';
import 'package:wordnest/features/speak/speak_controller.dart';
import 'package:wordnest/features/speak/speak_notice.dart';
import 'package:wordnest/features/speak/speak_state.dart';

import '../../fakes/fake_backend_translator.dart';
import '../../fakes/fake_language_preferences.dart';
import '../../fakes/fake_microphone_permissions.dart';
import '../../fakes/fake_speech_recognizer.dart';
import '../../fakes/fake_translator.dart';
import '../../fakes/speak_harness.dart';

void main() {
  // The controller listens for the app being backgrounded, so it needs a
  // binding even though nothing here pumps a widget.
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeSpeechRecognizer recognizer;
  late FakeTranslator translator;
  late FakeMicrophonePermissions permissions;
  late FakeLanguagePreferences preferences;

  setUp(() {
    recognizer = FakeSpeechRecognizer();
    translator = FakeTranslator();
    permissions = FakeMicrophonePermissions();
    preferences = FakeLanguagePreferences();
  });

  ProviderContainer makeContainer() => ProviderContainer.test(
    overrides: speakOverrides(
      recognizer: recognizer,
      translator: translator,
      permissions: permissions,
      preferences: preferences,
    ),
  );

  /// Lets the recogniser's broadcast stream deliver and any translation
  /// microtasks settle.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('starting a session', () {
    test('opens the microphone in the remembered source language', () async {
      final container = makeContainer();
      final controller = container.read(speakControllerProvider.notifier);

      await controller.startListening();

      expect(recognizer.startedLanguages, ['en']);
      expect(recognizer.startedModes, [ListeningMode.single]);
      expect(
        container.read(speakControllerProvider).status,
        SpeakStatus.listening,
      );
    });

    test('requests permission once when it has not been granted yet', () async {
      permissions
        ..current = MicrophoneAccess.denied
        ..afterRequest = MicrophoneAccess.granted;
      final container = makeContainer();

      await container.read(speakControllerProvider.notifier).startListening();

      expect(permissions.requestCount, 1);
      expect(recognizer.startedLanguages, ['en']);
    });

    test(
      'shows a blocked notice and does not listen when denied for good',
      () async {
        permissions.current = MicrophoneAccess.permanentlyDenied;
        final container = makeContainer();

        await container.read(speakControllerProvider.notifier).startListening();

        final state = container.read(speakControllerProvider);
        expect(state.notice, const MicrophoneBlocked());
        expect(state.status, SpeakStatus.idle);
        expect(recognizer.startedLanguages, isEmpty);
      },
    );

    test(
      'surfaces an unsupported locale as a notice, not an exception',
      () async {
        recognizer.failOnStart = const SpeechFailure(
          SpeechFailureKind.localeUnsupported,
          detail: 'en',
        );
        final container = makeContainer();

        await container.read(speakControllerProvider.notifier).startListening();

        final state = container.read(speakControllerProvider);
        expect(state.notice, isA<LanguageNotRecognised>());
        expect(state.status, SpeakStatus.idle);
      },
    );
  });

  group('live transcription', () {
    test(
      'shows partials immediately and translates after the debounce',
      () async {
        final container = makeContainer();
        final controller = container.read(speakControllerProvider.notifier);
        await controller.startListening();

        recognizer.emitPartial('hello');
        await settle();

        expect(container.read(speakControllerProvider).sourceText, 'hello');
        expect(container.read(speakControllerProvider).translationText, '');

        await Future<void>.delayed(
          SpeakController.provisionalTranslationDebounce + Duration.zero,
        );
        await settle();

        final state = container.read(speakControllerProvider);
        expect(state.translationText, '[es] hello');
        expect(state.isTranslationProvisional, isTrue);
      },
    );

    test('coalesces a burst of partials into one translation', () async {
      final container = makeContainer();
      final controller = container.read(speakControllerProvider.notifier);
      await controller.startListening();

      recognizer
        ..emitPartial('he')
        ..emitPartial('hel')
        ..emitPartial('hello th')
        ..emitPartial('hello there');
      await settle();
      await Future<void>.delayed(
        SpeakController.provisionalTranslationDebounce * 2,
      );
      await settle();

      expect(translator.translated, ['hello there']);
    });

    test('a final result replaces the provisional translation', () async {
      final container = makeContainer();
      final controller = container.read(speakControllerProvider.notifier);
      await controller.startListening();

      recognizer.emitFinal('good morning');
      await settle();
      await settle();

      final state = container.read(speakControllerProvider);
      expect(state.sourceText, 'good morning');
      expect(state.translationText, '[es] good morning');
      expect(state.isTranslationProvisional, isFalse);
      expect(state.translationSource, TranslationSource.finalOnDevice);
      expect(state.status, SpeakStatus.idle);
    });

    test('a stale translation cannot overwrite a newer transcript', () async {
      final gate = Completer<void>();
      translator.gate = gate.future;
      final container = makeContainer();
      final controller = container.read(speakControllerProvider.notifier);
      await controller.startListening();

      recognizer.emitPartial('slow one');
      await settle();
      await Future<void>.delayed(
        SpeakController.provisionalTranslationDebounce * 2,
      );

      // A newer transcript lands while the first translation is still in flight.
      translator.gate = null;
      recognizer.emitFinal('the real sentence');
      await settle();
      await settle();
      gate.complete();
      await settle();
      await settle();

      expect(
        container.read(speakControllerProvider).translationText,
        '[es] the real sentence',
      );
    });

    test('hands-free mode stays listening across utterances', () async {
      final container = makeContainer();
      final controller = container.read(speakControllerProvider.notifier);
      await controller.startListening(mode: ListeningMode.continuous);

      recognizer.emitFinal('first');
      await settle();

      expect(
        container.read(speakControllerProvider).status,
        SpeakStatus.listening,
      );
    });

    test(
      'hands-free accumulates finals and translates the whole paragraph',
      () async {
        final container = makeContainer();
        final controller = container.read(speakControllerProvider.notifier);
        await controller.startListening(mode: ListeningMode.continuous);

        recognizer
          ..emitFinal('The bakery is closed.')
          ..emitFinal('The bank is still open.');
        for (var index = 0; index < 8; index++) {
          await settle();
        }

        final state = container.read(speakControllerProvider);
        expect(
          state.sourceText,
          'The bakery is closed. The bank is still open.',
        );
        expect(
          state.translationText,
          '[es] The bakery is closed. The bank is still open.',
        );
        expect(state.translationSource, TranslationSource.finalOnDevice);
      },
    );

    test('a new partial is appended to the finalised paragraph', () async {
      final container = makeContainer();
      final controller = container.read(speakControllerProvider.notifier);
      await controller.startListening(mode: ListeningMode.continuous);

      recognizer.emitFinal('The bakery is closed.');
      for (var index = 0; index < 4; index++) {
        await settle();
      }
      recognizer.emitPartial('The bank is');
      await settle();

      expect(
        container.read(speakControllerProvider).sourceText,
        'The bakery is closed. The bank is',
      );

      await Future<void>.delayed(
        SpeakController.provisionalTranslationDebounce * 2,
      );
      await settle();
      final state = container.read(speakControllerProvider);
      expect(state.translationText, '[es] The bakery is closed. The bank is');
      expect(state.isTranslationProvisional, isTrue);
    });

    test(
      'the paragraph remains after stopping and clears on the next session',
      () async {
        final container = makeContainer();
        final controller = container.read(speakControllerProvider.notifier);
        await controller.startListening(mode: ListeningMode.continuous);
        recognizer.emitFinal('Keep this visible.');
        for (var index = 0; index < 4; index++) {
          await settle();
        }

        await controller.stopListening();
        expect(
          container.read(speakControllerProvider).sourceText,
          'Keep this visible.',
        );

        await controller.startListening(mode: ListeningMode.continuous);
        final state = container.read(speakControllerProvider);
        expect(state.sourceText, isEmpty);
        expect(state.translationText, isEmpty);
      },
    );
  });

  group('failures', () {
    test('an empty session reports that nothing was heard', () async {
      final container = makeContainer();
      await container.read(speakControllerProvider.notifier).startListening();

      recognizer.emitFailure(
        const SpeechFailure(
          SpeechFailureKind.noSpeechDetected,
          isPermanent: false,
        ),
      );
      await settle();

      expect(
        container.read(speakControllerProvider).notice,
        const NothingHeard(),
      );
    });

    test('a missing offline model offers the download', () async {
      translator.presentModels.remove('es');
      final container = makeContainer();
      final controller = container.read(speakControllerProvider.notifier);
      await controller.startListening();

      recognizer.emitFinal('hola');
      await settle();
      await settle();

      final notice = container.read(speakControllerProvider).notice;
      expect(notice, isA<TranslationModelMissing>());
      expect((notice! as TranslationModelMissing).language.code, 'es');
    });

    test('downloading the model clears the notice and translates', () async {
      translator.presentModels.remove('es');
      final container = makeContainer();
      final controller = container.read(speakControllerProvider.notifier);
      await controller.startListening();
      recognizer.emitFinal('hola');
      await settle();
      await settle();

      await controller.downloadMissingModel(
        const Language(code: 'es', name: 'Spanish'),
      );
      await settle();
      await settle();

      final state = container.read(speakControllerProvider);
      expect(translator.downloaded, ['es']);
      expect(state.notice, isNull);
      expect(state.translationText, '[es] hola');
    });

    test('a failed download offers a retry', () async {
      translator
        ..presentModels.remove('es')
        ..downloadFails = true;
      final container = makeContainer();
      final controller = container.read(speakControllerProvider.notifier);

      await controller.downloadMissingModel(
        const Language(code: 'es', name: 'Spanish'),
      );

      expect(
        container.read(speakControllerProvider).notice,
        isA<TranslationModelDownloadFailed>(),
      );
    });
  });

  group('persistence', () {
    late WordNestDatabase database;
    late FakeBackendTranslator backend;

    ProviderContainer withDatabase() {
      database = WordNestDatabase.memory();
      addTearDown(database.close);
      return ProviderContainer.test(
        overrides: speakOverrides(
          recognizer: recognizer,
          translator: translator,
          permissions: permissions,
          preferences: preferences,
          database: database,
          backendTranslator: backend,
        ),
      );
    }

    setUp(() => backend = FakeBackendTranslator());

    /// The utterance is written, then enriched, then written again — three
    /// hops of the event loop before the row has settled.
    Future<void> settleWrites() async {
      for (var i = 0; i < 5; i++) {
        await settle();
      }
    }

    test('the sentence is saved with its on-device translation', () async {
      backend.failure = const ApiException(ApiFailureKind.unreachable);
      final container = withDatabase();
      await container.read(speakControllerProvider.notifier).startListening();

      recognizer.emitFinal('the bakery is closed');
      await settleWrites();

      final saved = (await database.select(database.utterances).get()).single;
      expect(saved.sourceText, 'the bakery is closed');
      expect(saved.translationText, '[es] the bakery is closed');
      expect(saved.enrichmentState, EnrichmentState.pending);
      expect(
        container.read(speakControllerProvider).savedUtteranceId,
        saved.id,
      );
    });

    test('a paragraph still saves one row per finalised sentence', () async {
      backend.failure = const ApiException(ApiFailureKind.unreachable);
      final container = withDatabase();
      await container
          .read(speakControllerProvider.notifier)
          .startListening(mode: ListeningMode.continuous);

      recognizer
        ..emitFinal('First sentence.')
        ..emitFinal('Second sentence.');
      for (var index = 0; index < 12; index++) {
        await settle();
      }

      final saved = await database.select(database.utterances).get();
      expect(saved.map((row) => row.sourceText), [
        'First sentence.',
        'Second sentence.',
      ]);
      expect(saved.map((row) => row.translationText), [
        '[es] First sentence.',
        '[es] Second sentence.',
      ]);
      expect(
        container.read(speakControllerProvider).translationText,
        '[es] First sentence. Second sentence.',
      );
    });

    test(
      'marking the paragraph marks only its latest saved sentence',
      () async {
        backend.failure = const ApiException(ApiFailureKind.unreachable);
        final container = withDatabase();
        final controller = container.read(speakControllerProvider.notifier);
        await controller.startListening(mode: ListeningMode.continuous);

        recognizer
          ..emitFinal('First sentence.')
          ..emitFinal('Second sentence.');
        for (var index = 0; index < 12; index++) {
          await settle();
        }
        await controller.toggleLastUtteranceFlag();

        final saved = await database.select(database.utterances).get();
        expect(saved.map((row) => row.isFlagged), [false, true]);
      },
    );

    test("the backend's translation replaces the on-device one", () async {
      backend.response = const RemoteTranslation(
        sourceText: 'the bakery is closed',
        sourceLanguage: 'en',
        targetLanguage: 'es',
        translation: 'la panadería está cerrada',
      );
      final container = withDatabase();
      await container.read(speakControllerProvider.notifier).startListening();

      recognizer.emitFinal('the bakery is closed');
      await settleWrites();

      final saved = (await database.select(database.utterances).get()).single;
      expect(saved.translationText, 'la panadería está cerrada');
      expect(saved.enrichmentState, EnrichmentState.enriched);
    });

    test('a sentence is kept even when it could not be translated', () async {
      translator.presentModels.remove('es');
      backend.failure = const ApiException(ApiFailureKind.unreachable);
      final container = withDatabase();
      await container.read(speakControllerProvider.notifier).startListening();

      recognizer.emitFinal('the bakery is closed');
      await settleWrites();

      final saved = (await database.select(database.utterances).get()).single;
      expect(saved.sourceText, 'the bakery is closed');
      expect(saved.translationText, '');
      expect(
        saved.enrichmentState,
        EnrichmentState.pending,
        reason: 'the backend should still get a chance at it',
      );
    });

    test('a backend that is down never disturbs the speak screen', () async {
      backend.failure = const ApiException(ApiFailureKind.serverError);
      final container = withDatabase();
      await container.read(speakControllerProvider.notifier).startListening();

      recognizer.emitFinal('the bakery is closed');
      await settleWrites();

      final state = container.read(speakControllerProvider);
      expect(state.notice, isNull);
      expect(state.translationText, '[es] the bakery is closed');
    });
  });

  group('language pair', () {
    test('swapping reverses the pair and remembers it', () async {
      final container = makeContainer();
      final controller = container.read(speakControllerProvider.notifier);

      await controller.swapLanguages();

      expect(container.read(speakControllerProvider).pair.source.code, 'es');
      expect(preferences.saved.single.key, 'es-en');
    });

    test('changing the pair re-translates what is on screen', () async {
      final container = makeContainer();
      final controller = container.read(speakControllerProvider.notifier);
      await controller.startListening();
      recognizer.emitFinal('hello');
      await settle();
      await settle();

      await controller.setLanguagePair(
        const LanguagePair(
          source: Language(code: 'en', name: 'English'),
          target: Language(code: 'sv', name: 'Swedish'),
        ),
      );
      await settle();
      await settle();

      expect(
        container.read(speakControllerProvider).translationText,
        '[sv] hello',
      );
    });

    test('changing the pair re-translates the whole paragraph', () async {
      final container = makeContainer();
      final controller = container.read(speakControllerProvider.notifier);
      await controller.startListening(mode: ListeningMode.continuous);
      recognizer
        ..emitFinal('First sentence.')
        ..emitFinal('Second sentence.');
      for (var index = 0; index < 8; index++) {
        await settle();
      }
      await controller.stopListening();

      await controller.setLanguagePair(
        const LanguagePair(
          source: Language(code: 'en', name: 'English'),
          target: Language(code: 'sv', name: 'Swedish'),
        ),
      );
      for (var index = 0; index < 4; index++) {
        await settle();
      }

      final state = container.read(speakControllerProvider);
      expect(state.sourceText, 'First sentence. Second sentence.');
      expect(state.translationText, '[sv] First sentence. Second sentence.');
    });

    test('cancelling clears the transcript', () async {
      final container = makeContainer();
      final controller = container.read(speakControllerProvider.notifier);
      await controller.startListening();
      recognizer.emitPartial('half a sentence');
      await settle();

      await controller.cancelListening();

      final state = container.read(speakControllerProvider);
      expect(state.sourceText, '');
      expect(state.translationText, '');
      expect(recognizer.cancelCount, 1);
    });
  });

  group('a press and a release that race each other', () {
    // Opening the microphone is asynchronous: the permission check, then the
    // platform's own start. A hold-to-talk release can land inside that
    // window, and the widget layer does not await either call.

    test('a release during the permission check closes the session', () async {
      final container = makeContainer();
      final controller = container.read(speakControllerProvider.notifier);

      final starting = controller.startListening();
      await controller.stopListening();
      await starting;
      await settle();

      expect(recognizer.isListening, isFalse);
      expect(container.read(speakControllerProvider).status, SpeakStatus.idle);
    });

    test('a later press still opens a new session', () async {
      final container = makeContainer();
      final controller = container.read(speakControllerProvider.notifier);

      final starting = controller.startListening();
      await controller.stopListening();
      await starting;
      await settle();

      await controller.startListening();
      await settle();

      expect(recognizer.isListening, isTrue);
      expect(
        container.read(speakControllerProvider).status,
        SpeakStatus.listening,
      );
    });

    test(
      'a release before the listening callback cancels the open microphone',
      () async {
        recognizer.announceListening = false;
        final container = makeContainer();
        final controller = container.read(speakControllerProvider.notifier);

        await controller.startListening();
        expect(
          container.read(speakControllerProvider).status,
          SpeakStatus.starting,
        );
        expect(recognizer.isListening, isTrue);

        await controller.stopListening();

        expect(recognizer.isListening, isFalse);
        expect(recognizer.cancelCount, 1);
        expect(
          container.read(speakControllerProvider).status,
          SpeakStatus.idle,
        );
      },
    );

    test(
      'a session the platform ends by itself frees the next press',
      () async {
        final container = makeContainer();
        final controller = container.read(speakControllerProvider.notifier);

        await controller.startListening();
        await settle();
        // The platform gives up on its own — a timeout, a busy recogniser.
        recognizer.emitFailure(
          const SpeechFailure(SpeechFailureKind.recognitionFailed),
        );
        await settle();

        await controller.startListening();
        await settle();

        expect(recognizer.startedLanguages, hasLength(2));
        expect(
          container.read(speakControllerProvider).status,
          SpeakStatus.listening,
        );
      },
    );
  });
}
