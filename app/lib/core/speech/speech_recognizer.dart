/// The one audio boundary in WordNest.
///
/// AUDIO POLICY — read before changing anything in this directory.
///
/// Microphone audio is owned end-to-end by the platform speech recogniser.
/// This app never receives audio samples, never opens a file, and never sends
/// bytes anywhere. Everything that crosses this interface is [String] text.
/// There is deliberately no `File`, no `path_provider`, and no `dart:io` import
/// anywhere under `lib/core/speech/`; `test/core/speech/no_audio_persistence_test.dart`
/// asserts that mechanically, and that a recognition session writes nothing to
/// the application document or cache directories.
library;

import 'dart:async';

/// Why a recognition session could not start or could not continue.
enum SpeechFailureKind {
  /// The user has not granted microphone access yet.
  permissionDenied,

  /// The user denied permanently; only Settings can undo it.
  permissionPermanentlyDenied,

  /// No recogniser on this device, or the plugin failed to initialise.
  unavailable,

  /// The recogniser works but not for the requested language.
  localeUnsupported,

  /// The recogniser heard nothing before it timed out.
  noSpeechDetected,

  /// Anything the platform reported that we cannot act on specifically.
  recognitionFailed,
}

/// A failure with enough detail for the UI to explain itself.
class SpeechFailure implements Exception {
  const SpeechFailure(this.kind, {this.detail, this.isPermanent = true});

  final SpeechFailureKind kind;
  final String? detail;

  /// A transient failure means the user can simply try again.
  final bool isPermanent;

  @override
  String toString() => 'SpeechFailure($kind, $detail)';
}

/// What the recogniser is doing right now.
enum SpeechLifecycle { idle, listening, processing, done }

/// Everything the recogniser tells us. Text only — never audio.
sealed class SpeechEvent {
  const SpeechEvent();
}

/// An in-progress transcription. Replaces the previous partial in full.
class SpeechPartial extends SpeechEvent {
  const SpeechPartial(this.text);
  final String text;
}

/// The recogniser has settled on this utterance and will not revise it.
class SpeechFinal extends SpeechEvent {
  const SpeechFinal(this.text, {this.confidence});
  final String text;
  final double? confidence;
}

/// Session lifecycle transitions, used to drive the microphone affordance.
class SpeechLifecycleChanged extends SpeechEvent {
  const SpeechLifecycleChanged(this.lifecycle);
  final SpeechLifecycle lifecycle;
}

/// A running estimate of input loudness, 0..1, for the listening animation.
class SpeechSoundLevel extends SpeechEvent {
  const SpeechSoundLevel(this.level);
  final double level;
}

/// Something went wrong. The session may or may not still be alive.
class SpeechFailed extends SpeechEvent {
  const SpeechFailed(this.failure);
  final SpeechFailure failure;
}

/// How long a session should run and how eagerly it should finalise.
enum ListeningMode {
  /// Hold-to-talk: one utterance, finalised when the user lets go.
  single,

  /// Hands-free: keep listening and emit an utterance per natural pause.
  continuous,
}

/// The narrow interface the rest of the app programs against.
///
/// Implementations: [PlatformSpeechRecognizer] in production, `FakeSpeechRecognizer`
/// in tests. Nothing outside this directory imports `speech_to_text`.
abstract interface class SpeechRecognizer {
  /// Prepares the recogniser. Safe to call more than once; the second call is
  /// a no-op that returns the first call's answer.
  Future<bool> initialize();

  /// Whether [initialize] succeeded and a recogniser exists on this device.
  bool get isAvailable;

  /// Whether a session is currently running.
  bool get isListening;

  /// Platform locale identifiers this device can recognise, e.g. `en_US`.
  Future<List<String>> availableLocaleIds();

  /// A single broadcast stream of text-only events.
  Stream<SpeechEvent> get events;

  /// Starts a session for [languageCode] (BCP-47 primary tag).
  ///
  /// Throws [SpeechFailure] if the session cannot start.
  Future<void> start({
    required String languageCode,
    ListeningMode mode = ListeningMode.single,
  });

  /// Ends the session and asks the recogniser to finalise what it has.
  Future<void> stop();

  /// Ends the session and discards the in-flight utterance.
  Future<void> cancel();

  Future<void> dispose();
}

/// Chooses the platform speech locale to use for a BCP-47 language tag.
///
/// Pure so it can be tested against the awkward cases: a device that only has
/// `en_GB` when we asked for English, a device that has nothing for the
/// language at all, and a device that reports locales with a `-` separator.
String? resolveSpeechLocaleId({
  required String languageCode,
  required List<String> availableLocaleIds,
  String? systemLocaleId,
}) {
  String languageOf(String localeId) =>
      localeId.replaceAll('-', '_').split('_').first.toLowerCase();

  final wanted = languageCode.toLowerCase();
  final matches = availableLocaleIds
      .where((id) => languageOf(id) == wanted)
      .toList(growable: false);
  if (matches.isEmpty) return null;

  // Prefer the system locale when it is one of the matches, so a British user
  // asking for English gets en_GB rather than whatever sorts first.
  if (systemLocaleId != null && matches.contains(systemLocaleId)) {
    return systemLocaleId;
  }
  // Then prefer the "plain" tag (`en`) or the one whose region echoes the
  // language (`sv_SE`, `de_DE`), which is the conventional default.
  final conventional = '${wanted}_${wanted.toUpperCase()}';
  for (final candidate in [wanted, conventional]) {
    for (final id in matches) {
      if (id.replaceAll('-', '_').toLowerCase() == candidate.toLowerCase()) {
        return id;
      }
    }
  }
  return matches.first;
}
