import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/utterance_repository.dart';
import '../../core/enrichment/enrichment_service.dart';

import '../../core/models/language.dart';
import '../../core/permissions/microphone_permission.dart';
import '../../core/providers.dart';
import '../../core/settings/language_preferences.dart';
import '../../core/speech/speech_recognizer.dart';
import '../../core/translation/translator.dart';
import 'speak_notice.dart';
import 'speak_state.dart';

/// Drives the speak screen: microphone permission, the recognition session,
/// and the debounced provisional translation of partial results.
///
/// Nothing here touches audio. It consumes [SpeechEvent]s, which are text.
class SpeakController extends Notifier<SpeakState> {
  /// Long enough that a fast talker does not trigger a translation per word,
  /// short enough that a rough translation appears while they are still going.
  static const provisionalTranslationDebounce = Duration(milliseconds: 300);

  Timer? _debounce;
  StreamSubscription<SpeechEvent>? _events;

  /// Guards against a slow translation of an old partial overwriting a newer
  /// one. Each translation request carries the transcript revision it is for.
  int _transcriptRevision = 0;

  SpeechRecognizer get _recognizer => ref.read(speechRecognizerProvider);
  OnDeviceTranslator get _translator => ref.read(onDeviceTranslatorProvider);
  MicrophonePermissions get _permissions =>
      ref.read(microphonePermissionsProvider);
  UtteranceRepository get _utterances => ref.read(utteranceRepositoryProvider);
  EnrichmentService get _enrichment => ref.read(enrichmentServiceProvider);
  LanguagePreferences get _preferences => ref.read(languagePreferencesProvider);

  @override
  SpeakState build() {
    _events = _recognizer.events.listen(_onSpeechEvent);
    ref.onDispose(() {
      _debounce?.cancel();
      _events?.cancel();
    });
    return SpeakState(pair: ref.read(initialLanguagePairProvider));
  }

  // --- User intents -------------------------------------------------------

  /// Starts listening. Requests the microphone if we do not have it yet.
  ///
  /// Never throws: every failure becomes a [SpeakNotice] the screen can render,
  /// because a broken microphone must not take the screen down with it.
  Future<void> startListening({ListeningMode mode = ListeningMode.single}) async {
    if (state.isListening) return;

    final access = await _ensureMicrophone();
    if (access != MicrophoneAccess.granted) return;

    state = state.copyWith(
      status: SpeakStatus.listening,
      mode: mode,
      notice: null,
      sourceText: '',
      translationText: '',
      translationSource: TranslationSource.none,
    );

    try {
      await _recognizer.start(
        languageCode: state.pair.source.code,
        mode: mode,
      );
    } on SpeechFailure catch (failure) {
      state = state.copyWith(
        status: SpeakStatus.idle,
        notice: _noticeFor(failure),
      );
    }
  }

  /// Ends the session and lets the recogniser finalise what it heard.
  Future<void> stopListening() async {
    if (!state.isListening) return;
    state = state.copyWith(status: SpeakStatus.finalising);
    await _recognizer.stop();
  }

  /// Ends the session and throws away the in-flight utterance.
  Future<void> cancelListening() async {
    _debounce?.cancel();
    await _recognizer.cancel();
    state = state.copyWith(
      status: SpeakStatus.idle,
      sourceText: '',
      translationText: '',
      translationSource: TranslationSource.none,
      soundLevel: 0,
    );
  }

  /// Toggles hands-free mode. Stops first so the recogniser restarts with the
  /// new mode rather than inheriting the old one.
  Future<void> setMode(ListeningMode mode) async {
    if (state.mode == mode) return;
    final wasListening = state.isListening;
    if (wasListening) await cancelListening();
    state = state.copyWith(mode: mode);
    if (wasListening) await startListening(mode: mode);
  }

  Future<void> swapLanguages() =>
      setLanguagePair(state.pair.swapped, clearTranscript: true);

  Future<void> setLanguagePair(
    LanguagePair pair, {
    bool clearTranscript = false,
  }) async {
    if (pair == state.pair) return;
    final wasListening = state.isListening;
    if (wasListening) await cancelListening();

    state = state.copyWith(
      pair: pair,
      notice: null,
      sourceText: clearTranscript ? '' : state.sourceText,
      translationText: '',
      translationSource: TranslationSource.none,
    );
    await _preferences.save(pair);

    // Re-translate what is already on screen under the new pair rather than
    // leaving a translation that no longer matches its label.
    if (state.hasTranscript) {
      _translateNow(state.sourceText, source: TranslationSource.finalOnDevice);
    }
    if (wasListening) await startListening(mode: state.mode);
  }

  /// Downloads the offline model a [TranslationModelMissing] notice named.
  Future<void> downloadMissingModel(Language language) async {
    state = state.copyWith(
      notice: TranslationModelMissing(language, isDownloading: true),
    );
    try {
      await _translator.downloadModel(language);
      state = state.copyWith(notice: null);
      if (state.hasTranscript) {
        _translateNow(
          state.sourceText,
          source: state.status == SpeakStatus.idle
              ? TranslationSource.finalOnDevice
              : TranslationSource.provisionalOnDevice,
        );
      }
    } on TranslationFailure {
      state = state.copyWith(
        notice: TranslationModelDownloadFailed(language),
      );
    }
  }

  Future<void> openSystemSettings() => _permissions.openSettings();

  void dismissNotice() => state = state.copyWith(notice: null);

  // --- Speech pipeline ----------------------------------------------------

  void _onSpeechEvent(SpeechEvent event) {
    switch (event) {
      case SpeechPartial(:final text):
        _transcriptRevision++;
        state = state.copyWith(sourceText: text, notice: null);
        _scheduleProvisionalTranslation(text, _transcriptRevision);

      case SpeechFinal(:final text):
        _transcriptRevision++;
        _debounce?.cancel();
        state = state.copyWith(
          sourceText: text,
          savedUtteranceId: null,
          status: state.mode == ListeningMode.continuous
              ? SpeakStatus.listening
              : SpeakStatus.idle,
          soundLevel: 0,
        );
        unawaited(_finalise(text, revision: _transcriptRevision));

      case SpeechSoundLevel(:final level):
        state = state.copyWith(soundLevel: level);

      case SpeechLifecycleChanged(:final lifecycle):
        _applyLifecycle(lifecycle);

      case SpeechFailed(:final failure):
        state = state.copyWith(
          status: failure.isPermanent ? SpeakStatus.idle : state.status,
          notice: _noticeFor(failure),
        );
    }
  }

  void _applyLifecycle(SpeechLifecycle lifecycle) {
    final status = switch (lifecycle) {
      SpeechLifecycle.listening => SpeakStatus.listening,
      SpeechLifecycle.processing =>
        state.isListening ? SpeakStatus.finalising : state.status,
      // A `done` in hands-free mode is the gap between utterances, not the end.
      SpeechLifecycle.done => state.mode == ListeningMode.continuous
          ? state.status
          : SpeakStatus.idle,
      SpeechLifecycle.idle => SpeakStatus.idle,
    };
    if (status != state.status) state = state.copyWith(status: status);
  }

  void _scheduleProvisionalTranslation(String text, int revision) {
    _debounce?.cancel();
    _debounce = Timer(provisionalTranslationDebounce, () {
      _translateNow(
        text,
        source: TranslationSource.provisionalOnDevice,
        revision: revision,
      );
    });
  }

  /// Translates [text] on-device and writes the result unless a newer
  /// transcript has arrived in the meantime.
  ///
  /// Returns the translation, or null if it could not be produced.
  Future<String?> _translateNow(
    String text, {
    required TranslationSource source,
    int? revision,
  }) async {
    final forRevision = revision ?? _transcriptRevision;
    if (text.trim().isEmpty) return null;
    try {
      final translation = await _translator.translate(text, pair: state.pair);
      if (forRevision != _transcriptRevision) return translation;
      state = state.copyWith(
        translationText: translation,
        translationSource: source,
      );
      return translation;
    } on TranslationFailure catch (failure) {
      if (forRevision == _transcriptRevision) {
        state = state.copyWith(notice: _noticeForTranslation(failure));
      }
      return null;
    }
  }

  /// Translates the finished utterance and saves it, in that order, so the
  /// stored row carries the best translation available offline.
  ///
  /// The save happens even when translation failed: the sentence the user said
  /// is worth keeping, and the backend fills the translation in later. A
  /// storage failure is surfaced but never re-raised — losing a row must not
  /// take the microphone down with it.
  Future<void> _finalise(String text, {required int revision}) async {
    final pair = state.pair;
    final translation = await _translateNow(
      text,
      source: TranslationSource.finalOnDevice,
      revision: revision,
    );

    try {
      final saved = await _utterances.saveFinalised(
        sourceText: text,
        translationText: translation ?? '',
        pair: pair,
      );
      if (revision == _transcriptRevision) {
        state = state.copyWith(savedUtteranceId: saved.id);
      }
      // Deliberately not awaited: the better translation and the word
      // breakdown arrive when they arrive, and the user is already speaking
      // again. A backend that is down leaves the row queued.
      unawaited(_enrichment.enrichNow(saved));
    } on Object catch (error, stackTrace) {
      debugPrint('WordNest: could not save utterance: $error\n$stackTrace');
      if (revision == _transcriptRevision) {
        state = state.copyWith(notice: const CouldNotSave());
      }
    }
  }

  /// Marks the utterance just spoken as one the user found hard.
  Future<void> flagLastUtterance() async {
    final id = state.savedUtteranceId;
    if (id == null) return;
    await _utterances.setFlagged(id, isFlagged: true);
  }

  // --- Permission ---------------------------------------------------------

  Future<MicrophoneAccess> _ensureMicrophone() async {
    var access = await _permissions.status();
    if (access == MicrophoneAccess.denied) {
      access = await _permissions.request();
    }
    state = state.copyWith(notice: _noticeForAccess(access));
    return access;
  }

  static SpeakNotice? _noticeForAccess(MicrophoneAccess access) =>
      switch (access) {
        MicrophoneAccess.granted => null,
        MicrophoneAccess.denied => const MicrophoneDenied(),
        MicrophoneAccess.permanentlyDenied => const MicrophoneBlocked(),
        MicrophoneAccess.restricted => const MicrophoneBlocked(),
      };

  SpeakNotice _noticeFor(SpeechFailure failure) => switch (failure.kind) {
        SpeechFailureKind.permissionDenied => const MicrophoneDenied(),
        SpeechFailureKind.permissionPermanentlyDenied =>
          const MicrophoneBlocked(),
        SpeechFailureKind.unavailable => const RecognitionUnavailable(),
        SpeechFailureKind.localeUnsupported =>
          LanguageNotRecognised(state.pair.source),
        SpeechFailureKind.noSpeechDetected => const NothingHeard(),
        SpeechFailureKind.recognitionFailed =>
          RecognitionFailed(detail: failure.detail),
      };

  SpeakNotice _noticeForTranslation(TranslationFailure failure) =>
      switch (failure.kind) {
        TranslationFailureKind.modelMissing =>
          TranslationModelMissing(failure.language ?? state.pair.target),
        TranslationFailureKind.modelDownloadFailed =>
          TranslationModelDownloadFailed(failure.language ?? state.pair.target),
        TranslationFailureKind.pairUnsupported ||
        TranslationFailureKind.translationFailed =>
          TranslationFailed(detail: failure.detail),
      };
}

final speakControllerProvider =
    NotifierProvider<SpeakController, SpeakState>(SpeakController.new);
