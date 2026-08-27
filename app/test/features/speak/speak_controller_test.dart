import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/core/db/database.dart';
import 'package:wordnest/core/db/tables.dart';
import 'package:wordnest/core/models/language.dart';
import 'package:wordnest/core/permissions/microphone_permission.dart';
import 'package:wordnest/core/speech/speech_recognizer.dart';
import 'package:wordnest/features/speak/speak_controller.dart';
import 'package:wordnest/features/speak/speak_notice.dart';
import 'package:wordnest/features/speak/speak_state.dart';

import '../../fakes/fake_language_preferences.dart';
import '../../fakes/fake_microphone_permissions.dart';
import '../../fakes/fake_speech_recognizer.dart';
import '../../fakes/fake_translator.dart';
import '../../fakes/speak_harness.dart';

void main() {
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
      expect(container.read(speakControllerProvider).status,
          SpeakStatus.listening);
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

    test('shows a blocked notice and does not listen when denied for good',
        () async {
      permissions.current = MicrophoneAccess.permanentlyDenied;
      final container = makeContainer();

      await container.read(speakControllerProvider.notifier).startListening();

      final state = container.read(speakControllerProvider);
      expect(state.notice, const MicrophoneBlocked());
      expect(state.status, SpeakStatus.idle);
      expect(recognizer.startedLanguages, isEmpty);
    });

    test('surfaces an unsupported locale as a notice, not an exception',
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
    });
  });

  group('live transcription', () {
    test('shows partials immediately and translates after the debounce',
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
    });

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

      expect(container.read(speakControllerProvider).status,
          SpeakStatus.listening);
    });
  });

  group('failures', () {
    test('an empty session reports that nothing was heard', () async {
      final container = makeContainer();
      await container.read(speakControllerProvider.notifier).startListening();

      recognizer.emitFailure(const SpeechFailure(
        SpeechFailureKind.noSpeechDetected,
        isPermanent: false,
      ));
      await settle();

      expect(container.read(speakControllerProvider).notice, const NothingHeard());
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
    test('a finalised utterance is saved with its final translation', () async {
      final database = WordNestDatabase.memory();
      addTearDown(database.close);
      final container = ProviderContainer.test(
        overrides: speakOverrides(
          recognizer: recognizer,
          translator: translator,
          permissions: permissions,
          preferences: preferences,
          database: database,
        ),
      );
      final controller = container.read(speakControllerProvider.notifier);
      await controller.startListening();

      recognizer.emitFinal('the bakery is closed');
      await settle();
      await settle();
      await settle();

      final saved = await database.select(database.utterances).get();
      expect(saved.single.sourceText, 'the bakery is closed');
      expect(saved.single.translationText, '[es] the bakery is closed');
      expect(
        container.read(speakControllerProvider).savedUtteranceId,
        saved.single.id,
      );
    });

    test('a sentence is kept even when it could not be translated', () async {
      translator.presentModels.remove('es');
      final database = WordNestDatabase.memory();
      addTearDown(database.close);
      final container = ProviderContainer.test(
        overrides: speakOverrides(
          recognizer: recognizer,
          translator: translator,
          permissions: permissions,
          preferences: preferences,
          database: database,
        ),
      );
      await container.read(speakControllerProvider.notifier).startListening();

      recognizer.emitFinal('the bakery is closed');
      await settle();
      await settle();
      await settle();

      final saved = await database.select(database.utterances).get();
      expect(saved.single.sourceText, 'the bakery is closed');
      expect(saved.single.translationText, '');
      expect(
        saved.single.enrichmentState,
        EnrichmentState.pending,
        reason: 'the backend should still get a chance at it',
      );
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
}
