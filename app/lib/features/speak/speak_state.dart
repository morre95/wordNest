import 'package:freezed_annotation/freezed_annotation.dart';

import '../../core/models/language.dart';
import '../../core/speech/speech_recognizer.dart';
import 'speak_notice.dart';

part 'speak_state.freezed.dart';

/// What the microphone control is doing, from the user's point of view.
enum SpeakStatus {
  /// Not listening. Tap or hold to start.
  idle,

  /// The user is holding the control while the platform opens the microphone.
  starting,

  /// Microphone is open and partials are arriving.
  listening,

  /// The user stopped; the recogniser is settling on a final result.
  finalising,
}

/// Where the translation currently on screen came from.
enum TranslationSource {
  /// Nothing translated yet.
  none,

  /// Debounced on-device translation of a partial. Expected to be replaced.
  provisionalOnDevice,

  /// On-device translation of the final utterance. Good enough to keep when
  /// the backend is unreachable.
  finalOnDevice,

  /// The backend's higher-quality translation (milestone 3).
  finalRemote,
}

@freezed
abstract class SpeakState with _$SpeakState {
  const SpeakState._();

  const factory SpeakState({
    required LanguagePair pair,
    @Default(SpeakStatus.idle) SpeakStatus status,
    @Default(ListeningMode.single) ListeningMode mode,

    /// Everything finalised in the current microphone session. Natural pauses
    /// add to this paragraph instead of replacing what was already said.
    @Default('') String finalisedSourceText,

    /// The recogniser's replaceable draft for the sentence being spoken now.
    @Default('') String partialSourceText,
    @Default('') String translationText,
    @Default(TranslationSource.none) TranslationSource translationSource,

    /// Smoothed input level, 0..1, for the listening animation only.
    @Default(0.0) double soundLevel,

    /// Where the audio of the last session actually went. Drives the privacy
    /// line, which must describe the route taken rather than the one intended.
    @Default(SpeechRoute.onDevice) SpeechRoute recognitionRoute,

    /// The row the last finalised utterance was saved as. Lets the screen flag
    /// what was just said, and gives the backend queue something to enrich.
    String? savedUtteranceId,

    /// Whether the user has marked the sentence just said as one they found
    /// hard. Reset with each new utterance.
    @Default(false) bool isLastUtteranceFlagged,
    SpeakNotice? notice,
  }) = _SpeakState;

  bool get isListening => status == SpeakStatus.listening;

  /// The whole session as it should appear on screen. The recognisers return
  /// each utterance without surrounding whitespace, but normalising here keeps
  /// adapters and tests from being able to produce doubled gaps.
  String get sourceText {
    final finalised = finalisedSourceText.trim();
    final partial = partialSourceText.trim();
    if (finalised.isEmpty) return partial;
    if (partial.isEmpty) return finalised;
    return '$finalised $partial';
  }

  bool get hasTranscript => sourceText.trim().isNotEmpty;

  /// A provisional translation is shown dimmed, so the user reads it as a
  /// guess rather than the answer.
  bool get isTranslationProvisional =>
      translationSource == TranslationSource.provisionalOnDevice;
}
