/// Text-to-speech, behind a narrow interface like the other platform services.
///
/// Playback only. It produces sound from text; it never records, and nothing
/// here touches the microphone or a file.
library;

/// Why the target language could not be spoken aloud.
enum SpeakerFailureKind {
  /// No voice installed for the language.
  voiceUnavailable,

  /// The engine is missing or failed to start.
  unavailable,
}

class SpeakerFailure implements Exception {
  const SpeakerFailure(this.kind, {this.languageCode});

  final SpeakerFailureKind kind;
  final String? languageCode;

  @override
  String toString() => 'SpeakerFailure($kind, $languageCode)';
}

abstract interface class Speaker {
  /// Whether [languageCode] can be spoken on this device.
  Future<bool> canSpeak(String languageCode);

  /// Speaks [text] in [languageCode]. Completes when playback ends.
  ///
  /// Throws [SpeakerFailure] when there is no voice for the language.
  Future<void> speak(String text, {required String languageCode});

  Future<void> stop();

  Future<void> dispose();
}
