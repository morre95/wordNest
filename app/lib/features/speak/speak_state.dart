import 'package:freezed_annotation/freezed_annotation.dart';

import '../../core/models/language.dart';
import '../../core/speech/speech_recognizer.dart';
import 'speak_notice.dart';

part 'speak_state.freezed.dart';

/// What the microphone control is doing, from the user's point of view.
enum SpeakStatus {
  /// Not listening. Tap or hold to start.
  idle,

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

    /// The transcript as it stands — partial while listening, final after.
    @Default('') String sourceText,
    @Default('') String translationText,
    @Default(TranslationSource.none) TranslationSource translationSource,

    /// Smoothed input level, 0..1, for the listening animation only.
    @Default(0.0) double soundLevel,

    /// True when the last session ran entirely on-device. False means the
    /// platform fell back to network recognition and the user should know.
    @Default(true) bool isRecognitionOnDevice,
    SpeakNotice? notice,
  }) = _SpeakState;

  bool get isListening => status == SpeakStatus.listening;

  bool get hasTranscript => sourceText.trim().isNotEmpty;

  /// A provisional translation is shown dimmed, so the user reads it as a
  /// guess rather than the answer.
  bool get isTranslationProvisional =>
      translationSource == TranslationSource.provisionalOnDevice;
}
